import XCTest
@testable import JuxtaCore

final class SavedComparisonTests: XCTestCase {
    /// 2026-10-21T18:03:12Z, whole seconds as the file stores them.
    private let date = Date(timeIntervalSince1970: 1_792_605_792)

    private func pasted(_ text: String, _ name: String = "Pasted Text") throws -> SavedComparison.Side {
        try SavedComparison.Side(document: TextDocument(text: text, name: name), fileData: nil)
    }

    private func sample(left: String = "a\nb\n", right: String = "a\nc\n") throws -> SavedComparison {
        SavedComparison(note: "CHG0012345", saved: date, options: DiffOptions(),
                        left: try pasted(left, "pre"), right: try pasted(right, "post"))
    }

    private func reopen(_ saved: SavedComparison) throws -> SavedComparison {
        try SavedComparison(data: saved.encode())
    }

    func testFixturePairsRoundTrip() throws {
        let dirs = try FileManager.default.contentsOfDirectory(at: Fixtures.pairs, includingPropertiesForKeys: nil)
        var checked = 0
        for dir in dirs {
            let name = dir.lastPathComponent, pair = String(name.prefix(2))
            let urls = (try Fixtures.file(pair, "left"), try Fixtures.file(pair, "right"))
            let left: TextDocument, right: TextDocument
            do {
                (left, right) = (try TextDocument.load(from: urls.0), try TextDocument.load(from: urls.1))
            } catch TextLoadError.binary {
                continue
            }
            let saved = SavedComparison(
                saved: date, options: DiffOptions(),
                left: try .init(document: left, fileData: Data(contentsOf: urls.0)),
                right: try .init(document: right, fileData: Data(contentsOf: urls.1)))
            let reopened = try reopen(saved)
            let (newLeft, newRight) = try reopened.documents()
            for (side, url) in [(reopened.left, urls.0), (reopened.right, urls.1)] {
                XCTAssertEqual(side.bytes, try Data(contentsOf: url), name)
                XCTAssertTrue(side.matchesDigest, name)
                XCTAssertEqual(side.source, .file(url.path), name)
            }
            for (new, original) in [(newLeft, left), (newRight, right)] {
                XCTAssertEqual(new.lines, original.lines, name)
                XCTAssertEqual(new.format, original.format, name)
                XCTAssertEqual(new.digest, original.digest, name)
                XCTAssertEqual(new.name, original.name, name)
                XCTAssertNil(new.url, name)
            }
            XCTAssertEqual(newLeft.hiddenDifferences(from: newRight), left.hiddenDifferences(from: right), name)
            XCTAssertEqual(newLeft.isByteIdentical(to: newRight), left.isByteIdentical(to: right), name)
            checked += 1
        }
        XCTAssertGreaterThan(checked, 40)
    }

    func testPastedSideStaysPasted() throws {
        // A trailing empty line and CRLF input: pasted text keeps its lines, not its bytes.
        let saved = try sample(left: "one\r\ntwo\r\n\r\n", right: "")
        XCTAssertEqual(saved.left.bytes, Data("one\ntwo\n\n".utf8))
        let reopened = try reopen(saved)
        XCTAssertEqual(reopened.left.source, .pasted)
        let (left, right) = try reopened.documents()
        XCTAssertEqual(left.lines, ["one", "two", ""])
        XCTAssertEqual(left.name, "pre")
        XCTAssertNil(left.format)
        XCTAssertNil(left.digest)
        XCTAssertEqual(right.lines, [])
        XCTAssertNil(left.isByteIdentical(to: right))
    }

    func testNewlinesInValuesAreSavedAsSpaces() throws {
        var saved = try sample()
        saved.note = "CHG0012345\npost-change\r\ncore1\rdone"
        saved.left.name = "show ip bgp\nsummary"
        let header = String(decoding: saved.encode(), as: UTF8.self)
        XCTAssertTrue(header.contains("\nnote: CHG0012345 post-change core1 done\n"))
        XCTAssertTrue(header.contains("\nname: show ip bgp summary\n"))
        let reopened = try reopen(saved)
        XCTAssertEqual(reopened.note, "CHG0012345 post-change core1 done")
        XCTAssertEqual(reopened.left.name, "show ip bgp summary")
    }

