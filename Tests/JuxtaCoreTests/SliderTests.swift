import XCTest
@testable import JuxtaCore

/// Where an insertion or deletion lands when it could slide over equal lines.
final class SliderTests: XCTestCase {
    /// Hunks as "-old", "+new", "~old => new".
    private func hunks(_ left: [String], _ right: [String]) -> [[String]] {
        let result = Comparator.compare(left, right)
        return result.hunks.map { hunk in
            result.rows[hunk.rows].map { row in
                switch row.kind {
                case .same: return "=" + left[Int(row.left)]
                case .changed: return "~" + left[Int(row.left)] + " => " + right[Int(row.right)]
                case .deleted: return "-" + left[Int(row.left)]
                case .inserted: return "+" + right[Int(row.right)]
                }
            }
        }
    }

    /// Starts from every alignment that inserts the extra lines of `long` into `short`
    /// (and deletes them, the other way round), and checks sliding moves them to `expected`.
    private func assertSlides(_ short: [String], _ long: [String], to expected: Range<Int>,
                              file: StaticString = #filePath, line: UInt = #line) {
        let table = Dictionary(zip(long, long.indices.map(Int32.init)), uniquingKeysWith: { x, _ in x })
        let a = short.map { table[$0]! }, b = long.map { table[$0]! }
        let count = long.count - short.count
        let placements = (0...short.count).filter { Array(long[..<$0] + long[($0 + count)...]) == short }
        XCTAssertTrue(placements.contains(expected.lowerBound), "expected placement isn't valid", file: file, line: line)
        XCTAssertEqual(expected.count, count, file: file, line: line)
        for start in placements {
            let matches = short.indices.map { Match($0, $0 < start ? $0 : $0 + count) }
            let inserted = Slider.slide(matches, a, b, short, long)
            XCTAssertEqual(Set(long.indices).subtracting(inserted.map(\.b)), Set(expected),
                           "inserted from \(start)", file: file, line: line)
            let deleted = Slider.slide(matches.map { Match($0.b, $0.a) }, b, a, long, short)
            XCTAssertEqual(Set(long.indices).subtracting(deleted.map(\.a)), Set(expected),
                           "deleted from \(start)", file: file, line: line)
        }
    }

    private func iosConfig(_ ports: [Int]) -> [String] {
        ["hostname r1", "!"] + ports.flatMap { ["interface Gi0/\($0)", " description port \($0)", "!"] } + ["end"]
    }

    func testIOSBlockAnywhere() {
        let ports = [1, 2, 3, 4]
        for position in 0...ports.count {
            var withNew = ports
            withNew.insert(9, at: position)
            let first = 2 + 3 * position
            assertSlides(iosConfig(ports), iosConfig(withNew), to: first..<(first + 3))
        }
    }

    func testIOSTwoBlocksTogether() {
        assertSlides(iosConfig([1, 4]), iosConfig([1, 2, 3, 4]), to: 5..<11)
    }

    func testIOSBlankBlocks() {
        // Blocks with no body: `!` is both the separator and what's inserted.
        assertSlides(["a", "!", "!", "b"], ["a", "!", "!", "!", "b"], to: 3..<4)
    }

    func testJunosUnit() {
        let before = [
            "interfaces {", "    ge-0/0/0 {", "        unit 0 {", "            family inet;", "        }",
            "        unit 10 {", "            vlan-id 10;", "        }", "    }", "}",
        ]
        var after = before
        after.insert(contentsOf: ["        unit 20 {", "            vlan-id 20;", "        }"], at: 8)
        assertSlides(before, after, to: 8..<11)
        XCTAssertEqual(hunks(before, after), [["+        unit 20 {", "+            vlan-id 20;", "+        }"]])
    }

    func testCNestedBlock() {
        let before = ["int f(int x) {", "    if (x) {", "        a();", "    }", "    return 0;", "}"]
        var after = before
        after.insert(contentsOf: ["    if (x) {", "        b();", "    }"], at: 4)
        assertSlides(before, after, to: 4..<7)
    }

    func testCFunctionsWithBlankLines() {
        let f = ["int f(void)", "{", "    return 1;", "}", ""]
        let g = ["int g(void)", "{", "    return 1;", "}", ""]
        assertSlides(f + ["int main(void)", "{", "}"], f + g + ["int main(void)", "{", "}"], to: 5..<10)
    }

