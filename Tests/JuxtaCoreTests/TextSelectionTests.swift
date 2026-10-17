import XCTest
@testable import JuxtaCore

final class TextSelectionTests: XCTestCase {
    private let left = ["interface Gi0/1", " ip address 10.1.1.1/24", "", " shutdown", "!"]
    private let right = ["interface Gi0/1", " ip address 10.1.1.2/24", " description core", "", "!"]
    /// Row 2 is a filler on the left, row 4 on the right.
    private let result = DiffResult(rows: [
        DiffRow(left: 0, right: 0, kind: .same),
        DiffRow(left: 1, right: 1, kind: .changed),
        DiffRow(left: -1, right: 2, kind: .inserted),
        DiffRow(left: 2, right: 3, kind: .same),
        DiffRow(left: 3, right: -1, kind: .deleted),
        DiffRow(left: 4, right: 4, kind: .same),
    ], hunks: [Hunk(rows: 1..<3), Hunk(rows: 4..<5)])

    private func selection(_ anchor: (Int, Int), _ head: (Int, Int)) -> TextSelection {
        TextSelection(anchor: .init(row: anchor.0, offset: anchor.1), head: .init(row: head.0, offset: head.1))
    }

    private func leftText(_ selection: TextSelection) -> String {
        selection.text(in: result, on: \.left, lines: left)
    }

    func testStartAndEndAreOrdered() {
        let backward = selection((3, 2), (1, 5))
        XCTAssertEqual(backward.start, .init(row: 1, offset: 5))
        XCTAssertEqual(backward.end, .init(row: 3, offset: 2))
        XCTAssertEqual(selection((1, 9), (1, 4)).start.offset, 4)
        XCTAssertTrue(selection((1, 4), (1, 4)).isEmpty)
        XCTAssertFalse(backward.isEmpty)
    }

    func testCopiesPartOfOneLine() {
        XCTAssertEqual(leftText(selection((1, 4), (1, 11))), "address")
        XCTAssertEqual(leftText(selection((1, 23), (1, 12))), "10.1.1.1/24")
        XCTAssertEqual(leftText(selection((1, 4), (1, 4))), "")
    }

    func testCopiesPartialFirstAndLastLinesSkippingFillersAndKeepingEmptyLines() {
        // Row 2 is a filler on the left; row 3 is an empty line.
        let across = selection((1, 12), (5, 1))
        XCTAssertEqual(leftText(across), "10.1.1.1/24\n\n shutdown\n!")
        XCTAssertEqual(leftText(selection((5, 1), (1, 12))), "10.1.1.1/24\n\n shutdown\n!")
        // The same rows on the right skip row 4 instead.
        XCTAssertEqual(across.text(in: result, on: \.right, lines: right),
                       "10.1.1.2/24\n description core\n\n!")
    }

    func testEndAtColumnZeroTakesTheBreakButNotTheLine() {
        XCTAssertEqual(leftText(selection((0, 0), (1, 0))), "interface Gi0/1\n")
        XCTAssertEqual(leftText(selection((0, 0), (4, 0))), "interface Gi0/1\n ip address 10.1.1.1/24\n\n")
        // From the end of a line, just the break.
        XCTAssertEqual(leftText(selection((0, 15), (1, 0))), "\n")
        // Ending on a filler row takes no break after the last line.
        XCTAssertEqual(leftText(selection((1, 0), (2, 0))), " ip address 10.1.1.1/24")
    }

    func testCopiesTheFileTextNotTheDisplay() {
        let lines = ["a\tb", "65001:\u{200B}100"]
        let rows = DiffResult(rows: [DiffRow(left: 0, right: 0, kind: .changed),
                                     DiffRow(left: 1, right: 1, kind: .changed)], hunks: [])
        XCTAssertEqual(selection((0, 1), (1, 7)).text(in: rows, on: \.left, lines: lines), "\tb\n65001:\u{200B}")
    }

    func testWholeRowsMatchTheLinesTheyShow() {
        let all = TextSelection(rows: 0, to: 5, in: result, on: \.left, lines: left)
        XCTAssertEqual(all.anchor, .init(row: 0, offset: 0))
        XCTAssertEqual(all.head, .init(row: 5, offset: 1))
        XCTAssertEqual(leftText(all), left.joined(separator: "\n"))
        // Dragging up anchors at the end of the first row clicked.
        let up = TextSelection(rows: 3, to: 1, in: result, on: \.right, lines: right)
        XCTAssertEqual(up.anchor, .init(row: 3, offset: 0))
        XCTAssertEqual(up.head, .init(row: 1, offset: 0))
        let down = TextSelection(rows: 1, to: 4, in: result, on: \.right, lines: right)
        XCTAssertEqual(down.head, .init(row: 4, offset: 0)) // a filler row
        XCTAssertEqual(down.text(in: result, on: \.right, lines: right),
                       " ip address 10.1.1.2/24\n description core\n")
        let line = TextSelection(rows: 1, to: 1, in: result, on: \.left, lines: left)
        XCTAssertEqual(leftText(line), left[1])
        XCTAssertEqual(leftText(TextSelection(rows: 4, to: 1, in: result, on: \.left, lines: left)),
                       " ip address 10.1.1.1/24\n\n shutdown")
    }