    func testOptionsAndDateRoundTrip() throws {
        var saved = try sample()
        let text = String(decoding: saved.encode(), as: UTF8.self)
        // The offset depends on the time zone the test runs in.
        XCTAssertNotNil(text.range(of: #"^juxta-comparison 1\nsaved: \d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(Z|[+-]\d\d:\d\d)\n"#,
                                   options: .regularExpression), text)
        XCTAssertTrue(text.contains("\noptions:\n"))
        XCTAssertEqual(try reopen(saved).options, DiffOptions())
        for options in [DiffOptions(ignoreTimers: true),
                        DiffOptions(ignoreWhitespace: true, ignoreCase: true, ignoreTimers: true)] {
            saved.options = options
            let reopened = try reopen(saved)
            XCTAssertEqual(reopened.options, options)
            XCTAssertEqual(reopened.saved, date)
            XCTAssertEqual(reopened.note, "CHG0012345")
        }
        XCTAssertTrue(String(decoding: saved.encode(), as: UTF8.self)
            .contains("\noptions: ignore-whitespace ignore-case ignore-timers\n"))
    }

    func testFormatMatchesTheSpec() throws {
        let saved = try sample(left: "x\n", right: "y")
        let text = String(decoding: saved.encode(), as: UTF8.self)
        XCTAssertTrue(text.hasSuffix("""

            left
            name: pre
            source: pasted
            bytes: 2
            sha256: \(saved.left.sha256)

            right
            name: post
            source: pasted
            bytes: 2
            sha256: \(saved.right.sha256)

            --- left
            x

            --- right
            y


            """), text)
    }

    func testBodyContainingMarkerParses() throws {
        let tricky = "a\n--- right\nb\n--- left\nbytes: 3\n"
        let reopened = try reopen(try sample(left: tricky, right: tricky))
        XCTAssertEqual(reopened.left.bytes, Data(tricky.utf8))
        XCTAssertEqual(reopened.right.bytes, Data(tricky.utf8))
        XCTAssertTrue(reopened.left.matchesDigest)
    }

    func testOddFileBytesRoundTrip() throws {
        // CR only, no final newline, and UTF-16 whose bytes include 0x0A.
        let bodies = [Data("x\ry\r\n--- right".utf8), Data([0xFF, 0xFE, 0x0A, 0x00, 0x41, 0x00])]
        for body in bodies {
            let document = try TextDocument(fileData: body, name: "f")
            let side = try SavedComparison.Side(document: document, fileData: body)
            let reopened = try reopen(SavedComparison(saved: date, options: DiffOptions(), left: side, right: side))
            XCTAssertEqual(reopened.left.bytes, body)
            XCTAssertEqual(reopened.right.bytes, body)
            XCTAssertEqual(try reopened.documents().left.lines, document.lines)
        }
    }

    func testSavingChangedFileThrows() throws {
        let document = try TextDocument(fileData: Data("a\n".utf8), name: "post.txt")
        XCTAssertThrowsError(try SavedComparison.Side(document: document, fileData: Data("b\n".utf8))) { error in
            XCTAssertEqual(error.localizedDescription, "“post.txt” changed since it was loaded.")
        }
        XCTAssertThrowsError(try SavedComparison.Side(document: document, fileData: nil)) { error in
            XCTAssertEqual(error.localizedDescription, "“post.txt” can’t be found where it was loaded from.")
        }
        XCTAssertNoThrow(try SavedComparison.Side(document: document, fileData: Data("a\n".utf8)))
    }

    func testFileWithoutURLUsesItsNameAsSource() throws {
        let document = try TextDocument(fileData: Data("a\n".utf8), name: "-")
        let side = try SavedComparison.Side(document: document, fileData: Data("a\n".utf8))
        XCTAssertEqual(side.source, .file("-"))
    }

