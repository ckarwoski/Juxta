import XCTest
@testable import JuxtaCore

/// The desired layout for the config fixture pairs (30–53, 65). Checks the current engine
/// gets wrong are wrapped in XCTExpectFailure; remove the wrapper when a fix lands.
final class AlignmentTests: XCTestCase {
    private struct Pair {
        let left: [String]
        let right: [String]
        let result: DiffResult

        init(_ left: [String], _ right: [String]) {
            self.left = left
            self.right = right
            result = Comparator.compare(left, right)
        }

        func text(_ row: DiffRow) -> (String, String) {
            (row.left >= 0 ? left[Int(row.left)] : "", row.right >= 0 ? right[Int(row.right)] : "")
        }

        /// "-old", "+new", "~old => new" or "=same", for readable comparisons.
        func describe(_ row: DiffRow) -> String {
            let (a, b) = text(row)
            switch row.kind {
            case .same: return "=" + a
            case .changed: return "~" + a + " => " + b
            case .deleted: return "-" + a
            case .inserted: return "+" + b
            }
        }

        var hunks: [[String]] { result.hunks.map { result.rows[$0.rows].map(describe) } }
        var changedRows: [DiffRow] { result.rows.filter { $0.kind == .changed } }
    }

    private func load(_ pair: String, in folder: String = "pairs") throws -> Pair {
        Pair(try TextDocument.load(from: Fixtures.file(pair, "left", in: folder)).lines,
             try TextDocument.load(from: Fixtures.file(pair, "right", in: folder)).lines)
    }

    /// The route prefix, the second field of a `show ip route` line.
    private func prefix(_ line: String) throws -> Substring {
        let fields = line.split(separator: " ")
        return try XCTUnwrap(fields.count > 1 ? fields[1] : nil, "no prefix in \(line)")
    }

    // MARK: - Token helpers

    private static let separators = Set(" \t./:,-[]()".utf16)

    private func tokens(_ line: String) -> [String] {
        line.utf16.split { Self.separators.contains($0) }.map { String(decoding: $0, as: UTF16.self) }
    }

    /// The tokens `ranges` highlight. A partly highlighted token is listed with the
    /// highlighted part in brackets ("1[5]"), so it can never match a whole token.
    private func highlightedTokens(_ line: String, _ ranges: [NSRange]) -> [String] {
        let units = Array(line.utf16)
        var lit = [Bool](repeating: false, count: units.count)
        for range in ranges { for k in range.location..<NSMaxRange(range) { lit[k] = true } }
        var result: [String] = []
        var start = 0
        while start < units.count {
            if Self.separators.contains(units[start]) { start += 1; continue }
            var end = start
            while end < units.count && !Self.separators.contains(units[end]) { end += 1 }
            if lit[start..<end].allSatisfy({ $0 }) {
                result.append(String(decoding: units[start..<end], as: UTF16.self))
            } else if lit[start..<end].contains(true) {
                let clipped = ranges.map { NSIntersectionRange($0, NSRange(location: start, length: end - start)) }
                    .filter { $0.length > 0 }
                result.append(marked(String(decoding: units[start..<end], as: UTF16.self),
                                     clipped.map { NSRange(location: $0.location - start, length: $0.length) }))
            }
            start = end
        }
        return result
    }

    /// The line with each highlight wrapped in brackets.
    private func marked(_ line: String, _ ranges: [NSRange]) -> String {
        var out: [UTF16.CodeUnit] = []
        let units = Array(line.utf16)
        let open = Set(ranges.map(\.location)), close = Set(ranges.map(NSMaxRange))
        for k in 0...units.count {
            if close.contains(k) { out.append(UInt16(UInt8(ascii: "]"))) }
            if open.contains(k) { out.append(UInt16(UInt8(ascii: "["))) }
            if k < units.count { out.append(units[k]) }
        }
        return String(decoding: out, as: UTF16.self)
    }

    private func highlights(_ a: String, _ b: String) -> (left: [String], right: [String]) {
        let inline = Comparator.inlineChanges(a, b)
        return (highlightedTokens(a, inline?.left ?? []), highlightedTokens(b, inline?.right ?? []))
    }

