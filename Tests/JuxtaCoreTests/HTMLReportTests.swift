import XCTest
@testable import JuxtaCore

final class HTMLReportTests: XCTestCase {
    /// 2026-10-21T18:03:12Z.
    private let date = Date(timeIntervalSince1970: 1_792_605_792)

    private func report(_ left: TextDocument, _ right: TextDocument, options: DiffOptions = DiffOptions(),
                        extent: HTMLReport.Extent = .context(3)) -> HTMLReport {
        let result = Comparator.compare(left.lines, right.lines, options: options)
        var report = HTMLReport(left: left, right: right, result: result, options: options)
        report.date = date
        report.timeZone = TimeZone(identifier: "UTC")!
        report.locale = Locale(identifier: "en_US_POSIX")
        report.extent = extent
        return report
    }

    private func pasted(_ lines: [String], _ name: String) -> TextDocument {
        TextDocument(text: lines.map { $0 + "\n" }.joined(), name: name)
    }

    /// Lines "line 1" … "line N", with the given lines replaced.
    private func numbered(_ count: Int, changing changed: [Int: String] = [:]) -> [String] {
        (1...count).map { changed[$0] ?? "line \($0)" }
    }

    private func body(_ html: String) -> String {
        let start = html.range(of: "<body>\n")!.upperBound, end = html.range(of: "</body>")!.lowerBound
        return String(html[start..<end])
    }

    private func occurrences(_ text: String, in html: String) -> Int {
        html.components(separatedBy: text).count - 1
    }

    private func assertWellFormed(_ html: String, _ message: String = "", file: StaticString = #filePath,
                                  line: UInt = #line) {
        let parser = XMLParser(data: Data(html.utf8))
        XCTAssertTrue(parser.parse(), "\(message): \(parser.parserError.map(String.init(describing:)) ?? "")",
                      file: file, line: line)
    }

    // MARK: - Goldens

    /// Fixtures/html/<name>.html holds the expected body; JUXTA_UPDATE_GOLDENS=1 rewrites it.
    private func assertGolden(_ html: String, _ name: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let url = Fixtures.root.appendingPathComponent("html").appendingPathComponent(name + ".html")
        let actual = body(html)
        if ProcessInfo.processInfo.environment["JUXTA_UPDATE_GOLDENS"] != nil {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try actual.write(to: url, atomically: true, encoding: .utf8)
        }
        // Date formatting puts a narrow no-break space before "PM" on some systems.
        func normalized(_ text: String) -> String { text.replacingOccurrences(of: "\u{202F}", with: " ") }
        XCTAssertEqual(normalized(actual), normalized(try String(contentsOf: url, encoding: .utf8)), name,
                       file: file, line: line)
    }

    private func fixture44(_ extent: HTMLReport.Extent, paths: Bool) throws -> String {
        let left = try TextDocument.load(from: Fixtures.file("44", "left"))
        let right = try TextDocument.load(from: Fixtures.file("44", "right"))
        var page = report(left, right, extent: extent)
        if paths {
            // Under the home folder, so the golden is the same on every machine.
            page.leftPath = HTMLReport.displayPath(NSHomeDirectory() + "/captures/left.c")
            page.rightPath = HTMLReport.displayPath(NSHomeDirectory() + "/captures/right.c")
        }
        page.note = "CHG0012345"
        return page.render()
    }

    func testGoldenWithContext() throws {
        try assertGolden(try fixture44(.context(2), paths: true), "44-context-2")
    }

    func testGoldenAllLines() throws {
        try assertGolden(try fixture44(.all, paths: false), "44-all")
    }

    func testPathsOnlyWhenGiven() throws {
        let left = try TextDocument.load(from: Fixtures.file("44", "left"))
        let page = report(left, left)
        XCTAssertNil(page.leftPath)
        let html = page.render()
        XCTAssertFalse(html.contains(Fixtures.root.path))
        XCTAssertTrue(html.contains("<td class=\"where\">File · 17 lines</td>"))
        XCTAssertEqual(HTMLReport.displayPath(NSHomeDirectory() + "/a b/c.cfg"), "~/a b/c.cfg")
        XCTAssertEqual(HTMLReport.displayPath("/etc/hosts"), "/etc/hosts")
        XCTAssertTrue(try fixture44(.all, paths: true).contains("~/captures/left.c · 17 lines"))
    }

    func testCountsFollowTheLocale() {
        let lines = numbered(1_200)
        let changed = lines.map { $0 + " x" }
        var page = report(pasted(lines, "a"), pasted(changed, "b"))
        page.locale = Locale(identifier: "de_DE")
        let html = page.render()
        let summary = html.components(separatedBy: "\n").first { $0.contains("class=\"summary") } ?? ""
        XCTAssertTrue(html.contains("1 change · 1.200 modified"), summary)
        XCTAssertTrue(html.contains("Pasted text · 1.200 lines"))
        let same = report(pasted(lines, "a"), pasted(lines, "b"))
        var german = same
        german.locale = Locale(identifier: "de_DE")
        XCTAssertTrue(german.render().contains("⋯ 1.200 unchanged lines"))
        var english = same
        english.locale = Locale(identifier: "en_US")
        XCTAssertTrue(english.render().contains("⋯ 1,200 unchanged lines"))
    }

