import XCTest
@testable import JuxtaCore

final class DiffTests: XCTestCase {
    private func lcsLength(_ a: [Int32], _ b: [Int32]) -> Int {
        var dp = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0..<a.count {
            for j in 0..<b.count {
                dp[i + 1][j + 1] = a[i] == b[j] ? dp[i][j] + 1 : max(dp[i][j + 1], dp[i + 1][j])
            }
        }
        return dp[a.count][b.count]
    }

    private func assertValid(_ matches: [Match], _ a: [Int32], _ b: [Int32], file: StaticString = #file, line: UInt = #line) {
        var lastA = -1, lastB = -1
        for m in matches {
            XCTAssertGreaterThan(m.a, lastA, file: file, line: line)
            XCTAssertGreaterThan(m.b, lastB, file: file, line: line)
            XCTAssertEqual(a[m.a], b[m.b], file: file, line: line)
            lastA = m.a
            lastB = m.b
        }
    }

    func testMyersIsOptimalOnRandomInputs() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<2000 {
            let a = (0..<Int.random(in: 0...30, using: &rng)).map { _ in Int32.random(in: 0...4, using: &rng) }
            let b = (0..<Int.random(in: 0...30, using: &rng)).map { _ in Int32.random(in: 0...4, using: &rng) }
            let matches = SequenceDiff.matches(a, b, patience: false)
            assertValid(matches, a, b)
            XCTAssertEqual(matches.count, lcsLength(a, b), "a=\(a) b=\(b)")
        }
    }

    func testPatienceProducesValidAlignment() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<2000 {
            let a = (0..<Int.random(in: 0...40, using: &rng)).map { _ in Int32.random(in: 0...25, using: &rng) }
            let b = (0..<Int.random(in: 0...40, using: &rng)).map { _ in Int32.random(in: 0...25, using: &rng) }
            assertValid(SequenceDiff.matches(a, b, patience: true), a, b)
        }
    }

    func testRowsReconstructBothSides() {
        var rng = SystemRandomNumberGenerator()
        let words = ["interface Gi0/1", " description uplink", " ip address 10.0.0.1 255.255.255.0", "!", " shutdown", " no shutdown", "router ospf 1", " network 10.0.0.0 0.0.0.255 area 0"]
        for _ in 0..<500 {
            let left = (0..<Int.random(in: 0...25, using: &rng)).map { _ in words.randomElement(using: &rng)! }
            let right = (0..<Int.random(in: 0...25, using: &rng)).map { _ in words.randomElement(using: &rng)! }
            let result = Comparator.compare(left, right)
            XCTAssertEqual(result.rows.filter { $0.left >= 0 }.map { left[Int($0.left)] }, left)
            XCTAssertEqual(result.rows.filter { $0.right >= 0 }.map { right[Int($0.right)] }, right)
            XCTAssertEqual(result.isIdentical, left == right)
            for row in result.rows where row.kind == .same {
                XCTAssertEqual(left[Int(row.left)], right[Int(row.right)])
            }
        }
    }

    func testSimilarLinesArePaired() {
        let left = ["hostname r1", "interface Gi0/1", " ip address 10.0.0.1 255.255.255.0", "end"]
        let right = ["hostname r1", "banner motd x", "interface Gi0/1", " ip address 10.0.0.2 255.255.255.0", "end"]
        let result = Comparator.compare(left, right)
        XCTAssertEqual(result.rows.map(\.kind), [.same, .inserted, .same, .changed, .same])
        XCTAssertEqual(result.hunks.count, 2)
        let inline = Comparator.inlineChanges(left[2], right[3])
        XCTAssertEqual(inline?.left, [NSRange(location: 19, length: 1)])
        XCTAssertEqual(inline?.right, [NSRange(location: 19, length: 1)])
    }

    func testDissimilarLinesAreNotPaired() {
        let left = ["hostname r1", " description uplink to core", "! unrelated comment", "end"]
        let right = ["hostname r1", " description uplink to core-2", "router ospf 1", "end"]
        XCTAssertEqual(Comparator.compare(left, right).rows.map(\.kind),
                       [.same, .changed, .deleted, .inserted, .same])
        // A lone pair gets the same check.
        XCTAssertEqual(Comparator.compare(["a", "banner motd x", "b"], ["a", "router ospf 1", "b"]).rows.map(\.kind),
                       [.same, .deleted, .inserted, .same])
    }

    func testSimilarityThresholdIsInclusive() {
        // Bigrams {ab, bc} vs {ab, bd}: Dice 0.5, paired.
        XCTAssertEqual(Comparator.compare(["<", "abc", ">"], ["<", "abd", ">"]).rows.map(\.kind),
                       [.same, .changed, .same])
        // {ab, bc, cd} vs {ab, bx, xy}: Dice 1/3, not paired.
        XCTAssertEqual(Comparator.compare(["<", "abcd", ">"], ["<", "abxy", ">"]).rows.map(\.kind),
                       [.same, .deleted, .inserted, .same])
    }

    func testShortValueEditsPairWhenFirstWordMatches() {
        func kinds(_ a: String, _ b: String) -> [RowKind] {
            Comparator.compare(["<", a, ">"], ["<", b, ">"]).rows.map(\.kind)
        }
        // Dice 0.43–0.45: the value is most of the line.
        for (a, b) in [(" mtu 9000", " mtu 1514"), (" name USERS", " name VOICE"),
                       (" password 7 0822455D0A16", " password 7 1511021F0725"),
                       (" switchport access vlan 10", " switchport mode trunk"),
                       // The first word after a sequence number.
                       (" 15 name USERS", " 20 name VOICE")] {
            XCTAssertEqual(kinds(a, b), [.same, .changed, .same], a)
        }
        // The same first word with little else in common (Dice 0.17, 0.19).
        XCTAssertEqual(kinds(" ip address 10.0.0.1 255.255.255.0", " ip ospf cost 10"),
                       [.same, .deleted, .inserted, .same])
        XCTAssertEqual(kinds("set interfaces ge-0/0/1 unit 0", "set protocols ospf area 0"),
                       [.same, .deleted, .inserted, .same])
    }

    func testOversizedRegionIsLeftUnpairedAndApproximate() {
        // 2 × 3000 lines of 3 KB: past the pairing byte limit.
        let filler = String(repeating: "x", count: 3000)
        let left = (0..<3000).map { "a\($0) " + filler }, right = (0..<3000).map { "b\($0) " + filler }
        let result = Comparator.compare(left, right)
        XCTAssertTrue(result.isApproximate)
        XCTAssertEqual(result.changedLines, 0)
        assertRebuildsBothFiles(result, leftCount: left.count, rightCount: right.count)
    }

    /// Blocks past the exact pairing limit, every line changed, with lines inserted and
    /// deleted inside: each line still pairs with its counterpart.
    func testLargeChangedBlockPairsWithoutDrift() {
        func check(_ name: String, _ line: (Int, Int) -> String, inserted: Set<Int>, deleted: Set<Int>,
                   file: StaticString = #filePath, line testLine: UInt = #line) {
            let count = 1500
            let left = (0..<count).filter { !inserted.contains($0) }.map { line($0, 0) }
            let right = (0..<count).filter { !deleted.contains($0) }.map { line($0, 1) }
            let result = Comparator.compare(left, right)
            assertRebuildsBothFiles(result, leftCount: left.count, rightCount: right.count, name,
                                    file: file, line: testLine)
            // Lines differ only in the version suffix, so pairs must share the rest.
            func id(_ text: String) -> Substring { text.dropLast(2) }
            for row in result.rows where row.kind == .changed {
                XCTAssertEqual(id(left[Int(row.left)]), id(right[Int(row.right)]), name, file: file, line: testLine)
            }
            XCTAssertEqual(Set(result.rows.filter { $0.kind == .inserted }.map { right[Int($0.right)] }),
                           Set(inserted.map { line($0, 1) }), name, file: file, line: testLine)
            XCTAssertEqual(Set(result.rows.filter { $0.kind == .deleted }.map { left[Int($0.left)] }),
                           Set(deleted.map { line($0, 0) }), name, file: file, line: testLine)
        }
        let inserted = Set([3, 4, 5, 400, 401, 900, 1499]), deleted = Set([0, 200, 201, 202, 1000])
        // Unique keys (the prefix): anchored.
        check("routes", { "O    10.0.\($0 / 256).\($0 % 256)/32 [110/2] via 192.168.1.1, age \($1)" },
              inserted: inserted, deleted: deleted)
        // Keys ("set x") repeat, so pairs come from the banded alignment. The random
        // names keep neighbors dissimilar, so only the counterpart can pair.
        func name(_ k: Int) -> String { String(UInt64(k) &* 11_400_714_819_323_198_485, radix: 36) }
        check("set members", { "  set x \(name($0 + 1))\(name($0 + 5000)) \($1)" },
              inserted: inserted, deleted: deleted)
        // The band must also span lines inserted all at one end.
        check("set members, top insert", { "  set x \(name($0 + 1))\(name($0 + 5000)) \($1)" },
              inserted: Set(0..<100), deleted: [])
    }

    // MARK: - Inline highlights

    /// The highlighted text, for readable assertions.
    private func lit(_ a: String, _ b: String, options: DiffOptions = DiffOptions())
        -> (left: [String], right: [String])? {
        guard let inline = Comparator.inlineChanges(a, b, options: options) else { return nil }
        return (inline.left.map { (a as NSString).substring(with: $0) },
                inline.right.map { (b as NSString).substring(with: $0) })
    }

    func testSameShapeComparesTokensByPosition() {
        // By content, either 00 on the right could be the inserted one.
        let inline = Comparator.inlineChanges("Last input 00:00:01, output 00:00:00",
                                              "Last input 00:00:00, output 00:00:00")
        XCTAssertEqual(inline?.left, [NSRange(location: 17, length: 2)])
        XCTAssertEqual(inline?.right, [NSRange(location: 17, length: 2)])
        // Realigned columns still count as the same shape; the padding isn't highlighted.
        let realigned = lit("     5 input errors, 0 CRC", "    50 input errors, 0 CRC")
        XCTAssertEqual(realigned?.left, ["5"])
        XCTAssertEqual(realigned?.right, ["50"])
    }

    func testDifferentShapeMatchesTokensByContent() {
        let got = lit(" permit tcp any any eq 80", " permit udp host 10.0.0.1 any eq 80")
        XCTAssertEqual(got?.left, ["tcp any"])
        XCTAssertEqual(got?.right, ["udp host 10.0.0.1"])
        XCTAssertEqual(lit("ip ospf cost 10", "ip ospf cost 100 ! raised")?.right, ["100 ! raised"])
        // Realigned padding mustn't outbid the unchanged VLAN.
        XCTAssertEqual(lit("Gi0/1  connected  10  a-full a-1000 10/100/1000BaseTX",
                           "Gi0/1  notconnect 10    auto   auto 10/100/1000BaseTX")?.right,
                       ["notconnect", "auto   auto"])
    }

    /// Ranges are sorted, disjoint, in bounds and cover whole tokens, and the words
    /// left unhighlighted are the same on both sides.
    func testInlineChangesInvariantsOnRandomLines() {
        let separators = Set(" \t./:,-[]()".utf16)
        let pieces = ["a", "b", "10", "0", " ", "  ", "\t", ".", "/", ":", ",", "-", "[", "]", "(", ")",
                      "é", "e\u{301}", "📍"]
        func plainWords(_ line: String, _ ranges: [NSRange]) -> [String] {
            let units = Array(line.utf16)
            var lit = [Bool](repeating: false, count: units.count)
            var end = 0
            for range in ranges {
                XCTAssertTrue(range.length > 0 && range.location >= end && NSMaxRange(range) <= units.count, line)
                end = NSMaxRange(range)
                for k in range.location..<end { lit[k] = true }
            }
            var words: [String] = []
            var k = 0
            while k < units.count {
                if separators.contains(units[k]) { k += 1; continue }
                let start = k
                while k < units.count && !separators.contains(units[k]) { k += 1 }
                XCTAssertEqual(Set(lit[start..<k]).count, 1, "partly highlighted token in \(line)")
                if !lit[start] { words.append(String(decoding: units[start..<k], as: UTF16.self)) }
            }
            return words
        }
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<20_000 {
            var a = (0..<Int.random(in: 0...12, using: &rng)).map { _ in pieces.randomElement(using: &rng)! }
            var b = a
            for _ in 0...Int.random(in: 0...3, using: &rng) {
                if b.isEmpty || Bool.random(using: &rng) {
                    b.insert(pieces.randomElement(using: &rng)!, at: Int.random(in: 0...b.count, using: &rng))
                } else {
                    b.remove(at: Int.random(in: 0..<b.count, using: &rng))
                }
            }
            if Bool.random(using: &rng) { swap(&a, &b) }
            let (x, y) = (a.joined(), b.joined())
            guard let inline = Comparator.inlineChanges(x, y) else { continue }
            XCTAssertEqual(plainWords(x, inline.left), plainWords(y, inline.right), "\(x) | \(y)")
        }
    }

    /// With timers ignored, a highlight holds a timer whole or not at all.
    func testHighlightsNeverSplitATimer() {
        let pieces = ["a", "10", " ", "  ", ".", ":", ",", "-", "(", ")", "é", "00:12:44", "1w2d", "3d04h",
                      "5d 3:04:11", "2 weeks, 3 days", " never", "input", "x"]
        let timers = DiffOptions(ignoreTimers: true)
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<10_000 {
            let a = (0..<Int.random(in: 1...10, using: &rng)).map { _ in pieces.randomElement(using: &rng)! }.joined()
            let b = (0..<Int.random(in: 1...10, using: &rng)).map { _ in pieces.randomElement(using: &rng)! }.joined()
            guard let inline = Comparator.inlineChanges(a, b, options: timers) else { continue }
            for (line, ranges) in [(a, inline.left), (b, inline.right)] {
                let units = Array(line.utf16)
                var end = 0
                for range in ranges {
                    XCTAssertTrue(range.length > 0 && range.location >= end && NSMaxRange(range) <= units.count, line)
                    end = NSMaxRange(range)
                    for timer in Timers.ranges(in: units) {
                        let overlap = max(timer.lowerBound, range.location) < min(timer.upperBound, NSMaxRange(range))
                        let holds = range.location <= timer.lowerBound && timer.upperBound <= NSMaxRange(range)
                        XCTAssertTrue(!overlap || holds, "\(line) | \(range)")
                    }
                }
            }
        }
    }

    func testAdjacentTokensMergeIntoOneRange() {
        XCTAssertEqual(lit("via 192.168.1.9, 01:02:03, Gi0/0/1", "via 192.168.1.9, 16:42:40, Gi0/0/1")?.left,
                       ["01:02:03"])
        // Unchanged tokens between two changes keep them apart.
        XCTAssertEqual(lit("10.0.1.1 255.255.255.0", "10.0.2.1 255.255.255.128")?.right, ["2", "128"])
    }

    func testHighlightsNeverHoldAnUnpairedBracket() {
        let got = lit("description dist-sw-01 (temp)", "description dist-sw-02 (perm)")
        XCTAssertEqual(got?.left, ["01", "temp"])
        XCTAssertEqual(got?.right, ["02", "perm"])
        // Split at the open bracket rather than reaching past it for the close.
        XCTAssertEqual(lit("set a (b c) d e f g", "set x (y z) d e f g")?.right, ["x", "y z"])
        // A closed group stays inside one highlight.
        XCTAssertEqual(lit("set a (b) c d e f g h", "set x (y) z d e f g h")?.right, ["x (y) z"])
        // A bracket that is the change itself is still highlighted.
        XCTAssertEqual(lit("match community 100 200", "match community (100 200")?.right, ["("])
    }

    func testHighlightsFollowComparisonOptions() {
        let caseOnly = DiffOptions(ignoreCase: true)
        XCTAssertNil(Comparator.inlineChanges("Interface Gi0/1", "interface Gi0/1", options: caseOnly))
        let (a, b) = ("Description Uplink to core 1", "description uplink to core 2")
        XCTAssertEqual(lit(a, b, options: caseOnly)?.right, ["2"])
        XCTAssertEqual(lit(a, b)?.right, ["description uplink", "2"])

        let spaces = DiffOptions(ignoreWhitespace: true)
        // Width changes on the positional path, and whitespace added or removed.
        XCTAssertNil(Comparator.inlineChanges("mtu  9000 x", "mtu 9000 x", options: spaces))
        XCTAssertNil(Comparator.inlineChanges(" mtu 9000", " mtu 9000  ", options: spaces))
        XCTAssertNil(Comparator.inlineChanges("  mtu 9000", "mtu 9000", options: spaces))
        XCTAssertEqual(lit("     5 input errors", " 50 input  errors", options: spaces)?.right, ["50"])
        XCTAssertEqual(lit("ip ospf cost 10", "ip ospf  cost 100 ", options: spaces)?.right, ["100"])

        let timers = DiffOptions(ignoreTimers: true)
        XCTAssertNil(Comparator.inlineChanges("Last input 00:00:01, output 00:00:00",
                                              "Last input never, output 00:00:00", options: timers))
        let (route, newer) = ("O 10.0.0.1/32 [110/2] via 192.168.1.1, 00:12:44, Gi0/0",
                              "O 10.0.0.1/32 [110/3] via 192.168.1.1, 1w2d, Gi0/0")
        XCTAssertEqual(lit(route, newer, options: timers)?.right, ["3"])
        XCTAssertEqual(lit(route, newer)?.right, ["3", "1w2d"])
        // A timer is one token, whatever its shape, so the line keeps its shape.
        XCTAssertEqual(lit("10.0.0.2  65002  1200  1300  0  0  1w2d 3:04:05 Establ",
                           "10.0.0.2  65002  1200  1300  0  0  5d 23:59:01 Active", options: timers)?.right,
                       ["Active"])
        XCTAssertEqual(lit("Uptime=00:12:44 state up", "Uptime=1w2d state down", options: timers)?.right, ["down"])
        // A timer replaced by something else is a real change.
        let unknown = lit("uptime 00:12:44 x", "uptime unknown x", options: timers)
        XCTAssertEqual(unknown?.left, ["00:12:44"])
        XCTAssertEqual(unknown?.right, ["unknown"])
    }

    func testOffsetsAreUTF16() {
        let a = "Café 📍 Zürich – 10.0.0.1", b = "Café 📍 Zürich – 10.0.0.12"
        let inline = Comparator.inlineChanges(a, b)
        XCTAssertEqual(inline?.left, [NSRange(location: 24, length: 1)])
        XCTAssertEqual(inline?.right, [NSRange(location: 24, length: 2)])
        XCTAssertEqual(lit("Zürich-1 up", "Zürich-2 up")?.right, ["2"])
        // Canonically equivalent but different code units still differ.
        XCTAssertEqual(lit("name Caf\u{E9} x", "name Cafe\u{301} x")?.right, ["Cafe\u{301}"])
    }

    func testSeparatorOnlyChanges() {
        // Nothing to highlight on the left: only the right gained a token run.
        let trailing = Comparator.inlineChanges(" mtu 9000", " mtu 9000  ")
        XCTAssertEqual(trailing?.left, [])
        XCTAssertEqual(trailing?.right, [NSRange(location: 9, length: 2)])
        XCTAssertEqual(lit("mtu  9000 x", "mtu 9000 x")?.left, ["  "])
        XCTAssertNil(Comparator.inlineChanges("", "mtu 9000"))
        XCTAssertNil(Comparator.inlineChanges("mtu 9000", "mtu 9000"))
    }

    func testUnusualSpacesAndInvisiblesAreHighlightedAlone() {
        // A no-break space is whitespace that differs in its characters, not its width.
        XCTAssertEqual(lit("banner Hello world", "banner Hello\u{A0}world")?.right, ["\u{A0}"])
        XCTAssertEqual(lit("a b", "a\u{2009}b")?.right, ["\u{2009}"])
        XCTAssertEqual(lit(" description core", "\u{A0}description core")?.left, [" "])
        XCTAssertEqual(lit("Gi0/1  connected  10", "Gi0/1\u{A0} connected  10")?.right, ["\u{A0} "])
        // Also on the content-matched path, where plain-space runs all match.
        XCTAssertEqual(lit("\tpermit ip any any x", "    permit ip any any")?.left, ["\t", "x"])
        XCTAssertEqual(lit("\tpermit ip any any x", "\t\tpermit ip any any")?.left, ["x"])
        // A zero-width or control character is a token of its own.
        XCTAssertEqual(lit("match community 65001:100", "match community 65001:\u{200B}100")?.right, ["\u{200B}"])
        XCTAssertEqual(lit("start", "\u{200B}start")?.right, ["\u{200B}"])
        XCTAssertEqual(lit("end", "end\u{AD}\u{200B}")?.right, ["\u{AD}\u{200B}"])
        // Kept at the end of a highlight, where a separator would be trimmed off.
        XCTAssertEqual(lit("emoji Cafe x", "emoji Caf\u{E9}\u{200D} x")?.right, ["Caf\u{E9}\u{200D}"])
        XCTAssertEqual(lit("banner motd ^C", "banner motd \u{1B}^C")?.right, ["\u{1B}"])
        // Column padding next to a changed value still isn't highlighted.
        XCTAssertEqual(lit("     5 input errors, 0 CRC", "    50 input errors, 0 CRC")?.right, ["50"])
        // Ignoring whitespace ignores unusual spaces too, as the line comparison does.
        let spaces = DiffOptions(ignoreWhitespace: true)
        XCTAssertTrue(Comparator.compare(["a b"], ["a\u{A0}b"], options: spaces).isIdentical)
        XCTAssertEqual(lit("banner Hello world 1", "banner Hello\u{A0}world 2", options: spaces)?.right, ["2"])
    }

    func testMostlyDifferentLinesGetNoHighlights() {
        XCTAssertNil(Comparator.inlineChanges("ip route 1.2.3.4", "router bgp 65000 x"))
        XCTAssertEqual(lit("Authorized access only.",
                           "Authorized access only. Disconnect now if you are not authorized.")?.right,
                       ["Disconnect now if you are not authorized"])
    }

    func testLongLineHighlightsChangedToken() throws {
        let a = try XCTUnwrap(TextDocument.load(from: Fixtures.file("20", "left")).lines.first)
        let b = try XCTUnwrap(TextDocument.load(from: Fixtures.file("20", "right")).lines.first)
        XCTAssertGreaterThan(a.utf16.count, 20_000)
        let inline = try XCTUnwrap(Comparator.inlineChanges(a, b))
        XCTAssertEqual(inline.left.count, 1)
        XCTAssertEqual(inline.right.count, 1)
        let (x, y) = ((a as NSString).substring(with: inline.left[0]), (b as NSString).substring(with: inline.right[0]))
        XCTAssertNotEqual(x, y)
        XCTAssertTrue(x.allSatisfy(\.isNumber) && y.allSatisfy(\.isNumber), "\(x) \(y)")
    }

    func testIgnoreWhitespaceAndCase() {
        let left = ["Interface  Gi0/1 ", "  mtu 9000"]
        let right = ["interface Gi0/1", "mtu 9000"]
        XCTAssertFalse(Comparator.compare(left, right).isIdentical)
        XCTAssertFalse(Comparator.compare(left, right, options: DiffOptions(ignoreWhitespace: true)).isIdentical)
        XCTAssertTrue(Comparator.compare(left, right, options: DiffOptions(ignoreWhitespace: true, ignoreCase: true)).isIdentical)
    }

    func testIgnoreTimers() {
        let left = ["Gateway of last resort is not set",
                    "O    10.0.0.1/32 [110/2] via 192.168.1.1, 00:12:44, Gi0/0",
                    "O    10.0.0.2/32 [110/2] via 192.168.1.1, 1w2d, Gi0/0",
                    "O    10.0.0.3/32 [110/2] via 192.168.1.1, 3d04h, Gi0/0"]
        let right = ["Gateway of last resort is not set",
                     "O    10.0.0.1/32 [110/2] via 192.168.1.1, 00:13:50, Gi0/0",
                     "S    172.16.0.0/24 [1/0] via 10.0.0.1",
                     "O    10.0.0.2/32 [110/2] via 192.168.1.1, 1w3d, Gi0/0",
                     "O    10.0.0.3/32 [110/2] via 192.168.1.1, 3d05h, Gi0/0"]
        let timers = DiffOptions(ignoreTimers: true)
        let result = Comparator.compare(left, right, options: timers)
        XCTAssertEqual(result.rows.filter { $0.kind != .same }, [DiffRow(left: -1, right: 2, kind: .inserted)])
        XCTAssertEqual(Comparator.compare(left, right).changedLines, 3)

        // With the other options too.
        let neighbor = ["Neighbor 10.0.0.2  UP  00:12:44"], other = ["neighbor 10.0.0.2 UP 1w2d"]
        let all = DiffOptions(ignoreWhitespace: true, ignoreCase: true, ignoreTimers: true)
        XCTAssertTrue(Comparator.compare(neighbor, other, options: all).isIdentical)
        XCTAssertFalse(Comparator.compare(neighbor, other, options: timers).isIdentical)

        // Things that look like timers still differ.
        for (a, b) in [("ipv6 address fe80::1:22:33", "ipv6 address fe80::1:22:34"),
                       ("periodic weekdays 08:00 to 17:00", "periodic weekdays 08:00 to 18:00"),
                       ("set community 65000:100", "set community 65000:200"),
                       ("10.0.0.5  0  aabb.1d00.0100  ARPA", "10.0.0.5  0  aabb.1d00.0101  ARPA"),
                       ("mac 00:11:22:33:44:55", "mac 00:11:22:33:44:56"),
                       ("  Last reset never", "  Last reset 00:00:05")] {
            XCTAssertFalse(Comparator.compare([a], [b], options: all).isIdentical, a)
        }
    }

    func testLineSplitting() {
        let doc = TextDocument(text: "\u{FEFF}a\r\nb\n\nc", name: "t")
        XCTAssertEqual(doc.lines, ["a", "b", "", "c"])
        XCTAssertEqual(TextDocument(text: "a\n", name: "t").lines, ["a"])
        XCTAssertEqual(TextDocument(text: "", name: "t").lines, [])
        XCTAssertEqual(TextDocument(text: "a\rb\rc", name: "t").lines, ["a", "b", "c"])
        XCTAssertEqual(TextDocument(text: "a\r\r\nb\n\rc\r", name: "t").lines, ["a", "", "b", "", "c"])
    }

    func testFormatOfLoadedFiles() throws {
        func format(_ bytes: [UInt8]) throws -> TextFormat? {
            try TextDocument(fileData: Data(bytes), name: "t").format
        }
        XCTAssertEqual(try format(Array("a\nb\n".utf8))?.lineEndings, .lf)
        XCTAssertEqual(try format(Array("a\r\nb".utf8))?.endsWithNewline, false)
        XCTAssertEqual(try format(Array("a\r\nb\n".utf8))?.lineEndings, [.lf, .crlf])
        XCTAssertEqual(try format([])?.endsWithNewline, true)
        XCTAssertEqual(try format([0xEF, 0xBB, 0xBF, 0x61])?.hasBOM, true)
        XCTAssertEqual(try format([0x61, 0xE9, 0x0A])?.encoding, .windowsLatin1)
        // One line without a line break has no line endings to disagree about.
        let single = try XCTUnwrap(format(Array("a".utf8)))
        XCTAssertEqual(single.differences(from: try XCTUnwrap(format(Array("a\r\n".utf8)))), [.finalNewline])
        XCTAssertThrowsError(try TextDocument(fileData: Data([0x61, 0x00, 0x62, 0x63, 0x00, 0x00]), name: "b"))
    }

    func testRowsReconstructBothSidesWithOptions() {
        var rng = SystemRandomNumberGenerator()
        let words = ["interface Gi0/1", "Interface  Gi0/1 ", " shutdown", "  SHUTDOWN", "!", " mtu 9000", "", " ",
                     "via 10.0.0.1, 00:12:44, Gi0/0", "via 10.0.0.1, 1w2d, Gi0/0", "  Last input never, output 00:00:00"]
        let allOptions = [DiffOptions(ignoreWhitespace: true), DiffOptions(ignoreCase: true),
                          DiffOptions(ignoreWhitespace: true, ignoreCase: true), DiffOptions(ignoreTimers: true),
                          DiffOptions(ignoreWhitespace: true, ignoreCase: true, ignoreTimers: true)]
        for options in allOptions {
            for _ in 0..<300 {
                let left = (0..<Int.random(in: 0...25, using: &rng)).map { _ in words.randomElement(using: &rng)! }
                let right = (0..<Int.random(in: 0...25, using: &rng)).map { _ in words.randomElement(using: &rng)! }
                let result = Comparator.compare(left, right, options: options)
                XCTAssertEqual(result.rows.filter { $0.left >= 0 }.map { left[Int($0.left)] }, left)
                XCTAssertEqual(result.rows.filter { $0.right >= 0 }.map { right[Int($0.right)] }, right)
                if options == DiffOptions(ignoreTimers: true) {
                    for row in result.rows where row.kind == .same {
                        XCTAssertEqual(Timers.masked(left[Int(row.left)]), Timers.masked(right[Int(row.right)]))
                    }
                }
            }
        }
    }

    func testTimeoutIsReportedAndStillValid() {
        // No unique lines and no common prefix/suffix, so only bisection can align these.
        let left = (0..<400).map { "line \($0 % 7)" }
        let right = (0..<400).map { "line \(($0 + 3) % 5)" }
        let a = left.map { Int32($0.last!.wholeNumberValue!) }
        let b = right.map { Int32($0.last!.wholeNumberValue!) }
        let alignment = SequenceDiff.alignment(a, b, timeLimit: 0)
        XCTAssertTrue(alignment.timedOut)
        assertValid(alignment.matches, a, b)

        let result = Comparator.compare(left, right, timeLimit: 0)
        XCTAssertTrue(result.isApproximate)
        XCTAssertEqual(result.rows.compactMap { $0.left >= 0 ? Int($0.left) : nil }, Array(left.indices))
        XCTAssertEqual(result.rows.compactMap { $0.right >= 0 ? Int($0.right) : nil }, Array(right.indices))
    }

    func testNormalCompareIsNotApproximate() {
        XCTAssertFalse(Comparator.compare(["a", "b", "c"], ["a", "x", "c"]).isApproximate)
        XCTAssertFalse(Comparator.compare(["a", "b"], ["c", "d"]).isApproximate)
        // Long enough for bisection to check the clock mid-search; the shared but
        // repeated "x" leaves no unique line to anchor on.
        let distant = Comparator.compare((0..<300).map { "l\($0)" } + ["x", "x"],
                                         ["x", "x"] + (0..<300).map { "r\($0)" })
        XCTAssertFalse(distant.isApproximate)
        XCTAssertEqual(distant.rows.filter { $0.kind == .same }.count, 2)
        // Disjoint inputs need no search at all.
        XCTAssertFalse(Comparator.compare((0..<300).map { "l\($0)" }, (0..<300).map { "r\($0)" }).isApproximate)
        XCTAssertFalse(SequenceDiff.alignment([1, 2, 1, 2], [2, 1, 2, 1]).timedOut)
    }

    /// A selection is kept as lines across results; the rows found for it must exist in
    /// the new result, which can be shorter (a cancelled comparison shows passthrough rows).
    func testSelectionMapsThroughLinesToNewResult() {
        let compared = Comparator.compare(["alpha", "beta", "gamma"], ["one", "two", "three", "four"])
        XCTAssertEqual(compared.rows.count, 7)
        let all = compared.rows.indices
        XCTAssertEqual(compared.lines(in: all, on: \.left), 0...2)
        XCTAssertEqual(compared.lines(in: all, on: \.right), 0...3)
        XCTAssertEqual(compared.lines(in: 0..<99, on: \.left), 0...2)
        let passthrough = Comparator.passthrough(leftCount: 3, rightCount: 4)
        XCTAssertEqual(passthrough.rows(showing: 0...2, on: \.left), 0..<3)
        XCTAssertEqual(passthrough.rows(showing: 0...3, on: \.right), 0..<4)
        XCTAssertEqual(passthrough.rows(showing: 1...1, on: \.left), 1..<2)
        // Filler rows hold no lines, so a selection of only those maps to nothing.
        let fillers = compared.rows.indices.filter { compared.rows[$0].left < 0 }
        XCTAssertFalse(fillers.isEmpty)
        XCTAssertNil(compared.lines(in: fillers.first!..<fillers.last! + 1, on: \.left))
        XCTAssertNil(passthrough.rows(showing: 5...6, on: \.left))
        // And back: the lines selected in passthrough rows map to the rows showing them.
        let rows = compared.rows(showing: 0...2, on: \.left)!
        XCTAssertEqual(rows.map { compared.rows[$0].left }.filter { $0 >= 0 }, [0, 1, 2])
    }
}