    func testZeroByteFileSide() throws {
        let document = try TextDocument(fileData: Data(), name: "empty.txt")
        let side = try SavedComparison.Side(document: document, fileData: Data())
        let reopened = try reopen(SavedComparison(saved: date, options: DiffOptions(), left: side, right: side))
        XCTAssertEqual(reopened.left.bytes, Data())
        XCTAssertTrue(reopened.right.matchesDigest)
        let (left, right) = try reopened.documents()
        XCTAssertEqual(left.lines, [])
        XCTAssertEqual(left.format, document.format)
        XCTAssertEqual(left.isByteIdentical(to: right), true)
    }

    func testParsesASlice() throws {
        let data = Data([0xAA, 0xBB]) + (try sample()).encode()
        let slice = data.dropFirst(2)
        XCTAssertEqual(slice.startIndex, 2)
        let reopened = try SavedComparison(data: slice)
        XCTAssertEqual(reopened.left.bytes.startIndex, 0)
        XCTAssertEqual(reopened.right.bytes, Data("a\nc\n".utf8))
        XCTAssertTrue(reopened.right.matchesDigest)
    }

    // MARK: - Saving again

    /// File sides on both sides, as they come back from a `.juxta` file.
    private func reopenedFiles() throws -> SavedComparison {
        let left = Data("one\r\ntwo\r\n".utf8), right = Data("one\nthree".utf8)
        func side(_ data: Data, _ name: String) throws -> SavedComparison.Side {
            let document = try TextDocument(fileData: data, name: name, url: URL(fileURLWithPath: "/captures/\(name)"))
            return try .init(document: document, fileData: data)
        }
        let saved = SavedComparison(saved: date, options: DiffOptions(),
                                    left: try side(left, "pre.txt"), right: try side(right, "post.txt"))
        return try reopen(saved)
    }

    func testResavingAReopenedComparison() throws {
        let reopened = try reopenedFiles()
        var (left, right) = try reopened.documents()
        left.name = "core1 pre"
        let again = SavedComparison(
            saved: date, options: DiffOptions(),
            left: try .init(document: left, fileData: nil, previous: [reopened.left]),
            right: try .init(document: right, fileData: nil, previous: [reopened.right]))
        let twice = try reopen(again)
        XCTAssertEqual(twice.left.bytes, reopened.left.bytes)
        XCTAssertEqual(twice.right.bytes, reopened.right.bytes)
        XCTAssertEqual(twice.left.source, .file("/captures/pre.txt"))
        XCTAssertEqual(twice.right.source, .file("/captures/post.txt"))
        XCTAssertEqual(twice.left.name, "core1 pre")
        XCTAssertEqual(try twice.documents().left.format, try reopened.documents().left.format)
    }

    func testResavingAfterSwapFindsEachSide() throws {
        let reopened = try reopenedFiles()
        let (left, right) = try reopened.documents()
        let candidates = [reopened.left, reopened.right]
        // Swapped panes, both offered every old side.
        let swapped = SavedComparison(
            saved: date, options: DiffOptions(),
            left: try .init(document: right, fileData: nil, previous: candidates),
            right: try .init(document: left, fileData: nil, previous: candidates))
        let twice = try reopen(swapped)
        XCTAssertEqual(twice.left.bytes, reopened.right.bytes)
        XCTAssertEqual(twice.left.source, .file("/captures/post.txt"))
        XCTAssertEqual(twice.right.bytes, reopened.left.bytes)
        XCTAssertEqual(twice.right.source, .file("/captures/pre.txt"))
        // A document matching no candidate still needs its file.
        let other = try TextDocument(fileData: Data("other\n".utf8), name: "other.txt")
        XCTAssertThrowsError(try SavedComparison.Side(document: other, fileData: nil, previous: candidates)) {
            XCTAssertEqual($0.localizedDescription, "“other.txt” can’t be found where it was loaded from.")
        }
    }

