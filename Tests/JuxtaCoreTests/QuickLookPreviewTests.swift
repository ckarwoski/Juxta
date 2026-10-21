import XCTest
@testable import JuxtaCore

final class QuickLookPreviewTests: XCTestCase {
    /// 2026-10-21T18:03:12Z, whole seconds as the file stores them.
    private let date = Date(timeIntervalSince1970: 1_792_605_792)

    private func pasted(_ lines: [String], _ name: String) throws -> SavedComparison.Side {
        try SavedComparison.Side(document: TextDocument(text: lines.map { $0 + "\n" }.joined(), name: name),
                                 fileData: nil)
    }

    /// Lines "line 1" … "line N", with the given lines replaced.
    private func numbered(_ count: Int, changing changed: [Int: String] = [:]) -> [String] {
        (1...count).map { changed[$0] ?? "line \($0)" }
    }

    private func saved(_ left: [String], _ right: [String], note: String = "CHG0012345",
                       options: DiffOptions = DiffOptions()) throws -> SavedComparison {
        SavedComparison(note: note, saved: date, options: options,
                        left: try pasted(left, "pre"), right: try pasted(right, "post"))
    }

    private func page(_ data: Data) -> String {
        let html = QuickLookPreview.page(for: data)
        let parser = XMLParser(data: Data(html.utf8))
        XCTAssertTrue(parser.parse(), parser.parserError.map(String.init(describing:)) ?? "")
        return html
    }

    func testSavedComparison() throws {
        let file = try saved(numbered(40), numbered(40, changing: [20: "line 20 changed"]),
                             options: DiffOptions(ignoreCase: true))
        let html = page(file.encode())
        XCTAssertTrue(html.contains("<title>CHG0012345</title>"))
        XCTAssertTrue(html.contains("<p class=\"note\">CHG0012345</p>"))
        XCTAssertFalse(html.contains("class=\"notice\""))
        XCTAssertTrue(html.contains("<p class=\"meta\">Saved "))
        XCTAssertTrue(html.contains(" · Ignore Case</p>"))
        XCTAssertTrue(html.contains("<td class=\"where\">Pasted text · 40 lines</td>"))
        // Changes only, with 3 lines of context.
        XCTAssertTrue(html.contains("⋯ 16 unchanged lines"))
        XCTAssertTrue(html.contains("<td class=\"n\">17</td>"))
        XCTAssertFalse(html.contains("<td class=\"n\">16</td>"))
        XCTAssertTrue(html.contains("<td class=\"n c\">20</td>"))

        // The same page the export makes for the file.
        let (left, right) = try file.documents()
        var report = HTMLReport(left: left, right: right,
                                result: Comparator.compare(left.lines, right.lines, options: file.options),
                                options: file.options)
        report.describe(try SavedComparison(data: file.encode()))
        report.extent = .context(3)
        XCTAssertEqual(html, report.render())
    }

    func testEditedSide() throws {
        let data = try saved(["a", "b"], ["a", "c"]).encode()
        let edited = Data(String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "\nc\n", with: "\nC\n").utf8)
        let html = page(edited)
        XCTAssertTrue(html.contains("<p class=\"notice\">The right side was edited after it was saved</p>"))
        // The page shows the edited bytes.
        XCTAssertTrue(html.contains("<td class=\"t i\">C</td>"))
    }

    func testChangeLimit() throws {
        let count = QuickLookPreview.changeLimit + 50
        let changed = Dictionary(uniqueKeysWithValues: (1...count).map { ($0 * 10, "line \($0 * 10) changed") })
        let html = page(try saved(numbered(count * 10 + 5), numbered(count * 10 + 5, changing: changed)).encode())
        XCTAssertTrue(html.contains("<p class=\"more\">50 more changes not shown</p>"))
        XCTAssertTrue(html.contains("<td class=\"n c\">2000</td>"))
        XCTAssertFalse(html.contains("<td class=\"n c\">2010</td>"))
        XCTAssertTrue(html.contains("250 changes · 250 modified"))
    }

    func testRowLimit() throws {
        let count = QuickLookPreview.rowLimit + 100
        let html = page(try saved(numbered(count), numbered(count).map { $0 + " changed" }).encode())
        XCTAssertTrue(html.contains("<p class=\"more\">100 more rows of this change not shown</p>"))
        XCTAssertTrue(html.contains("<td class=\"n c\">5000</td>"))
        XCTAssertFalse(html.contains("<td class=\"n c\">5001</td>"))
    }

    func testByteLimit() throws {
        let long = String(repeating: "x", count: 2_000)
        let html = page(try saved(numbered(2_000).map { $0 + " " + long },
                                      numbered(2_000).map { $0 + " changed " + long }).encode())
        XCTAssertLessThan(html.utf8.count, QuickLookPreview.byteLimit + 100_000)
        let shown = html.components(separatedBy: "<td class=\"n c\">").count / 2
        XCTAssertTrue(html.contains("<p class=\"more\">\((2_000 - shown).formatted()) more rows of this change not shown</p>"))
    }

    func testNoPathsEvenWithFileSources() throws {
        let leftURL = try Fixtures.file("44", "left"), rightURL = try Fixtures.file("44", "right")
        let leftData = try Data(contentsOf: leftURL), rightData = try Data(contentsOf: rightURL)
        let file = try SavedComparison(
            saving: try TextDocument(fileData: leftData, name: "left.c", url: leftURL),
            try TextDocument(fileData: rightData, name: "right.c", url: rightURL),
            fileData: (leftData, rightData), options: DiffOptions())
        let reopened = try SavedComparison(data: file.encode())
        XCTAssertEqual(reopened.left.path, leftURL.path)
        let report = try QuickLookPreview.report(for: file.encode())
        XCTAssertNil(report.leftPath)
        XCTAssertNil(report.rightPath)
        let html = page(file.encode())
        XCTAssertFalse(html.contains(Fixtures.root.path))
        XCTAssertFalse(html.contains(HTMLReport.displayPath(Fixtures.root.path)))
        XCTAssertFalse(html.contains("44-c-function-inserted"))
        XCTAssertTrue(html.contains("<td class=\"where\">File · 17 lines</td>"))
    }

    func testBadFileGetsAnErrorPage() throws {
        let data = try saved(["a"], ["b"]).encode()
        let newer = Data(String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "juxta-comparison 1", with: "juxta-comparison 2").utf8)
        XCTAssertTrue(page(newer).contains(
            "<p class=\"notice\">This comparison was saved by a newer version of Juxta (format 2).</p>"))
        XCTAssertTrue(page(data.prefix(data.count - 3)).contains("run past the end of the file"))
        XCTAssertTrue(page(Data()).contains("<h1>Can’t show this comparison</h1>"))
        // The reason is escaped: a missing key's name comes from the code, but a binary
        // side's name comes from the file.
        let binary = SavedComparison(saved: date, options: DiffOptions(),
                                     left: SavedComparison.Side(name: "<b>&", source: .file("/x"), bytes: Data([0, 1, 2, 0])),
                                     right: try pasted(["b"], "post"))
        let html = page(binary.encode())
        XCTAssertTrue(html.contains("“&lt;b&gt;&amp;” appears to be a binary file."))
    }
}
