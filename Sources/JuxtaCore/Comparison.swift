import Foundation

public struct DiffOptions: Equatable, Sendable {
    /// Treat runs of whitespace as a single space and ignore leading/trailing whitespace.
    public var ignoreWhitespace: Bool
    public var ignoreCase: Bool

    public init(ignoreWhitespace: Bool = false, ignoreCase: Bool = false) {
        self.ignoreWhitespace = ignoreWhitespace
        self.ignoreCase = ignoreCase
    }
}

public enum RowKind: UInt8, Sendable {
    case same, changed, deleted, inserted
}

/// One visual row of the side-by-side view. Line indices are -1 where that side has
/// no line (a filler row opposite an insertion or deletion).
public struct DiffRow: Equatable, Sendable {
    public var left: Int32
    public var right: Int32
    public var kind: RowKind

    public init(left: Int32, right: Int32, kind: RowKind) {
        self.left = left
        self.right = right
        self.kind = kind
    }
}

/// A contiguous run of non-identical rows.
public struct Hunk: Equatable, Sendable {
    public var rows: Range<Int>
}

public struct DiffResult: Sendable {
    public var rows: [DiffRow]
    public var hunks: [Hunk]
    public var changedLines = 0
    public var deletedLines = 0
    public var insertedLines = 0
    /// The comparison hit its time limit, so some regions that could have matched
    /// are shown as changes.
    public var isApproximate = false

    public static let empty = DiffResult(rows: [], hunks: [])

    public var isIdentical: Bool { hunks.isEmpty }