    private func assertSameShape(_ pair: Pair, file: StaticString = #filePath, line: UInt = #line) {
        for row in pair.changedRows {
            let (a, b) = pair.text(row)
            XCTAssertEqual(tokens(a).count, tokens(b).count, a, file: file, line: line)
        }
    }

    /// For lines with the same shape (show output): exactly the tokens that differ
    /// position by position are highlighted, each one whole.
    private func assertPositionalTokenHighlights(_ pair: Pair, file: StaticString = #filePath, line: UInt = #line) {
        for row in pair.changedRows {
            let (a, b) = pair.text(row)
            let (ta, tb) = (tokens(a), tokens(b))
            let differing = ta.indices.filter { $0 < tb.count && ta[$0] != tb[$0] }
            let got = highlights(a, b)
            XCTAssertEqual(got.left, differing.map { ta[$0] }, a, file: file, line: line)
            XCTAssertEqual(got.right, differing.map { tb[$0] }, b, file: file, line: line)
        }
    }

    // MARK: - Sanity helpers

    private func bigrams(_ line: String) -> [UInt16] {
        let bytes = Array(line.trimmingCharacters(in: .whitespaces).utf8)
        guard bytes.count >= 2 else { return bytes.map { UInt16($0) << 8 } }
        return (0..<(bytes.count - 1)).map { UInt16(bytes[$0]) << 8 | UInt16(bytes[$0 + 1]) }.sorted()
    }

    private func dice(_ a: String, _ b: String) -> Double {
        let (x, y) = (bigrams(a), bigrams(b))
        if x.isEmpty || y.isEmpty { return x.isEmpty && y.isEmpty ? 1 : 0 }
        var i = 0, j = 0, common = 0
        while i < x.count && j < y.count {
            if x[i] == y[j] { common += 1; i += 1; j += 1 } else if x[i] < y[j] { i += 1 } else { j += 1 }
        }
        return Double(2 * common) / Double(x.count + y.count)
    }

    private func assertRebuildsBothFiles(_ pair: Pair, file: StaticString = #filePath, line: UInt = #line) {
        JuxtaCoreTests.assertRebuildsBothFiles(pair.result, leftCount: pair.left.count, rightCount: pair.right.count,
                                               file: file, line: line)
    }

    /// The first word, skipping a leading sequence number.
    private func head(_ line: String) -> Substring? {
        let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard let first = words.first else { return nil }
        return first.allSatisfy { ("0"..."9").contains($0) } ? words.dropFirst().first : first
    }

    /// A .changed pair promises the lines are versions of each other: Dice ≥ 0.5, or
    /// ≥ 0.35 for lines starting with the same word.
    private func assertNoDissimilarPairs(_ pair: Pair, file: StaticString = #filePath, line: UInt = #line) {
        let bad = pair.changedRows.map(pair.text).filter {
            dice($0.0, $0.1) < (head($0.0) == head($0.1) ? 0.35 : 0.5)
        }
        XCTAssertEqual(bad.map { "\($0.0) => \($0.1)" }, [], file: file, line: line)
    }

    // MARK: - Block boundaries

    func test30BlockInserted() throws {
        let pair = try load("30")
        XCTAssertEqual(pair.hunks, [[
            "+interface GigabitEthernet0/0/4", "+ description Customer B",
            "+ ip address 198.51.100.1 255.255.255.0", "+ negotiation auto", "+!",
        ]])
    }

    func test31BlockDeleted() throws {
        let hunks = try load("31").hunks
        XCTAssertEqual(hunks.count, 1)
        XCTAssertTrue(hunks[0].allSatisfy { $0.hasPrefix("-") })
        XCTAssertEqual(hunks[0].first, "-interface GigabitEthernet0/0/2")
        XCTAssertEqual(hunks[0].last, "-!")
    }

    func test34PrefixListEntryInserted() throws {
        XCTAssertEqual(try load("34").hunks, [["+ip prefix-list CUST-A seq 7 permit 192.0.2.128/25"]])
    }

