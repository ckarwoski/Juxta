import XCTest
@testable import JuxtaCore

/// Loader and "never claim identical" checks driven by Fixtures/pairs.
final class FixtureTests: XCTestCase {
    private func file(_ pair: String, _ side: String) throws -> URL { try Fixtures.file(pair, side) }

    private func load(_ pair: String) throws -> (TextDocument, TextDocument) {
        (try TextDocument.load(from: file(pair, "left")), try TextDocument.load(from: file(pair, "right")))
    }

    /// Same lines on both sides; the only differences are the given format aspects.
    private func assertHiddenOnly(_ pair: String, _ aspects: [TextFormat.Aspect],
                                  file: StaticString = #filePath, line: UInt = #line) throws {
        let (left, right) = try load(pair)
        XCTAssertEqual(left.lines, right.lines, file: file, line: line)
        XCTAssertTrue(Comparator.compare(left.lines, right.lines).isIdentical, file: file, line: line)
        XCTAssertEqual(left.hiddenDifferences(from: right), aspects, file: file, line: line)
        XCTAssertEqual(left.isByteIdentical(to: right), false, file: file, line: line)
    }

    func testLineEndings() throws {
        try assertHiddenOnly("01", [.lineEndings])
        try assertHiddenOnly("02", [.lineEndings])
        try assertHiddenOnly("03", [.lineEndings])
        let (lf, cr) = try load("02")
        XCTAssertEqual(cr.lines.count, 11)
        XCTAssertEqual(cr.format?.lineEndings, .cr)
        XCTAssertEqual(lf.format?.label(for: .lineEndings), "LF")
        XCTAssertEqual(try load("03").0.format?.label(for: .lineEndings), "mixed line endings")
    }

    func testFinalNewlineAndBOM() throws {
        try assertHiddenOnly("04", [.finalNewline])
        try assertHiddenOnly("05", [.byteOrderMark])
        XCTAssertEqual(try load("04").1.format?.label(for: .finalNewline), "no final newline")
    }

    func testEncodings() throws {
        try assertHiddenOnly("06", [.encoding])
        XCTAssertEqual(try load("06").0.format?.encoding, .utf16LittleEndian)
        try assertHiddenOnly("07", [.encoding])
        XCTAssertEqual(try load("07").0.format?.encoding, .utf16BigEndian)
        try assertHiddenOnly("08", [.encoding])
        XCTAssertEqual(try load("08").0.format?.encoding, .windowsLatin1)
        XCTAssertTrue(try load("08").0.lines.contains(" description Café Zürich - uplink"))
    }

    func testInvalidUTF8OnlyAffectsItsOwnLine() throws {
        let (left, right) = try load("09")
        XCTAssertEqual(right.format?.encoding, .invalidUTF8)
        let differing = left.lines.indices.filter { left.lines[$0] != right.lines[$0] }
        XCTAssertEqual(differing.count, 1)
        XCTAssertTrue(right.lines.contains(" description Café Zürich – uplink"))
    }

    func testBinaryDetection() throws {
        let (left, right) = try load("10")
        XCTAssertEqual(left.lines.count, 200)
        XCTAssertEqual(right.lines.count, 200)
        XCTAssertThrowsError(try TextDocument.load(from: file("11", "left"))) { error in
            XCTAssertEqual(error.localizedDescription, "“left.bin” appears to be a binary file.")
        }
    }

    func testIdenticalFiles() throws {
        for pair in ["12", "14"] {
            let (left, right) = try load(pair)
            XCTAssertTrue(Comparator.compare(left.lines, right.lines).isIdentical)
            XCTAssertEqual(left.hiddenDifferences(from: right), [])
            XCTAssertEqual(left.isByteIdentical(to: right), true)
        }
    }

    func testUnicodeNormalizationIsADifference() throws {
        let (left, right) = try load("19")
        let result = Comparator.compare(left.lines, right.lines)
        XCTAssertEqual(result.changedLines, 4)
        XCTAssertTrue(Comparator.compare(["Caf\u{E9}"], ["Cafe\u{301}"]).hunks.count == 1)
    }