    func testFileOpenedOverPastedTextIsReadAgain() throws {
        // The pane held pasted "a\n", then /x/real.txt with the same text was opened.
        let old = try pasted("a\n")
        let data = Data("a\n".utf8)
        let real = try TextDocument(fileData: data, name: "real.txt", url: URL(fileURLWithPath: "/x/real.txt"))
        let side = try SavedComparison.Side(document: real, fileData: data, previous: [old])
        XCTAssertEqual(side.source, .file("/x/real.txt"))
        XCTAssertEqual(try side.document().format, real.format)
        XCTAssertThrowsError(try SavedComparison.Side(document: real, fileData: nil, previous: [old]))
    }

    func testNewlyLoadedFileIgnoresMatchingSnapshot() throws {
        // An edited snapshot side whose bytes happen to equal a file loaded afterwards.
        let saved = try reopenedFiles()
        let edited = try SavedComparison(data: edited(saved) { $0.replacingOccurrences(of: "three", with: "THREE") })
        XCTAssertFalse(edited.right.matchesDigest)
        let data = edited.right.bytes
        let fresh = try TextDocument(fileData: data, name: "f.txt", url: URL(fileURLWithPath: "/new/f.txt"))
        let side = try SavedComparison.Side(document: fresh, fileData: data, previous: [edited.left, edited.right])
        XCTAssertEqual(side.source, .file("/new/f.txt"))
        XCTAssertTrue(side.matchesDigest)
        XCTAssertThrowsError(try SavedComparison.Side(document: fresh, fileData: nil, previous: [edited.right])) {
            XCTAssertEqual($0.localizedDescription, "“f.txt” can’t be found where it was loaded from.")
        }
    }

    func testResavingAnEditedSideKeepsItEdited() throws {
        let saved = try reopenedFiles()
        let edited = try SavedComparison(data: edited(saved) { $0.replacingOccurrences(of: "three", with: "THREE") })
        XCTAssertFalse(edited.right.matchesDigest)
        let (left, right) = try edited.documents()
        let again = SavedComparison(
            saved: date, options: DiffOptions(),
            left: try .init(document: left, fileData: nil, previous: [edited.left]),
            right: try .init(document: right, fileData: nil, previous: [edited.right]))
        let twice = try reopen(again)
        XCTAssertTrue(twice.left.matchesDigest)
        XCTAssertFalse(twice.right.matchesDigest)
        XCTAssertEqual(twice.right.sha256, saved.right.sha256)
        XCTAssertEqual(try twice.documents().right.lines, ["one", "THREE"])
    }

    func testResavingAnEditedPastedSideKeepsItEdited() throws {
        let saved = try sample(left: "a\nb\n", right: "a\nc\n")
        let edited = try SavedComparison(data: edited(saved) { $0.replacingOccurrences(of: "a\nc\n", with: "a\nC\n") })
        XCTAssertTrue(edited.left.matchesDigest)
        XCTAssertFalse(edited.right.matchesDigest)
        let (left, right) = try edited.documents()
        let again = SavedComparison(
            saved: date, options: DiffOptions(),
            left: try .init(document: left, fileData: nil, previous: [edited.left]),
            right: try .init(document: right, fileData: nil, previous: [edited.right]))
        let twice = try reopen(again)
        XCTAssertTrue(twice.left.matchesDigest)
        XCTAssertFalse(twice.right.matchesDigest)
        XCTAssertEqual(twice.right.sha256, saved.right.sha256)
        XCTAssertEqual(twice.right.source, .pasted)
        XCTAssertEqual(try twice.documents().right.lines, ["a", "C"])
    }

    func testPastedPreviousWithDifferentLinesIsIgnored() throws {
        let saved = try sample(left: "a\nb\n", right: "a\nc\n")
        let edited = try SavedComparison(data: edited(saved) { $0.replacingOccurrences(of: "a\nc\n", with: "a\nC\n") })
        let (left, _) = try edited.documents()
        // The left text offered the edited right side: a fresh, intact side for the left text.
        let side = try SavedComparison.Side(document: left, fileData: nil, previous: [edited.right])
        XCTAssertEqual(side.bytes, Data("a\nb\n".utf8))
        XCTAssertEqual(side.sha256, saved.left.sha256)
        XCTAssertTrue(side.matchesDigest)
        XCTAssertEqual(side.name, "pre")
    }