    func test35BlockMoved() throws {
        let hunks = try load("35").hunks
        XCTAssertEqual(hunks.count, 2)
        XCTAssertEqual(hunks.first, [
            "+ip access-list extended CUST-A-IN", "+ 10 permit tcp 192.0.2.0 0.0.0.255 any eq 443",
            "+ 20 permit tcp 192.0.2.0 0.0.0.255 any eq 80", "+ 30 permit udp 192.0.2.0 0.0.0.255 any eq 53",
            "+ 40 permit icmp 192.0.2.0 0.0.0.255 any", "+ 50 deny   ip any any log", "+!",
        ])
        let deletion = try XCTUnwrap(hunks.last)
        XCTAssertTrue(deletion.allSatisfy { $0.hasPrefix("-") })
        XCTAssertEqual(deletion.count, 7)
        XCTAssertEqual(deletion.first, "-ip access-list extended CUST-A-IN")
        XCTAssertEqual(deletion.last, "-!")
    }

    func test36SectionDeleted() throws {
        let hunks = try load("36").hunks
        XCTAssertEqual(hunks.count, 1)
        XCTAssertTrue(hunks[0].allSatisfy { $0.hasPrefix("-") })
        XCTAssertEqual(hunks[0].first, "-router bgp 65001")
        XCTAssertEqual(hunks[0].last, "-!")
    }

    func test41JunosUnitInserted() throws {
        XCTAssertEqual(try load("41").hunks, [[
            "+        unit 20 {", "+            vlan-id 20;", "+            family inet {",
            "+                address 198.51.100.1/24;", "+            }", "+        }",
        ]])
    }

    func test44CFunctionInserted() throws {
        XCTAssertEqual(try load("44").hunks, [["+int mul(int a, int b)", "+{", "+    return a * b;", "+}", "+"]])
    }

    // MARK: - Pairing

    func test32ACLResequencedPairsByContent() throws {
        let pair = try load("32")
        func withoutSequence(_ line: String) -> String {
            String(line.drop { $0 == " " }.drop { $0.isNumber })
        }
        XCTAssertEqual(pair.hunks.count, 1)
        XCTAssertEqual(pair.result.rows.filter { $0.kind == .inserted }.map { pair.text($0).1 },
                       [" 20 permit tcp 192.0.2.0 0.0.0.255 any eq 22"])
        XCTAssertEqual(pair.result.rows.filter { $0.kind == .deleted }, [])
        XCTAssertEqual(pair.changedRows.count, 4)
        for row in pair.changedRows {
            let (a, b) = pair.text(row)
            XCTAssertEqual(withoutSequence(a), withoutSequence(b))
        }
        for row in pair.changedRows {
            let (a, b) = pair.text(row)
            let got = highlights(a, b)
            XCTAssertEqual(got.left, [tokens(a)[0]], a)
            XCTAssertEqual(got.right, [tokens(b)[0]], b)
        }
    }

    func test42BannerLinesPaired() throws {
        let pair = try load("42")
        XCTAssertEqual(pair.hunks, [[
            "~Authorized access only. => Authorized access only. Disconnect now if you are not authorized.",
            "~All activity is logged. => All activity is logged and monitored.",
            "+Contact noc@example.net.",
        ]])
        XCTAssertEqual(highlights("All activity is logged.", "All activity is logged and monitored.").right,
                       ["and", "monitored"])
    }

    func test43ChangesLandOnConfiguredPorts() throws {
        let pair = try load("43")
        func interface(_ lines: [String], _ index: Int32) -> String? {
            lines[...Int(index)].last { $0.hasPrefix("interface ") }
        }
        var touched = Set<String>()
        for row in pair.result.rows where row.kind != .same {
            if row.left >= 0 { touched.insert(interface(pair.left, row.left) ?? "") }
            if row.right >= 0 { touched.insert(interface(pair.right, row.right) ?? "") }
        }
        XCTAssertEqual(touched, ["interface GigabitEthernet1/0/7", "interface GigabitEthernet1/0/16"])
    }

    func test49InsertLandsUnderLineVty() throws {
        let pair = try load("49")
        XCTAssertEqual(pair.hunks, [["+ logging synchronous"]])
        let index = try XCTUnwrap(pair.result.rows.firstIndex { $0.kind == .inserted })
        let previous = pair.result.rows[index - 1]
        XCTAssertEqual(previous.kind, .same)
        XCTAssertEqual(Int(previous.left), pair.left.lastIndex(of: " exec-timeout 15 0"))
        XCTAssertEqual(pair.left[Int(previous.left) - 1], "line vty 0 4")
    }

