import Foundation

/// Finds the timers in show output (route and neighbor ages, uptimes, dead times) so
/// Ignore Timers can compare them as equal.
///
/// A timer is one of these, alone between separators (not inside a word, an address
/// or a dotted or colon-separated number):
/// - a clock with seconds: `00:12:44`, `0:04:12`, `10:15:32.123`;
/// - two or more units, largest first: `1w2d`, `3d04h`, `2y15w`, `1d02h03m`;
/// - Junos years, weeks or days and a clock: `3w2d 04:11:22`, `5d 3:04:11`, `5w1d 02:03`;
/// - two or more spelled-out units: `2 weeks, 3 days, 4 hours, 5 minutes`,
///   `12 day(s), 3 hour(s)`, `4 hours and 5 minutes`;
/// - `never` after `input`, `output`, `hang` or `counters` (`Last input never`).
///
/// Known gaps: bare-number timers (EIGRP hold, ARP age in minutes, Junos `Dead 34`,
/// IS-IS holdtime) look like any other number and still show, as do counters; so do
/// timers glued on with a colon (`Uptime:00:12:44`, syslog's `10:15:32.123:`), uppercase
/// units and three-digit hours or units. Some things that aren't timers match: a large
/// community with AS 1 (`1:10:20`) and times of day with seconds (`show clock`, Junos
/// `start-time 08:00:00`). Times without seconds (`08:00 to 17:00`) don't.
///
/// The scanner only tells ASCII apart, so it finds the same timers in UTF-8 and UTF-16.
enum Timers {
    /// What a timer is replaced with for comparison. A file with this private-use
    /// character in it would compare equal to a timer there, which is harmless.
    static let sentinel = "\u{E000}"
    private static let sentinelUTF8: [UInt8] = [0xEE, 0x80, 0x80]

    /// The timers in a line, as sorted, disjoint UTF-8 offsets.
    static func ranges(in bytes: UnsafeBufferPointer<UInt8>) -> [Range<Int>] {
        TimerScanner(bytes: bytes).ranges()
    }

    /// The timers in a line, as UTF-16 offsets.
    static func ranges(in units: [UInt16]) -> [Range<Int>] {
        // Non-ASCII is never part of a timer and never blocks one, so any one byte
        // above ASCII stands in for it.
        let folded = units.map { $0 < 0x80 ? UInt8($0) : 0x80 }
        return folded.withUnsafeBufferPointer { ranges(in: $0) }
    }

    /// The line with each timer replaced by `sentinel`; the line itself if it has none.
    static func masked(_ line: String) -> String {
        var text = line
        return text.withUTF8 { bytes in
            let found = ranges(in: bytes)
            if found.isEmpty { return line }
            // Every timer is at least as long as the sentinel's three bytes.
            return String(unsafeUninitializedCapacity: bytes.count) { buffer in
                let source = bytes.baseAddress!, target = buffer.baseAddress!
                var copied = 0, written = 0
                for range in found {
                    (target + written).initialize(from: source + copied, count: range.lowerBound - copied)
                    written += range.lowerBound - copied
                    (target + written).initialize(from: sentinelUTF8, count: 3)
                    written += 3
                    copied = range.upperBound
                }
                (target + written).initialize(from: source + copied, count: bytes.count - copied)
                return written + bytes.count - copied
            }
        }
    }
}

private struct TimerScanner {
    let bytes: UnsafeBufferPointer<UInt8>

    private static let unitWords: [[UInt8]] = ["year", "week", "day", "hour", "minute", "second"].map { Array($0.utf8) }
    private static let separators: [[UInt8]] = [", and ", ", ", " and "].map { Array($0.utf8) }
    private static let plural = Array("(s)".utf8)
    private static let neverWord = Array("never".utf8)
    private static let neverFollows: Set<[UInt8]> = Set(["input", "output", "hang", "counters"].map { Array($0.utf8) })

    func ranges() -> [Range<Int>] {
        var found: [Range<Int>] = []
        var k = 0
        while k < bytes.count {
            let c = bytes[k]
            if isDigit(c) || c == 0x6E, let end = timer(at: k) {  // n
                found.append(k..<end)
                k = end
            } else if isWord(c) {
                // Only the first byte of a word can start a timer.
                repeat { k += 1 } while k < bytes.count && isWord(bytes[k])
            } else {
                k += 1
            }
        }
        return found
    }

    /// The byte at `k`, or 0 outside the line.
    private func at(_ k: Int) -> UInt8 { k >= 0 && k < bytes.count ? bytes[k] : 0 }

    private func isDigit(_ c: UInt8) -> Bool { c >= 0x30 && c <= 0x39 }
    private func isLetter(_ c: UInt8) -> Bool { (c | 0x20) >= 0x61 && (c | 0x20) <= 0x7A }
    private func isWord(_ c: UInt8) -> Bool { isLetter(c) || isDigit(c) || c == 0x5F }

    /// Not inside a word or a dotted or colon-separated number.
    private func startsHere(_ k: Int) -> Bool {
        let c = at(k - 1)
        return !(isWord(c) || c == 0x2E || c == 0x3A)  // . :
    }