    // MARK: - Reading leniently

    func testUnknownOptionWordsAreIgnored() throws {
        let saved = try sample()
        let reopened = try SavedComparison(data: edited(saved) {
            $0.replacingOccurrences(of: "options:\n", with: "options: ignore-colour  ignore-case\n")
        })
        XCTAssertEqual(reopened.options, DiffOptions(ignoreCase: true))
    }

    func testKeysOutOfPlaceAreIgnored() throws {
        let saved = try sample()
        let reopened = try SavedComparison(data: edited(saved) {
            $0.replacingOccurrences(of: "\nright\n", with: "\nright\nnote: misplaced\noptions: ignore-case\n")
                .replacingOccurrences(of: "note: CHG0012345\n", with: "note: CHG0012345\nname: misplaced\n")
        })
        XCTAssertEqual(reopened.note, "CHG0012345")
        XCTAssertEqual(reopened.options, DiffOptions())
        XCTAssertEqual(reopened.left.name, "pre")
        XCTAssertEqual(reopened.right.name, "post")
    }

    func testReadsDatesInAnyOffset() throws {
        let saved = try sample()
        for written in ["2026-10-21T18:03:12Z", "2026-10-21T14:03:12-04:00", "2026-10-22T03:03:12+09:00"] {
            let data = edited(saved) {
                $0.replacingOccurrences(of: #"saved: [^\n]*"#, with: "saved: \(written)", options: .regularExpression)
            }
            XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\nsaved: \(written)\n"))
            let reopened = try SavedComparison(data: data)
            XCTAssertEqual(reopened.saved, date, written)
        }
    }

    // MARK: - Bad files

    private func assertRejects(_ data: Data, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try SavedComparison(data: data), file: file, line: line) { error in
            XCTAssertTrue(error.localizedDescription.contains(message), error.localizedDescription,
                          file: file, line: line)
        }
    }

    private func edited(_ saved: SavedComparison, _ change: (String) -> String) -> Data {
        Data(change(String(decoding: saved.encode(), as: UTF8.self)).utf8)
    }

    func testBadFilesThrow() throws {
        let saved = try sample(left: "left body\n", right: "right body\n")
        let data = saved.encode()
        assertRejects(data.prefix(data.count - 5), "right side’s 11 bytes run past the end")
        assertRejects(data.dropLast(), "right side isn’t followed by a newline")
        assertRejects(edited(saved) { $0.replacingOccurrences(of: "bytes: 10", with: "bytes: 9999") },
                      "left side’s 9999 bytes run past the end")
        assertRejects(edited(saved) { $0.replacingOccurrences(of: "bytes: 10", with: "bytes: 9") },
                      "left side isn’t followed by a “--- right” line")
        assertRejects(edited(saved) { $0.replacingOccurrences(of: "bytes: 11\n", with: "") },
                      "“bytes” line for the right side is missing")
        assertRejects(edited(saved) { $0.replacingOccurrences(of: "\nname: pre", with: "") },
                      "“name” line for the left side is missing")
        assertRejects(edited(saved) { $0.replacingOccurrences(of: "sha256: \(saved.left.sha256)\n", with: "") },
                      "“sha256” line for the left side is missing")
        assertRejects(edited(saved) {
            $0.replacingOccurrences(of: #"(\nright\nname: post\n)source: pasted\n"#, with: "$1",
                                    options: .regularExpression)
        }, "“source” line for the right side is missing")
        assertRejects(edited(saved) { $0.replacingOccurrences(of: "--- left\n", with: "") },
                      "no “--- left” line")
        assertRejects(edited(saved) { $0.replacingOccurrences(of: "juxta-comparison 1", with: "juxta-comparison 2") },
                      "newer version of Juxta (format 2)")
        assertRejects(edited(saved) { $0.replacingOccurrences(of: "juxta-comparison 1", with: "hello") },
                      "first line")
        assertRejects(Data(), "first line")
    }