    func test50MixedEditInBlock() throws {
        XCTAssertEqual(try load("50").hunks, [[
            "~ description Customer A =>  description Customer A (migrated)",
            "+ bandwidth 500000",
            "~ ip address 192.0.2.1 255.255.255.0 =>  ip address 192.0.2.1 255.255.255.128",
            "+ ip address 192.0.2.129 255.255.255.128 secondary",
        ]])
    }

    /// Lines stay paired despite the inserts. The 1000×1030 region is past the exact pairing
    /// limit, so this checks the key-anchored pairing.
    func test65BigChangedBlockDoesNotDrift() throws {
        try XCTSkipUnless(FileManager.default.fileExists(
            atPath: Fixtures.root.appendingPathComponent("generated/65-big-changed-block").path),
            "run scripts/make-fixtures.py")
        let pair = try load("65", in: "generated")
        assertRebuildsBothFiles(pair)
        XCTAssertEqual(pair.result.rows.filter { $0.kind == .inserted }.count, 30)
        XCTAssertEqual(pair.result.rows.filter { $0.kind == .deleted }.count, 0)
        XCTAssertTrue(pair.result.rows.filter { $0.kind == .inserted }
            .allSatisfy { pair.text($0).1.hasPrefix("S    172.17.") })
        let drifted = try pair.changedRows.filter { try prefix(pair.text($0).0) != prefix(pair.text($0).1) }
        XCTAssertEqual(drifted.count, 0)
    }

    // MARK: - Found by comparing with git (51–53)

    /// Blank-separated blocks appended after a block with the same closer take their own
    /// blank line, as git shows them, not the previous block's closer.
    func test51XRVrfAppended() throws {
        let pair = try load("51")
        XCTAssertEqual(pair.hunks, [[
            "+", "+vrf multiple-af", "+  address-family ipv4 unicast", "+    export route-target 1:13", "+  !",
            "+  address-family ipv6 unicast", "+    export route-target 1:16", "+  !", "+!",
        ]])
    }

    func test52F5RuleAppended() throws {
        let pair = try load("52")
        XCTAssertEqual(pair.hunks, [[
            "+", "+ltm rule /Common/empty {", "+}", "+", "+ltm rule /Common/empty_when {",
            "+when HTTP_REQUEST {", "+}", "+}",
        ]])
    }

    /// `next` closes a FortiOS `edit` entry; the nested `end` is deeper than `edit`, so it
    /// doesn't end the block.
    func test53FortiOSEditAppended() throws {
        let pair = try load("53")
        XCTAssertEqual(pair.hunks.first?.first, "+    edit \"secondary\"")
        XCTAssertEqual(pair.hunks.first?.last, "+    next")
        XCTAssertEqual(pair.hunks.count, 1)
        XCTAssertEqual(pair.hunks.first?.count, 10)
    }

    // MARK: - Inline highlights

    func test37HighlightsWholeTokens() throws {
        let pair = try load("37")
        XCTAssertEqual(Array(pair.hunks.joined()), [
            "~ ip address 10.0.12.1 255.255.255.252 =>  ip address 10.0.12.5 255.255.255.252",
            "~ description Uplink to core-rtr-03 =>  description Uplink to core-rtr-13",
            "~ mtu 9000 =>  mtu 9216",
            "~ ip ospf cost 10 =>  ip ospf cost 100",
            "~interface GigabitEthernet0/0/3 => interface GigabitEthernet0/0/30",
            "~ip route vrf MGMT 0.0.0.0 0.0.0.0 172.16.0.1 => ip route vrf MGMT 0.0.0.0 0.0.0.0 172.16.0.254",
            "~ exec-timeout 15 0 =>  exec-timeout 5 0",
        ])
        func assertMarked(_ a: String, _ b: String, _ expectedA: String, _ expectedB: String,
                          file: StaticString = #filePath, line: UInt = #line) {
            let inline = Comparator.inlineChanges(a, b)
            XCTAssertEqual(marked(a, inline?.left ?? []), expectedA, file: file, line: line)
            XCTAssertEqual(marked(b, inline?.right ?? []), expectedB, file: file, line: line)
        }
        assertMarked(" ip address 10.0.12.1 255.255.255.252", " ip address 10.0.12.5 255.255.255.252",
                     " ip address 10.0.12.[1] 255.255.255.252", " ip address 10.0.12.[5] 255.255.255.252")
        assertMarked("ip route vrf MGMT 0.0.0.0 0.0.0.0 172.16.0.1", "ip route vrf MGMT 0.0.0.0 0.0.0.0 172.16.0.254",
                     "ip route vrf MGMT 0.0.0.0 0.0.0.0 172.16.0.[1]", "ip route vrf MGMT 0.0.0.0 0.0.0.0 172.16.0.[254]")
        assertMarked(" description Uplink to core-rtr-03", " description Uplink to core-rtr-13",
                     " description Uplink to core-rtr-[03]", " description Uplink to core-rtr-[13]")
        assertMarked(" mtu 9000", " mtu 9216", " mtu [9000]", " mtu [9216]")
        assertMarked(" ip ospf cost 10", " ip ospf cost 100", " ip ospf cost [10]", " ip ospf cost [100]")
        assertMarked("interface GigabitEthernet0/0/3", "interface GigabitEthernet0/0/30",
                     "interface GigabitEthernet0/0/[3]", "interface GigabitEthernet0/0/[30]")
        assertMarked(" exec-timeout 15 0", " exec-timeout 5 0", " exec-timeout [15] 0", " exec-timeout [5] 0")
    }