    // MARK: - Content

    func testEverythingIsEscaped() {
        let banner = #"banner motd ^C <b>"Authorized" & monitored</b> ^C"#
        let left = pasted(["hostname r1", banner, "end"], #"pre <"r1"> & co"#)
        let right = pasted(["hostname r1", banner.replacingOccurrences(of: "monitored", with: "logged"), "end"],
                           "post")
        var page = report(left, right)
        page.note = #"CHG <1> & "2""#
        page.leftPath = "/tmp/a&b/<c>.txt"
        let html = page.render()
        assertWellFormed(html)
        XCTAssertTrue(html.contains("<title>CHG &lt;1&gt; &amp; &quot;2&quot;</title>"))
        XCTAssertTrue(html.contains("pre &lt;&quot;r1&quot;&gt; &amp; co"))
        XCTAssertTrue(html.contains("/tmp/a&amp;b/&lt;c&gt;.txt"))
        XCTAssertTrue(html.contains("banner motd ^C &lt;b&gt;&quot;Authorized&quot; &amp; "))
        XCTAssertFalse(body(html).contains("<b>"))
    }

    func testCloseChangesShareContext() {
        let left = pasted(numbered(30), "a")
        // Changes at lines 5 and 10: four lines apart, under 2 × 3.
        let close = report(left, pasted(numbered(30, changing: [5: "five", 10: "ten"]), "b")).render()
        XCTAssertEqual(occurrences("class=\"skip\"", in: close), 1)
        XCTAssertTrue(close.contains("⋯ 1 unchanged line") == false)
        XCTAssertTrue(close.contains("⋯ 17 unchanged lines"))
        // Changes at lines 5 and 20: their context doesn't meet, so a separator goes between.
        let apart = report(left, pasted(numbered(30, changing: [5: "five", 20: "twenty"]), "b")).render()
        let skips = apart.components(separatedBy: "\n").filter { $0.contains("class=\"skip\"") }
        XCTAssertEqual(skips.map { $0.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression) },
                       ["⋯ 8 unchanged lines", "⋯ 7 unchanged lines"])
        // Line 1 alone before the first change is shown, not replaced by a separator.
        XCTAssertTrue(apart.contains("<td class=\"n\">1</td>"))
    }

    func testFillerRows() {
        let left = pasted(numbered(10), "a")
        var lines = numbered(10)
        lines.insert(contentsOf: ["new 1", "new 2"], at: 4)
        lines.remove(at: 8)
        let html = report(left, pasted(lines, "b"), extent: .all).render()
        let result = Comparator.compare(left.lines, lines)
        XCTAssertEqual(occurrences("<td class=\"t f\"></td>", in: html), result.insertedLines + result.deletedLines)
        XCTAssertEqual(occurrences("<td class=\"s i\">+</td>", in: html), result.insertedLines)
        XCTAssertEqual(occurrences("<td class=\"s d\">−</td>", in: html), result.deletedLines)
    }

    func testIdentical() throws {
        let left = try TextDocument.load(from: Fixtures.file("14", "left"))
        let right = try TextDocument.load(from: Fixtures.file("14", "right"))
        let html = report(left, right).render()
        XCTAssertTrue(html.contains("<p class=\"summary same\">Files are identical</p>"))
        XCTAssertEqual(occurrences("<tr", in: body(html).components(separatedBy: "<table class=\"diff\">")[1]), 1)
        XCTAssertTrue(html.contains("⋯ \(left.lines.count) unchanged lines"))
        // All lines shows them all.
        XCTAssertEqual(occurrences("<tr><td class=\"n\">", in: report(left, right, extent: .all).render()),
                       left.lines.count)
        // Same text in another encoding says so.
        let encoded = report(try TextDocument.load(from: Fixtures.file("06", "left")),
                             try TextDocument.load(from: Fixtures.file("06", "right"))).render()
        XCTAssertTrue(encoded.contains("<p class=\"summary same\">Same text · differs in encoding</p>"))
        XCTAssertTrue(encoded.contains("<strong>UTF-16 LE</strong>"))
    }