    func testDigestMismatchOpensWithFlag() throws {
        let saved = try sample(left: "left body\n", right: "right body\n")
        let reopened = try SavedComparison(data: edited(saved) {
            $0.replacingOccurrences(of: "right body", with: "RIGHT body")
        })
        XCTAssertTrue(reopened.left.matchesDigest)
        XCTAssertFalse(reopened.right.matchesDigest)
        XCTAssertEqual(try reopened.documents().right.lines, ["RIGHT body"])
    }

    func testUnknownHeaderKeysAreIgnored() throws {
        let saved = try sample()
        let reopened = try SavedComparison(data: edited(saved) {
            $0.replacingOccurrences(of: "note: ", with: "colour: blue\nnote: ")
                .replacingOccurrences(of: "source: pasted\n", with: "source: pasted\nencoding-hint: utf-8\n")
        })
        XCTAssertEqual(reopened.note, "CHG0012345")
        XCTAssertEqual(reopened.left.bytes, saved.left.bytes)
        XCTAssertEqual(reopened.right.bytes, saved.right.bytes)
    }

    func testBinarySideThrowsFromDocuments() throws {
        let binary = Data([0x00, 0x01, 0x02, 0x03, 0x00, 0x00, 0x05])
        let side = SavedComparison.Side(name: "left.bin", source: .file("/tmp/left.bin"), bytes: binary)
        let reopened = try reopen(SavedComparison(saved: date, options: DiffOptions(), left: side, right: side))
        XCTAssertEqual(reopened.left.bytes, binary)
        XCTAssertThrowsError(try reopened.documents()) { error in
            XCTAssertEqual(error.localizedDescription, "“left.bin” appears to be a binary file.")
        }
    }

    func testGivenOptionsReplaceSavedOnes() throws {
        var saved = try sample()
        saved.options = DiffOptions(ignoreWhitespace: true, ignoreTimers: true)
        XCTAssertEqual(saved.options(given: DiffOptions()), saved.options)
        // Any option given replaces the saved set, not just the options named.
        XCTAssertEqual(saved.options(given: DiffOptions(ignoreCase: true)), DiffOptions(ignoreCase: true))
        XCTAssertEqual(saved.options(given: DiffOptions(ignoreWhitespace: true)), DiffOptions(ignoreWhitespace: true))
    }

    func testEditedNotice() throws {
        XCTAssertNil(try sample().editedNotice)
        let saved = try sample(left: "left body\n", right: "right body\n")
        let right = try SavedComparison(data: edited(saved) {
            $0.replacingOccurrences(of: "right body", with: "RIGHT body")
        })
        XCTAssertEqual(right.editedNotice, "The right side was edited after it was saved")
        let both = try SavedComparison(data: edited(saved) {
            $0.replacingOccurrences(of: "right body", with: "RIGHT body")
                .replacingOccurrences(of: "left body", with: "LEFT body")
        })
        XCTAssertEqual(both.editedNotice, "Both sides were edited after they were saved")
        XCTAssertEqual(SavedComparison.editedNotice(left: true, right: false),
                       "The left side was edited after it was saved")
    }

    func testSidePath() throws {
        XCTAssertNil(try pasted("a\n").path)
        let stdin = try SavedComparison.Side(document: TextDocument(fileData: Data("a\n".utf8), name: "-"),
                                              fileData: Data("a\n".utf8))
        // Standard input is recorded as "-", which isn't a path.
        XCTAssertEqual(stdin.source, .file("-"))
        XCTAssertNil(stdin.path)
        XCTAssertNil(SavedComparison.Side(name: "x", source: .file(""), bytes: Data()).path)
        XCTAssertEqual(SavedComparison.Side(name: "x", source: .file("/a/x"), bytes: Data()).path, "/a/x")
    }

    // MARK: Saving again