    /// Index of the first hunk whose rows start at or after `row`.
    public func firstHunk(atOrAfter row: Int) -> Int {
        var lo = 0, hi = hunks.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if hunks[mid].rows.lowerBound < row { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// Index of the hunk containing `row`, if any.
    public func hunk(containing row: Int) -> Int? {
        let next = firstHunk(atOrAfter: row + 1)
        guard next > 0, hunks[next - 1].rows.contains(row) else { return nil }
        return next - 1
    }

    /// The first and last of one side's lines (`\.left` or `\.right`) shown in `rows`,
    /// or nil when they are all fillers on that side.
    public func lines(in rows: Range<Int>, on side: KeyPath<DiffRow, Int32>) -> ClosedRange<Int>? {
        let rows = rows.clamped(to: self.rows.indices)
        guard let first = rows.first(where: { self.rows[$0][keyPath: side] >= 0 }),
              let last = rows.last(where: { self.rows[$0][keyPath: side] >= 0 }) else { return nil }
        return Int(self.rows[first][keyPath: side])...Int(self.rows[last][keyPath: side])
    }

    /// The rows from the first to the last showing any of one side's `lines`, or nil
    /// when none of them is shown.
    public func rows(showing lines: ClosedRange<Int>, on side: KeyPath<DiffRow, Int32>) -> Range<Int>? {
        let shows = { (row: Int) in lines.contains(Int(self.rows[row][keyPath: side])) }
        guard let first = rows.indices.first(where: shows),
              let last = rows.indices.last(where: shows) else { return nil }
        return first..<last + 1
    }
}

/// Character ranges (UTF-16, for use with NSString / CoreText) that differ within a
/// pair of changed lines.
public struct InlineChanges: Equatable, Sendable {
    public var left: [NSRange]
    public var right: [NSRange]
}

public enum Comparator {
    public static func compare(
        _ left: [String], _ right: [String], options: DiffOptions = DiffOptions(),
        timeLimit: TimeInterval = 5
    ) -> DiffResult {
        compare(left, right, options: options, timeLimit: timeLimit, cancellation: nil)!
    }

    /// Like `compare`, but returns nil, soon after `cancellation` is cancelled, instead
    /// of a result: what was found by then is incomplete and must not be shown.
    public static func compare(
        _ left: [String], _ right: [String], options: DiffOptions = DiffOptions(),
        timeLimit: TimeInterval = 5, cancellation: Cancellation?
    ) -> DiffResult? {
        var budget = PairingBudget(
            deadline: DispatchTime.now().uptimeNanoseconds + UInt64(max(0, timeLimit) * 1e9),
            cancellation: cancellation)
        let (a, b) = intern(left, right, options: options)
        if cancellation?.isCancelled == true { return nil }
        let (aligned, timedOut) = SequenceDiff.alignment(a, b, timeLimit: timeLimit, cancellation: cancellation)
        if cancellation?.isCancelled == true { return nil }
        let matches = Slider.slide(aligned, a, b, left, right)

        var rows: [DiffRow] = []
        rows.reserveCapacity(max(left.count, right.count))
        var i = 0, j = 0
        for match in matches + [Match(left.count, right.count)] {
            if match.a > i || match.b > j {
                appendHunk(&rows, left, right, i..<match.a, j..<match.b, options, &budget)
            }
            if match.a < left.count {
                rows.append(DiffRow(left: Int32(match.a), right: Int32(match.b), kind: .same))
            }
            i = match.a + 1
            j = match.b + 1
        }
        if cancellation?.isCancelled == true { return nil }
        var result = finish(rows)
        result.isApproximate = timedOut || budget.cutShort
        return result
    }

    /// Rows for showing a single document before the other side has been loaded.
    public static func passthrough(leftCount: Int?, rightCount: Int?) -> DiffResult {
        let count = max(leftCount ?? 0, rightCount ?? 0)
        let rows = (0..<count).map { index in
            DiffRow(
                left: index < (leftCount ?? 0) ? Int32(index) : -1,
                right: index < (rightCount ?? 0) ? Int32(index) : -1,
                kind: .same)
        }
        return DiffResult(rows: rows, hunks: [])
    }

    /// Highlights whole tokens: runs between whitespace and `. / : , - [ ] ( )`, which
    /// are tokens of their own. Lines of the same shape (show output) are compared token
    /// by token; others are matched by content with a token-level LCS. `options` hides
    /// the differences the comparison ignores.
    public static func inlineChanges(
        _ left: String, _ right: String, options: DiffOptions = DiffOptions()
    ) -> InlineChanges? {
        let a = Array(left.utf16), b = Array(right.utf16)
        if a.isEmpty || b.isEmpty { return nil }
        let ta = tokens(a), tb = tokens(b)
        var litA = [Bool](repeating: true, count: ta.count)
        var litB = [Bool](repeating: true, count: tb.count)
        func key(_ units: [UInt16], _ token: Token) -> ArraySlice<UInt16> {
            options.ignoreCase
                ? ArraySlice(String(decoding: units[token.range], as: UTF16.self).lowercased().utf16)
                : units[token.range]
        }
        if sameShape(ta, tb) {
            for k in ta.indices {
                let differs = key(a, ta[k]) != key(b, tb[k])
                litA[k] = differs
                litB[k] = differs
            }
        } else {
            // Positional comparison is linear; only the LCS needs a size cap.
            if ta.count + tb.count > 20_000 { return nil }
            var table = [ArraySlice<UInt16>: Int32](minimumCapacity: ta.count + tb.count)
            func ids(_ units: [UInt16], _ list: [Token]) -> [Int32] {
                list.map { token in
                    // Runs of plain spaces all match, whatever their width: realigned
                    // columns could otherwise outbid an unchanged word (`connected  10`
                    // vs `notconnect 10   `) and get it highlighted. Other runs match by
                    // the characters in them, so a tab or no-break space still shows.
                    if token.isSpace, units[token.range].allSatisfy({ $0 == 0x20 }) { return -1 }
                    let k = token.isSpace ? collapsed(units[token.range]) : key(units, token)
                    if let id = table[k] { return id }
                    let id = Int32(table.count)
                    table[k] = id
                    return id
                }
            }
            for match in SequenceDiff.matches(ids(a, ta), ids(b, tb), patience: false, timeLimit: 0.05) {
                litA[match.a] = false
                litB[match.b] = false
            }
        }
        if options.ignoreWhitespace {
            for k in ta.indices where ta[k].isSpace { litA[k] = false }
            for k in tb.indices where tb[k].isSpace { litB[k] = false }
        }
        let rangesA = highlightRanges(ta, litA), rangesB = highlightRanges(tb, litB)
        let changed = max(rangesA.reduce(0) { $0 + $1.length }, rangesB.reduce(0) { $0 + $1.length })
        // Lines that are mostly different read better with just the block color.
        if changed == 0 || Double(changed) > 0.7 * Double(max(a.count, b.count)) { return nil }
        return InlineChanges(left: rangesA, right: rangesB)
    }

    // MARK: - Internals

    private struct Token {
        var range: Range<Int>
        var isWord: Bool
        var isSpace: Bool
        /// The character, for a punctuation token; 0 otherwise.
        var punctuation: UInt16 = 0
    }

    /// Tabs and spaces, including the no-break and other unusual spaces that look like one.
    private static func isSpace(_ u: UInt16) -> Bool {
        u == 0x20 || u == 0x09 || (u >= 0xA0 && Invisibles.isUnusualSpace(Unicode.Scalar(u) ?? "a"))
    }

    private static func isPunctuation(_ u: UInt16) -> Bool {
        switch u {
        case 0x2E, 0x2F, 0x3A, 0x2C, 0x2D, 0x5B, 0x5D, 0x28, 0x29: return true  // . / : , - [ ] ( )
        default: return false
        }
    }

    /// A character that draws nothing (a control or zero-width character). Each is a
    /// one-character word, so a stray one is highlighted alone rather than with the word
    /// it's in, and never trimmed off a highlight as a separator would be.
    private static func isInvisible(_ u: UInt16) -> Bool {
        u < 0x20 ? u != 0x09 : u >= 0x7F && Invisibles.isBadged(Unicode.Scalar(u) ?? "a")
    }

    /// A whitespace run with repeats dropped: runs that differ only in width compare equal.
    private static func collapsed(_ run: ArraySlice<UInt16>) -> ArraySlice<UInt16> {
        var result: [UInt16] = []
        for u in run where u != result.last { result.append(u) }
        return result[...]
    }

    /// Words and whitespace runs, with each punctuation or invisible character a token of its own.
    private static func tokens(_ units: [UInt16]) -> [Token] {
        var list: [Token] = []
        var k = 0
        while k < units.count {
            let start = k
            if isPunctuation(units[k]) {
                k += 1
                list.append(Token(range: start..<k, isWord: false, isSpace: false, punctuation: units[start]))
            } else if isSpace(units[k]) {
                while k < units.count && isSpace(units[k]) { k += 1 }
                list.append(Token(range: start..<k, isWord: false, isSpace: true))
            } else if isInvisible(units[k]) {
                k += 1
                list.append(Token(range: start..<k, isWord: true, isSpace: false))
            } else {
                while k < units.count && !isSpace(units[k]) && !isPunctuation(units[k]) && !isInvisible(units[k]) {
                    k += 1
                }
                list.append(Token(range: start..<k, isWord: true, isSpace: false))
            }
        }
        return list
    }

    /// Same token count with the same punctuation in the same places. Whitespace runs
    /// may differ in width, since show output realigns its columns.
    private static func sameShape(_ ta: [Token], _ tb: [Token]) -> Bool {
        guard ta.count == tb.count else { return false }
        for (x, y) in zip(ta, tb) {
            if x.isWord != y.isWord || x.isSpace != y.isSpace { return false }
            if x.punctuation != y.punctuation { return false }
        }
        return true
    }

    /// Runs of highlighted tokens, without the separators at their ends unless the run
    /// is only separators. Runs with nothing but separators between them are joined so a
    /// changed phrase or address reads as one highlight, then split at any bracket left
    /// unpaired so a highlight never opens a bracket it doesn't close.
    private static func highlightRanges(_ list: [Token], _ lit: [Bool]) -> [NSRange] {
        func trimmed(_ run: Range<Int>) -> Range<Int>? {
            guard let lo = list[run].firstIndex(where: \.isWord),
                  let hi = list[run].lastIndex(where: \.isWord) else { return nil }
            return lo..<(hi + 1)
        }
        var runs: [Range<Int>] = []
        var k = 0
        while k < list.count {
            guard lit[k] else { k += 1; continue }
            let start = k
            while k < list.count && lit[k] { k += 1 }
            // A run of separators alone is a change of its own, never joined.
            guard let run = trimmed(start..<k) else { runs.append(start..<k); continue }
            if let last = runs.last, trimmed(last) != nil,
               !list[last.upperBound..<run.lowerBound].contains(where: \.isWord) {
                runs[runs.count - 1] = last.lowerBound..<run.upperBound
            } else {
                runs.append(run)
            }
        }
        return runs.flatMap { run -> [Range<Int>] in
            guard trimmed(run) != nil else { return [run] }
            let unpaired = unpairedBrackets(list, run)
            if unpaired.isEmpty { return [run] }
            var pieces: [Range<Int>] = []
            var lo = run.lowerBound
            for cut in unpaired + [run.upperBound] {
                if let piece = trimmed(lo..<cut) { pieces.append(piece) }
                lo = cut + 1
            }
            return pieces
        }.map {
            let start = list[$0.lowerBound].range.lowerBound
            return NSRange(location: start, length: list[$0.upperBound - 1].range.upperBound - start)
        }
    }

    /// Token indices of the brackets in `run` that have no partner inside it.
    private static func unpairedBrackets(_ list: [Token], _ run: Range<Int>) -> [Int] {
        var opened: [Int] = [], unpaired: [Int] = []
        for k in run {
            switch list[k].punctuation {
            case 0x28, 0x5B: opened.append(k)  // ( [
            case 0x29, 0x5D:  // ) ]
                let partner: UInt16 = list[k].punctuation == 0x29 ? 0x28 : 0x5B
                if let last = opened.last, list[last].punctuation == partner {
                    opened.removeLast()
                } else {
                    unpaired.append(k)
                }
            default: break
            }
        }
        return (unpaired + opened).sorted()
    }

    private static func normalize(_ line: String, _ options: DiffOptions) -> String {
        var s = line
        if options.ignoreWhitespace {
            s = s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        }
        if options.ignoreCase { s = s.lowercased() }
        return s
    }

    private static func intern(
        _ left: [String], _ right: [String], options: DiffOptions
    ) -> ([Int32], [Int32]) {
        var table = [ExactLine: Int32](minimumCapacity: left.count + right.count)
        let normalizing = options.ignoreWhitespace || options.ignoreCase
        func ids(_ lines: [String]) -> [Int32] {
            lines.map { line in
                let key = ExactLine(normalizing ? normalize(line, options) : line)
                if let id = table[key] { return id }
                let id = Int32(table.count)
                table[key] = id
                return id
            }
        }
        return (ids(left), ids(right))
    }

    /// A line compared by its exact UTF-8 bytes. String equality treats canonically
    /// equivalent text as equal (precomposed é == e + combining accent), which would
    /// hide real differences between files.
    private struct ExactLine: Hashable {
        let text: String
        init(_ text: String) { self.text = text }

        static func == (a: ExactLine, b: ExactLine) -> Bool {
            a.text.utf8.elementsEqual(b.text.utf8)
        }

        func hash(into hasher: inout Hasher) {
            var text = text
            text.withUTF8 { hasher.combine(bytes: UnsafeRawBufferPointer($0)) }
        }
    }

    /// Pairing shares the comparison's time limit, and gives up on regions too big to
    /// pair in reasonable time and memory.
    private struct PairingBudget {
        let deadline: UInt64
        let cancellation: Cancellation?
        /// Some region was left unpaired, or only partly paired, for lack of budget.
        var cutShort = false

        mutating func expired() -> Bool {
            if DispatchTime.now().uptimeNanoseconds > deadline || cancellation?.isCancelled == true {
                cutShort = true
            }
            return cutShort
        }
    }

    /// Lays out one region of differing lines. Similar lines are paired up so they
    /// sit side by side (and get inline highlights); the rest become pure deletions
    /// and insertions, since a changed row claims the two lines are versions of each
    /// other.
    private static func appendHunk(
        _ rows: inout [DiffRow], _ left: [String], _ right: [String],
        _ a: Range<Int>, _ b: Range<Int>, _ options: DiffOptions, _ budget: inout PairingBudget
    ) {
        var i = a.lowerBound, j = b.lowerBound
        for (pi, pj) in similarPairs(left, right, a, b, options, &budget) + [(a.upperBound, b.upperBound)] {
            for t in i..<pi {
                rows.append(DiffRow(left: Int32(t), right: -1, kind: .deleted))
            }
            for t in j..<pj {
                rows.append(DiffRow(left: -1, right: Int32(t), kind: .inserted))
            }
            if pi < a.upperBound {
                rows.append(DiffRow(left: Int32(pi), right: Int32(pj), kind: .changed))
            }
            i = pi + 1
            j = pj + 1
        }
    }

    /// Lines are similar enough to pair when the Dice coefficient of their character
    /// bigrams reaches this...
    private static let similarityThreshold: Float = 0.5
    /// ...or this, when they start with the same word.
    private static let sameWordThreshold: Float = 0.35

    /// Regions (or gaps between anchors) up to this many line pairs are aligned exactly.
    private static let exactPairingLimit = 40_000
    /// Most line pairs the banded alignment of one gap may compare (about 5 bytes each).
    private static let pairingCellLimit = 4_000_000
    /// Regions with more text than this (both sides, in UTF-8) aren't paired: bigrams
    /// take 4 bytes per character, and comparing long lines is slow.
    private static let pairingByteLimit = 16 << 20

    /// What pairing compares: a line's sorted character bigrams and its first word.
    private struct Signature {
        var grams: [UInt32]
        var head: Int
    }

    private static func signature(_ line: String, _ options: DiffOptions) -> Signature {
        Signature(grams: bigrams(line, options), head: leadingWords(line, 1, options))
    }

    /// How alike two lines are (Dice over bigrams), or 0 if too different to pair. A
    /// short edit to a keyword's value (` mtu 9000` → ` mtu 1514`) changes most of the
    /// line's bigrams, so lines that start with the same word need a lower score. The
    /// word alone isn't enough: `ip`, `set` and `interface` start unrelated lines.
    private static func similarity(_ x: Signature, _ y: Signature) -> Float {
        let s = dice(x.grams, y.grams)
        return s >= similarityThreshold || (s >= sameWordThreshold && x.head == y.head) ? s : 0
    }

    /// Similar lines to pair, increasing on both sides. Small regions get a DP that
    /// maximizes total similarity. That's O(n·m), so in bigger ones lines whose key
    /// (first two words) occurs once on each side are paired first, patience-style, and
    /// only the gaps between them get the DP, banded if still big. The two sides of a
    /// changed block are nearly always in the same order (route tables, show output),
    /// so this finds the same pairs without positional drift.
    private static func similarPairs(
        _ left: [String], _ right: [String], _ a: Range<Int>, _ b: Range<Int>,
        _ options: DiffOptions, _ budget: inout PairingBudget
    ) -> [(Int, Int)] {
        if a.isEmpty || b.isEmpty { return [] }
        // The common case (one line edited) is cheap, so it's paired even past the
        // deadline, without the DP's setup.
        if a.count == 1 && b.count == 1 {
            let s = similarity(signature(left[a.lowerBound], options), signature(right[b.lowerBound], options))
            return s > 0 ? [(a.lowerBound, b.lowerBound)] : []
        }
        let bytes = left[a].reduce(0) { $0 + $1.utf8.count } + right[b].reduce(0) { $0 + $1.utf8.count }
        if bytes > pairingByteLimit || budget.expired() {
            budget.cutShort = true
            return []
        }
        let sigA = a.map { signature(left[$0], options) }
        let sigB = b.map { signature(right[$0], options) }
        let anchors = a.count * b.count <= exactPairingLimit
            ? [] : keyAnchors(left[a], right[b], sigA, sigB, options)
        // Indices are relative to the region until the end.
        var pairs: [(Int, Int)] = []
        var i = 0, j = 0
        for anchor in anchors + [Match(a.count, b.count)] {
            pairs += alignedPairs(sigA, sigB, i..<anchor.a, j..<anchor.b, &budget)
            if anchor.a < a.count { pairs.append((anchor.a, anchor.b)) }
            i = anchor.a + 1
            j = anchor.b + 1
        }
        return pairs.map { (a.lowerBound + $0.0, b.lowerBound + $0.1) }
    }

    /// Similar pairs whose key is unique on both sides, as the longest run increasing on
    /// both sides (like patience diff's unique-line anchors).
    private static func keyAnchors(
        _ left: ArraySlice<String>, _ right: ArraySlice<String>,
        _ sigA: [Signature], _ sigB: [Signature], _ options: DiffOptions
    ) -> [Match] {
        struct Seen { var countA = 0, countB = 0, indexB = 0 }
        let keysA = left.map { leadingWords($0, 2, options) }
        var table = [Int: Seen](minimumCapacity: keysA.count)
        for key in keysA { table[key, default: Seen()].countA += 1 }
        for (j, line) in right.enumerated() {
            let key = leadingWords(line, 2, options)
            guard var seen = table[key] else { continue }
            seen.countB += 1
            seen.indexB = j
            table[key] = seen
        }
        var candidates: [Match] = []
        for (i, key) in keysA.enumerated() {
            let seen = table[key]!
            if seen.countA == 1 && seen.countB == 1 && similarity(sigA[i], sigB[seen.indexB]) > 0 {
                candidates.append(Match(i, seen.indexB))
            }
        }
        return SequenceDiff.longestIncreasingRun(candidates)
    }

    /// A hash of a line's first `count` words, skipping a leading sequence number. They
    /// usually name what the line describes (a route's prefix, an ACL entry's action),
    /// so they survive edits to the rest of the line and to ACL sequence numbers.
    private static func leadingWords(_ line: String, _ count: Int, _ options: DiffOptions) -> Int {
        var text = options.ignoreCase ? line.lowercased() : line
        return text.withUTF8 { bytes in
            func isSpace(_ k: Int) -> Bool { bytes[k] == 0x20 || bytes[k] == 0x09 }
            var hasher = Hasher()
            var words = 0, k = 0, first = true
            while words < count {
                while k < bytes.count && isSpace(k) { k += 1 }
                let start = k
                while k < bytes.count && !isSpace(k) { k += 1 }
                if start == k { break }
                let word = UnsafeRawBufferPointer(UnsafeBufferPointer(rebasing: bytes[start..<k]))
                let sequenceNumber = first && word.allSatisfy { $0 >= 0x30 && $0 <= 0x39 }
                first = false
                if sequenceNumber { continue }
                hasher.combine(bytes: word)
                hasher.combine(UInt8(0x20))
                words += 1
            }
            return hasher.finalize()
        }
    }

    /// The similar pairs maximizing total similarity within `ra` × `rb`. A big gap is
    /// only searched within a band around its diagonal, so lines far out of step stay
    /// unpaired rather than the cost growing as n·m. Past the deadline, the gap is left
    /// unpaired.
    private static func alignedPairs(
        _ sigA: [Signature], _ sigB: [Signature], _ ra: Range<Int>, _ rb: Range<Int>,
        _ budget: inout PairingBudget
    ) -> [(Int, Int)] {
        let n = ra.count, m = rb.count
        if n == 0 || m == 0 { return [] }
        // Wide enough for the gap's imbalance (lines inserted at one end of a block
        // whose keys repeat) plus some drift, within pairingCellLimit.
        let reach = n * m <= exactPairingLimit ? m
            : max(16, min(max(abs(n - m) + 16, exactPairingLimit / n), pairingCellLimit / (2 * n)))
        // Row i (1...n) holds columns lo[i]...hi[i] around the diagonal. Both bounds
        // never decrease, and the last row ends at m.
        var lo = [Int](repeating: 0, count: n + 1), hi = lo
        var offset = [Int](repeating: 0, count: n + 2)
        for i in 1...n {
            let center = i * m / n
            lo[i] = max(1, center - reach)
            hi[i] = min(m, center + reach)
            offset[i + 1] = offset[i] + hi[i] - lo[i] + 1
        }
        let up: UInt8 = 0, left: UInt8 = 1, pair: UInt8 = 2
        var score = [Float](repeating: 0, count: offset[n + 1])
        var move = [UInt8](repeating: up, count: offset[n + 1])
        func value(_ i: Int, _ j: Int) -> Float {
            if i == 0 || j == 0 { return 0 }
            // Columns past the band can only be left unpaired.
            if j > hi[i] { return score[offset[i] + hi[i] - lo[i]] }
            if j < lo[i] { return -.infinity }
            return score[offset[i] + j - lo[i]]
        }
        for i in 1...n {
            if i & 63 == 0 && budget.expired() { return [] }
            for j in lo[i]...hi[i] {
                let cell = offset[i] + j - lo[i]
                var best = value(i - 1, j)
                if value(i, j - 1) > best {
                    best = value(i, j - 1)
                    move[cell] = left
                }
                let s = similarity(sigA[ra.lowerBound + i - 1], sigB[rb.lowerBound + j - 1])
                if s > 0 && value(i - 1, j - 1) + s > best {
                    best = value(i - 1, j - 1) + s
                    move[cell] = pair
                }
                score[cell] = best
            }
        }
        var pairs: [(Int, Int)] = []
        var i = n, j = m
        while i > 0 && j > 0 {
            j = min(j, hi[i])
            switch move[offset[i] + j - lo[i]] {
            case pair:
                pairs.append((ra.lowerBound + i - 1, rb.lowerBound + j - 1))
                i -= 1
                j -= 1
            case left: j -= 1
            default: i -= 1
            }
        }
        return pairs.reversed()
    }

    private static func bigrams(_ line: String, _ options: DiffOptions) -> [UInt32] {
        var text = line.trimmingCharacters(in: .whitespaces)
        if options.ignoreCase { text = text.lowercased() }
        let bytes = Array(text.utf8)
        if bytes.count < 2 { return bytes.map { UInt32($0) << 16 } }
        var grams = [UInt32]()
        grams.reserveCapacity(bytes.count - 1)
        for k in 0..<(bytes.count - 1) {
            grams.append(UInt32(bytes[k]) << 8 | UInt32(bytes[k + 1]))
        }
        grams.sort()
        return grams
    }

    private static func dice(_ x: [UInt32], _ y: [UInt32]) -> Float {
        if x.isEmpty || y.isEmpty { return x.isEmpty && y.isEmpty ? 1 : 0 }
        var i = 0, j = 0, common = 0
        while i < x.count && j < y.count {
            if x[i] == y[j] {
                common += 1
                i += 1
                j += 1
            } else if x[i] < y[j] {
                i += 1
            } else {
                j += 1
            }
        }
        return Float(2 * common) / Float(x.count + y.count)
    }

    private static func finish(_ rows: [DiffRow]) -> DiffResult {
        var result = DiffResult(rows: rows, hunks: [])
        var start: Int?
        for (index, row) in rows.enumerated() {
            switch row.kind {
            case .same:
                if let s = start {
                    result.hunks.append(Hunk(rows: s..<index))
                    start = nil
                }
                continue
            case .changed: result.changedLines += 1
            case .deleted: result.deletedLines += 1
            case .inserted: result.insertedLines += 1
            }
            if start == nil { start = index }
        }
        if let s = start { result.hunks.append(Hunk(rows: s..<rows.count)) }
        return result
    }
}