    func testChangeLimit() {
        let left = pasted(numbered(100), "a")
        let changed = Dictionary(uniqueKeysWithValues: [10, 30, 50, 70, 90].map { ($0, "line \($0) changed") })
        for extent in [HTMLReport.Extent.context(3), .all] {
            var page = report(left, pasted(numbered(100, changing: changed), "b"), extent: extent)
            page.changeLimit = 2
            let html = page.render()
            assertWellFormed(html)
            XCTAssertTrue(html.contains("<p class=\"more\">3 more changes not shown</p>"), "\(extent)")
            XCTAssertTrue(html.contains("<td class=\"n c\">30</td>"))
            XCTAssertFalse(html.contains("<td class=\"n c\">50</td>"))
            // Nothing after the last change shown is counted as unchanged.
            XCTAssertFalse(html.contains("⋯ 67 unchanged lines"))
            XCTAssertTrue(html.contains("5 changes · 5 modified"))
        }
        var page = report(left, pasted(numbered(100, changing: [10: "x"]), "b"))
        page.changeLimit = 1
        XCTAssertFalse(page.render().contains("class=\"more\""))
    }

    func testInlineHighlightsAtTheirOffsets() {
        let pairs = [("description Café Zürich – uplink", "description Cafe Zürich – uplink"),
                     ("name 😀 and Zoë here", "name 😀 and Zoe here"),
                     ("a <b> & c", "a <b> & d")]
        for (a, b) in pairs {
            let html = report(pasted([a], "a"), pasted([b], "b")).render()
            assertWellFormed(html, a)
            let inline = Comparator.inlineChanges(a, b)!
            for (line, ranges) in [(a, inline.left), (b, inline.right)] where !ranges.isEmpty {
                for range in ranges {
                    var expected = ""
                    HTMLReport.appendEscaped((line as NSString).substring(with: range), to: &expected)
                    XCTAssertTrue(html.contains("<span class=\"h\">\(expected)</span>"), "\(expected) in \(line)")
                }
            }
        }
    }

    func testInvisiblesAndTrailingWhitespace() {
        var out = ""
        HTMLReport.appendLine("a\u{200B}b\u{00A0}c  ", highlights: [NSRange(location: 1, length: 1)],
                              marksInvisibles: true, marksTrailing: true, to: &out)
        XCTAssertEqual(out, #"a<span class="h"><span class="b">U+200B</span></span>b<span class="u" title="U+00A0">"#
                       + "\u{00A0}</span>c<span class=\"w\">  </span>")
        // On unchanged rows only characters that can't be in the page get badges.
        out = ""
        HTMLReport.appendLine("x\u{1}y\u{200B}z\t", highlights: [], marksInvisibles: false, marksTrailing: false, to: &out)
        XCTAssertEqual(out, "x<span class=\"b\">SOH</span>y\u{200B}z\t")
        // A highlight crossing into trailing whitespace is closed and reopened, so they nest.
        out = ""
        HTMLReport.appendLine("ab  ", highlights: [NSRange(location: 1, length: 2)],
                              marksInvisibles: true, marksTrailing: true, to: &out)
        XCTAssertEqual(out, #"a<span class="h">b</span><span class="w"><span class="h"> </span></span><span class="w"> </span>"#)
        // A highlight that ends with the line leaves no empty span behind.
        out = ""
        HTMLReport.appendLine("ab  ", highlights: [NSRange(location: 3, length: 1)],
                              marksInvisibles: true, marksTrailing: true, to: &out)
        XCTAssertEqual(out, #"ab<span class="w"> </span><span class="w"><span class="h"> </span></span>"#)
        XCTAssertFalse(out.contains("<span class=\"w\"></span>"))
        assertWellFormed("<p>" + out + "</p>")
    }

    func testEveryFixtureIsWellFormed() throws {
        let dirs = try FileManager.default.contentsOfDirectory(at: Fixtures.pairs, includingPropertiesForKeys: nil)
        for dir in dirs {
            let pair = String(dir.lastPathComponent.prefix(2))
            let left: TextDocument, right: TextDocument
            do {
                (left, right) = (try TextDocument.load(from: Fixtures.file(pair, "left")),
                                 try TextDocument.load(from: Fixtures.file(pair, "right")))
            } catch TextLoadError.binary {
                continue
            }
            for extent in [HTMLReport.Extent.context(3), .all] {
                assertWellFormed(report(left, right, options: DiffOptions(ignoreTimers: true), extent: extent).render(),
                                 dir.lastPathComponent)
            }
        }
    }

    func testHeader() {
        var page = report(pasted(["a"], "pre"), pasted(["b"], "post"), options: DiffOptions(ignoreTimers: true))
        page.dateLabel = "Saved"
        page.notices = ["The right side was edited after it was saved"]
        let html = page.render()
        XCTAssertTrue(html.contains("<p class=\"meta\">Saved Oct 21, 2026 at 6:03\u{202F}PM · Ignore Timers</p>")
                      || html.contains("<p class=\"meta\">Saved Oct 21, 2026 at 6:03 PM · Ignore Timers</p>"), html)
        XCTAssertTrue(html.contains("<p class=\"notice\">The right side was edited after it was saved</p>"))
        XCTAssertTrue(html.contains("Pasted text · 1 line"))
        XCTAssertFalse(html.contains("<script"))
        XCTAssertFalse(html.contains("http"))
    }
}