    /// A comparison of two files, as saved from disk.
    private func files(_ left: String, _ right: String) throws -> SavedComparison {
        func document(_ text: String, _ path: String) throws -> TextDocument {
            let url = URL(fileURLWithPath: path)
            return try TextDocument(fileData: Data(text.utf8), name: url.lastPathComponent, url: url)
        }
        return try SavedComparison(saving: document(left, "/l/pre.txt"), document(right, "/r/post.txt"),
                                   fileData: (Data(left.utf8), Data(right.utf8)), note: "n", saved: date,
                                   options: DiffOptions())
    }

    /// Reopens `data` and saves it again, as the app and `juxta-diff --save` do.
    private func resave(_ data: Data, swapped: Bool = false) throws -> SavedComparison {
        let reopened = try SavedComparison(data: data)
        let (left, right) = try reopened.documents()
        if swapped {
            return try SavedComparison(saving: right, left, previous: (reopened.right, reopened.left),
                                       options: reopened.options)
        }
        return try SavedComparison(saving: left, right, previous: (reopened.left, reopened.right),
                                   options: reopened.options)
    }

    func testSavingKeepsEachSidesOwnSourceWhenBytesMatch() throws {
        let saved = try files("same\n", "same\n")
        XCTAssertEqual(saved.left.source, .file("/l/pre.txt"))
        XCTAssertEqual(saved.right.source, .file("/r/post.txt"))
        let again = try resave(saved.encode())
        XCTAssertEqual(again.left.source, .file("/l/pre.txt"))
        XCTAssertEqual(again.right.source, .file("/r/post.txt"))
        XCTAssertEqual([again.left.name, again.right.name], ["pre.txt", "post.txt"])
        // Swapped panes pass their own sides first, so the sources swap with them.
        let swapped = try resave(saved.encode(), swapped: true)
        XCTAssertEqual(swapped.left.source, .file("/r/post.txt"))
        XCTAssertEqual(swapped.right.source, .file("/l/pre.txt"))
    }

    func testSavingKeepsEditedSideThatNowMatchesTheOther() throws {
        let saved = try files("aaa\n", "bbb\n")
        // The right side hand-edited to the left side's bytes.
        let data = edited(saved) { $0.replacingOccurrences(of: "--- right\nbbb\n", with: "--- right\naaa\n") }
        XCTAssertFalse(try SavedComparison(data: data).right.matchesDigest)
        let again = try resave(data)
        XCTAssertTrue(again.left.matchesDigest)
        XCTAssertFalse(again.right.matchesDigest)
        XCTAssertEqual(again.right.source, .file("/r/post.txt"))
        XCTAssertEqual(again.right.sha256, saved.right.sha256)
        XCTAssertEqual(again.right.bytes, Data("aaa\n".utf8))
        XCTAssertEqual(again.editedNotice, "The right side was edited after it was saved")
    }

    func testSavingPastedSidesAndNames() throws {
        let saved = try sample(left: "x\n", right: "x\n")
        let (left, right) = try saved.documents()
        let again = try SavedComparison(saving: left, right, previous: (saved.left, saved.right),
                                        names: ("", "renamed"), note: "new", options: DiffOptions())
        XCTAssertEqual([again.left.name, again.right.name], ["pre", "renamed"])
        XCTAssertEqual([again.left.source, again.right.source], [.pasted, .pasted])
        XCTAssertEqual(again.note, "new")
        XCTAssertEqual(again.left.bytes, saved.left.bytes)
    }

    func testSavingAFileNeedsItsBytes() throws {
        let document = try TextDocument(fileData: Data("a\n".utf8), name: "a.txt", url: URL(fileURLWithPath: "/a.txt"))
        XCTAssertThrowsError(try SavedComparison(saving: document, document, fileData: (nil, Data("a\n".utf8)),
                                                 options: DiffOptions()))
        XCTAssertThrowsError(try SavedComparison(saving: document, document, fileData: (Data("b\n".utf8), nil),
                                                 options: DiffOptions()))
    }
}