    func testBlankSeparatedParagraph() {
        let before = ["First paragraph,", "two lines.", "", "Last paragraph.", "", "Signature"]
        var after = before
        after.insert(contentsOf: ["New paragraph,", "two lines.", ""], at: 3)
        assertSlides(before, after, to: 3..<6)
    }

    func testBlankSeparatedBlockTakesItsOwnBlankLine() {
        // Not the previous vrf's `!` through the new vrf's nested `  !`.
        let vrf = { (name: String) in ["vrf \(name)", "  address-family ipv4 unicast", "    rd 1:1", "  !", "!"] }
        let before = ["hostname r1", "!", ""] + vrf("a")
        assertSlides(before, before + [""] + vrf("b"), to: 8..<14)
    }

    func testBlankSeparatedBlocksAppended() {
        let before = ["ltm rule a {", "when HTTP_REQUEST {", "}", "}"]
        let after = before + ["", "ltm rule b {", "}", "", "ltm rule c {", "when HTTP_REQUEST {", "}", "}"]
        assertSlides(before, after, to: 4..<12)
    }

    func testBlockFollowedByBlankLineKeepsItsBlankLine() {
        // Blocks that end with `!` and a blank line: the blank line stays after the new
        // block, though the group could also start on the blank line above it.
        let block = { (port: Int) in ["interface Gi0/\(port)", " description port \(port)", "!", ""] }
        assertSlides(["hostname r1", ""] + block(1) + block(3) + ["end"],
                     ["hostname r1", ""] + block(1) + block(2) + block(3) + ["end"], to: 6..<10)
    }

    func testFortiOSEntryWithNestedEnd() {
        let entry = { (name: String) in
            ["    edit \"\(name)\"", "        set ip 10.0.0.1/24", "        config secondaryip",
             "            edit 1", "            next", "        end", "    next"]
        }
        let before = ["config system interface"] + entry("port1") + ["end"]
        assertSlides(before, ["config system interface"] + entry("port1") + entry("port2") + ["end"], to: 8..<15)
    }

    func testIndentedBlockEndsOnItsOwnCloser() {
        // Not `!` through `  exit`: a closer deeper than the group's first line is nested.
        let block = { (n: Int) in ["  router \(n)", "    area 0", "  exit", "!"] }
        assertSlides(["x"] + block(1) + ["end"], ["x"] + block(1) + block(2) + ["end"], to: 5..<9)
    }

    func testInsertionNextToAnEditJoinsItsHunk() {
        XCTAssertEqual(hunks(["a", " old value", "!", "b"], ["a", " new value", "!", "!", "b"]).count, 1)
    }

    func testUnambiguousChangesStayPut() {
        let a: [Int32] = [0, 1, 2, 3, 4], b: [Int32] = [0, 1, 5, 3, 4, 6]
        let lines = ["a", "b", "c", "d", "e", "f", "g"]
        let matches = SequenceDiff.matches(a, b)
        XCTAssertEqual(Slider.slide(matches, a, b, a.map { lines[Int($0)] }, b.map { lines[Int($0)] }), matches)
        XCTAssertEqual(hunks(["a", "b", "c", "d"], ["a", "b", "x", "c", "d"]), [["+x"]])
    }

    /// Sliding never changes how many lines match, and keeps matches equal and in order.
    func testSlidingKeepsAValidMinimalAlignment() {
        var rng = SystemRandomNumberGenerator()
        let words = ["!", "", "}", " x", "  y", "end", "a"]
        for _ in 0..<2000 {
            let a = (0..<Int.random(in: 0...30, using: &rng)).map { _ in Int32.random(in: 0...6, using: &rng) }
            let b = (0..<Int.random(in: 0...30, using: &rng)).map { _ in Int32.random(in: 0...6, using: &rng) }
            let matches = SequenceDiff.matches(a, b)
            let slid = Slider.slide(matches, a, b, a.map { words[Int($0)] }, b.map { words[Int($0)] })
            XCTAssertEqual(slid.count, matches.count, "a=\(a) b=\(b)")
            for (k, m) in slid.enumerated() {
                XCTAssertEqual(a[m.a], b[m.b])
                if k > 0 { XCTAssertTrue(m.a > slid[k - 1].a && m.b > slid[k - 1].b) }
            }
        }
    }
}