    func testIgnoreTimersLeavesOnlyRealChanges() throws {
        let timers = DiffOptions(ignoreTimers: true)
        func compare(_ pair: String, _ options: DiffOptions = DiffOptions()) throws -> DiffResult {
            let (left, right) = try load(pair)
            let result = Comparator.compare(left.lines, right.lines, options: options)
            assertRebuildsBothFiles(result, leftCount: left.lines.count, rightCount: right.lines.count, pair)
            return result
        }
        // Route ages: only the adds and deletes are left.
        let routes = try compare("40", timers)
        XCTAssertEqual([routes.changedLines, routes.deletedLines, routes.insertedLines], [0, 1, 3])
        XCTAssertEqual(routes.hunks.count, 2)
        let added = try compare("22", timers)
        XCTAssertEqual(added.hunks.count, 1)
        XCTAssertEqual([added.changedLines, added.deletedLines, added.insertedLines], [0, 0, 1])
        XCTAssertGreaterThan(try compare("22").changedLines, 30)

        // Show output: the real changes among look-alikes stay, highlighted without the timers.
        let show = try compare("23", timers)
        XCTAssertEqual([show.changedLines, show.deletedLines, show.insertedLines], [6, 0, 0])
        XCTAssertEqual(try compare("23").changedLines, 11)
        let (left, right) = try load("23")
        func lit(_ prefix: String) throws -> [String] {
            let a = try XCTUnwrap(left.lines.first { $0.hasPrefix(prefix) })
            let b = try XCTUnwrap(right.lines.first { $0.hasPrefix(prefix) })
            let inline = try XCTUnwrap(Comparator.inlineChanges(a, b, options: timers), prefix)
            return inline.right.map { (b as NSString).substring(with: $0) }
        }
        XCTAssertEqual(try lit("10.255.0.3        1"), ["INIT/DROTHER"])
        XCTAssertEqual(try lit("10.255.0.3      4"), ["Idle"])

        // show interfaces: the four Last input lines drop out; counters still show.
        XCTAssertEqual(try compare("39", timers).changedLines, try compare("39").changedLines - 4)
    }

    /// The rule behind all of the above: if two files' bytes differ, Juxta must show it,
    /// either as changed lines or as a hidden (format) difference.
    func testDifferentBytesAreNeverReportedIdentical() throws {
        let dirs = try FileManager.default.contentsOfDirectory(at: Fixtures.pairs, includingPropertiesForKeys: nil)
        XCTAssertGreaterThan(dirs.count, 40)
        for dir in dirs where !dir.lastPathComponent.hasPrefix("11-") {
            let name = dir.lastPathComponent
            let (left, right) = try load(String(name.prefix(2)))
            let bytesDiffer = try Data(contentsOf: file(String(name.prefix(2)), "left"))
                != Data(contentsOf: file(String(name.prefix(2)), "right"))
            let result = Comparator.compare(left.lines, right.lines)
            let shown = !result.isIdentical || !left.hiddenDifferences(from: right).isEmpty
                || left.isByteIdentical(to: right) == false
            XCTAssertEqual(shown, bytesDiffer, name)
            XCTAssertEqual(left.isByteIdentical(to: right), !bytesDiffer, name)
            assertRebuildsBothFiles(result, leftCount: left.lines.count, rightCount: right.lines.count, name)
        }
    }

    func testUTF16WithoutBOM() throws {
        let text = "interface Gi0/1\n description uplink\n"
        let le = try TextDocument(fileData: Data(text.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }),
                                  name: "le")
        XCTAssertEqual(le.lines, ["interface Gi0/1", " description uplink"])
        XCTAssertEqual(le.format?.encoding, .utf16LittleEndian)
        XCTAssertEqual(le.format?.label(for: .byteOrderMark), "no BOM")
        let be = try TextDocument(fileData: Data(text.utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }),
                                  name: "be")
        XCTAssertEqual(be.lines, le.lines)
        XCTAssertEqual(be.format?.encoding, .utf16BigEndian)
    }

    func testPastedTextHasNoFormat() {
        let pasted = TextDocument(text: "a\r\nb\r\n", name: "Pasted Text")
        XCTAssertEqual(pasted.lines, ["a", "b"])
        XCTAssertNil(pasted.format)
        XCTAssertNil(pasted.digest)
    }
}