    /// Not followed by more of a word, a number or a path.
    private func endsHere(_ e: Int) -> Bool {
        let c = at(e)
        return !(isWord(c) || c == 0x2E || c == 0x3A || c == 0x2F)  // . : /
    }

    /// The end of a run of 1...`max` digits starting at `k`, if it isn't longer.
    private func digits(_ k: Int, _ max: Int) -> Int? {
        var j = k
        while isDigit(at(j)) { j += 1 }
        return j > k && j - k <= max ? j : nil
    }

    /// The end of two digits from 00 to 59 at `k`, alone.
    private func sixty(_ k: Int) -> Int? {
        isDigit(at(k)) && at(k) <= 0x35 && isDigit(at(k + 1)) && !isDigit(at(k + 2)) ? k + 2 : nil
    }

    private func matches(_ word: [UInt8], at k: Int) -> Bool {
        guard k + word.count <= bytes.count else { return false }
        for (offset, c) in word.enumerated() where bytes[k + offset] != c { return false }
        return true
    }

    private func timer(at k: Int) -> Int? {
        if at(k) == 0x6E { return never(k) }
        guard startsHere(k), let d = digits(k, 4) else { return nil }
        // What follows the first number tells the shapes apart.
        switch at(d) {
        case 0x3A: return hms(k)  // :
        case 0x20: return spelled(k)
        default:
            guard let run = unitRun(k) else { return nil }
            return unitsAndClock(run) ?? units(run)
        }
    }

    /// `h:mm` or `hh:mm:ss`, with a fraction of a second after the seconds.
    private func clock(_ k: Int, needSeconds: Bool) -> Int? {
        guard let h = digits(k, 2), at(h) == 0x3A, let m = sixty(h + 1) else { return nil }
        guard at(m) == 0x3A, let s = sixty(m + 1) else { return needSeconds ? nil : m }
        if at(s) == 0x2E, let fraction = digits(s + 1, 6) { return fraction }
        return s
    }

    private func hms(_ k: Int) -> Int? {
        guard let e = clock(k, needSeconds: true), endsHere(e) else { return nil }
        return e
    }

    /// Digits and unit letters, largest unit first (`1w2d`), with how many units and
    /// the rank of the last: y 0, w 1, d 2, h 3, m 4, s 5.
    private typealias UnitRun = (end: Int, count: Int, last: Int)

    private func unitRun(_ k: Int) -> UnitRun? {
        var j = k, count = 0, last = -1
        while isDigit(at(j)) {
            guard let d = digits(j, 2) else { return nil }
            let rank: Int
            switch at(d) {
            case 0x79: rank = 0  // y
            case 0x77: rank = 1  // w
            case 0x64: rank = 2  // d
            case 0x68: rank = 3  // h
            case 0x6D: rank = 4  // m
            case 0x73: rank = 5  // s
            default: return nil
            }
            guard rank > last else { return nil }
            last = rank
            count += 1
            j = d + 1
        }
        return count > 0 ? (j, count, last) : nil
    }

    /// Junos: years, weeks or days, then a clock (`3w2d 04:11:22`).
    private func unitsAndClock(_ run: UnitRun) -> Int? {
        guard run.last <= 2, at(run.end) == 0x20 else { return nil }
        var j = run.end
        while at(j) == 0x20 { j += 1 }
        guard isDigit(at(j)), let e = clock(j, needSeconds: false), endsHere(e) else { return nil }
        return e
    }

    private func units(_ run: UnitRun) -> Int? {
        guard run.count >= 2, endsHere(run.end) else { return nil }
        return run.end
    }

    /// One spelled-out unit (`3 days`, `3 day(s)`), with its rank.
    private func term(_ k: Int) -> (end: Int, rank: Int)? {
        guard let d = digits(k, 4), at(d) == 0x20 else { return nil }
        for (rank, word) in Self.unitWords.enumerated() where matches(word, at: d + 1) {
            var e = d + 1 + word.count
            if at(e) == 0x73 {  // s
                e += 1
            } else if matches(Self.plural, at: e) {
                e += 3
            }
            return isLetter(at(e)) ? nil : (e, rank)
        }
        return nil
    }

    /// Two or more spelled-out units, largest first (`2 weeks, 3 days and 4 hours`).
    private func spelled(_ k: Int) -> Int? {
        guard var (end, last) = term(k) else { return nil }
        var count = 1
        while true {
            guard let separator = Self.separators.first(where: {
                matches($0, at: end) && isDigit(at(end + $0.count))
            }), let next = term(end + separator.count), next.rank > last else { break }
            (end, last) = next
            count += 1
        }
        return count >= 2 && !isWord(at(end)) ? end : nil
    }

    /// `never` in place of a time, after `input`, `output`, `hang` or `counters`.
    private func never(_ k: Int) -> Int? {
        guard at(k - 1) == 0x20, matches(Self.neverWord, at: k), !isWord(at(k + 5)) else { return nil }
        var w = k - 1
        while isLetter(at(w - 1)) { w -= 1 }
        guard w < k - 1, !isWord(at(w - 1)),
              Self.neverFollows.contains(Array(bytes[w..<(k - 1)])) else { return nil }
        return k + 5
    }
}