    func test38TimestampHeader() throws {
        let pair = try load("38")
        XCTAssertEqual(pair.changedRows.count, 1)
        XCTAssertEqual(pair.result.rows.filter { $0.kind != .same }.count, 1)
        assertSameShape(pair)
        assertPositionalTokenHighlights(pair)
    }

    func test39CountersHighlightWholeNumbers() throws {
        let pair = try load("39")
        XCTAssertEqual(pair.result.rows.filter { $0.kind != .same && $0.kind != .changed }, [])
        XCTAssertEqual(pair.changedRows.count, 13)
        assertSameShape(pair)
        assertPositionalTokenHighlights(pair)
    }

    func test40RouteTable() throws {
        let pair = try load("40")
        for row in pair.changedRows {
            XCTAssertEqual(try prefix(pair.text(row).0), try prefix(pair.text(row).1))
        }
        XCTAssertEqual(try pair.result.rows.filter { $0.kind == .deleted }.map { try prefix(pair.text($0).0) },
                       ["10.0.0.10/32"])
        XCTAssertEqual(try pair.result.rows.filter { $0.kind == .inserted }.map { try prefix(pair.text($0).1) },
                       ["172.16.0.0/24", "172.16.1.0/24", "172.16.2.0/24"])
        assertSameShape(pair)
        assertPositionalTokenHighlights(pair)
    }

    // MARK: - No single right answer: sanity only

    func test33ReorderedACLSanity() throws {
        let pair = try load("33")
        assertRebuildsBothFiles(pair)
        XCTAssertEqual(pair.changedRows, [])
    }

    func test45PythonFunctionMovedSanity() throws {
        let pair = try load("45")
        assertRebuildsBothFiles(pair)
        assertNoDissimilarPairs(pair)
        // load and render swap places around summarize; keeping summarize costs 16 rows
        // (load and render each deleted and reinserted). Patience alone anchors on
        // render's 5 unique lines over summarize's 4 (22 rows); the Myers check fixes it.
        XCTAssertLessThanOrEqual(pair.result.rows.filter { $0.kind != .same }.count, 16)
    }

    func test46ProseRewrappedSanity() throws {
        let pair = try load("46")
        assertRebuildsBothFiles(pair)
        assertNoDissimilarPairs(pair)
    }

    func test47JSONKeysReorderedSanity() throws {
        let pair = try load("47")
        assertRebuildsBothFiles(pair)
        XCTAssertTrue(pair.hunks.joined().contains(
            "~  \"neighbors\": [\"10.255.0.2\", \"10.255.0.3\"], =>   \"neighbors\": [\"10.255.0.2\", \"10.255.0.3\", \"10.255.0.4\"],"))
        assertNoDissimilarPairs(pair)
    }

    func test48UnrelatedFilesSanity() throws {
        let pair = try load("48")
        assertRebuildsBothFiles(pair)
        assertNoDissimilarPairs(pair)
    }
}