    func testSpans() {
        let across = selection((3, 0), (1, 12))
        XCTAssertNil(across.span(inRow: 0, lineLength: 15))
        XCTAssertEqual(across.span(inRow: 1, lineLength: 23), .init(offsets: 12..<23, throughLineEnd: true))
        XCTAssertEqual(across.span(inRow: 2, lineLength: 0), .init(offsets: 0..<0, throughLineEnd: true))
        // Ending at offset 0 selects nothing in the last row.
        XCTAssertNil(across.span(inRow: 3, lineLength: 0))
        XCTAssertNil(across.span(inRow: 4, lineLength: 9))

        let partial = selection((1, 4), (4, 3))
        XCTAssertEqual(partial.span(inRow: 3, lineLength: 0), .init(offsets: 0..<0, throughLineEnd: true))
        XCTAssertEqual(partial.span(inRow: 4, lineLength: 9), .init(offsets: 0..<3, throughLineEnd: false))
        XCTAssertEqual(selection((1, 4), (1, 11)).span(inRow: 1, lineLength: 23),
                       .init(offsets: 4..<11, throughLineEnd: false))
        XCTAssertNil(selection((1, 4), (1, 4)).span(inRow: 1, lineLength: 23))
        // From the end of a line, only its break.
        XCTAssertEqual(selection((0, 15), (1, 2)).span(inRow: 0, lineLength: 15),
                       .init(offsets: 15..<15, throughLineEnd: true))
        // Offsets past the end of the line are clamped.
        XCTAssertEqual(selection((1, 30), (2, 0)).span(inRow: 1, lineLength: 23),
                       .init(offsets: 23..<23, throughLineEnd: true))
    }

    func testSavedSelectionRestoresTheSameLinesInANewResult() throws {
        // The same documents unaligned: line n of each side is in row n.
        let unaligned = Comparator.passthrough(leftCount: left.count, rightCount: right.count)
        let backward = selection((4, 3), (1, 12))
        let saved = try XCTUnwrap(backward.saved(in: result, on: \.left, lines: left))
        XCTAssertEqual(saved.anchor, .init(line: 3, offset: 3))
        XCTAssertEqual(saved.head, .init(line: 1, offset: 12))
        let restored = try XCTUnwrap(TextSelection(saved, in: unaligned, on: \.left))
        XCTAssertEqual(restored, selection((3, 3), (1, 12)))
        XCTAssertEqual(restored.text(in: unaligned, on: \.left, lines: left), leftText(backward))
        // And back again.
        XCTAssertEqual(TextSelection(saved, in: result, on: \.left), backward)

        let oneLine = try XCTUnwrap(selection((1, 4), (1, 11)).saved(in: result, on: \.right, lines: right))
        XCTAssertEqual(TextSelection(oneLine, in: unaligned, on: \.right), selection((1, 4), (1, 11)))
    }

    func testSavedEndsOnFillerRowsMoveToTheLinesTheySelect() throws {
        let unaligned = Comparator.passthrough(leftCount: left.count, rightCount: right.count)
        // Rows 2 to 4 of the left are a filler, line 2 and line 3: a start on the filler
        // moves to the start of line 2.
        let fromFiller = selection((2, 0), (4, 3))
        let saved = try XCTUnwrap(fromFiller.saved(in: result, on: \.left, lines: left))
        XCTAssertEqual(saved.anchor, .init(line: 2, offset: 0))
        XCTAssertEqual(leftText(fromFiller), "\n sh")
        XCTAssertEqual(TextSelection(saved, in: unaligned, on: \.left)?.text(in: unaligned, on: \.left, lines: left),
                       "\n sh")
        // An end on the filler moves to the end of line 1, so no break is added.
        let toFiller = selection((1, 12), (2, 0))
        let savedTo = try XCTUnwrap(toFiller.saved(in: result, on: \.left, lines: left))
        XCTAssertEqual(savedTo.head, .init(line: 1, offset: 23))
        XCTAssertEqual(TextSelection(savedTo, in: unaligned, on: \.left)?.text(in: unaligned, on: \.left, lines: left),
                       "10.1.1.1/24")
    }

    func testNothingToSaveWithoutSelectedText() {
        XCTAssertNil(selection((2, 0), (2, 0)).saved(in: result, on: \.left, lines: left))
        XCTAssertNil(selection((1, 5), (1, 5)).saved(in: result, on: \.left, lines: left))
        // Only a filler row on this side.
        XCTAssertNil(selection((4, 0), (4, 3)).saved(in: result, on: \.right, lines: right))
        // From the end of line 1 to the filler after it: no text.
        XCTAssertNil(selection((1, 23), (2, 0)).saved(in: result, on: \.left, lines: left))
        // Lines the new result doesn't show.
        let saved = TextSelection.Saved(anchor: .init(line: 7, offset: 0), head: .init(line: 9, offset: 1))
        XCTAssertNil(TextSelection(saved, in: result, on: \.left))
    }
}
