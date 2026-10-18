import Foundation

/// Selected text in one pane, from an anchor (where the drag started) to a head (where
/// it is now). Positions are rows of the result and UTF-16 offsets in that row's line
/// on the pane's side, matching the inline-change ranges. A whole-row selection is
/// offset 0 of its first row to the end of its last row's line, so drawing and copying
/// have just one case, but it is marked `wholeRows` so that every row in it, empty or
/// not, draws as selected to the pane's edge.
///
/// As in a text view, the line break after a row is selected when the selection goes
/// on past that row, and copied as "\n". A selection that ends at offset 0 of a row
/// takes none of that row's line, but does take the break before it; one that ends on
/// a filler row takes no break after the last line, like whole rows, which copy without
/// a final newline.
public struct TextSelection: Equatable, Sendable {
    public struct Position: Comparable, Sendable {
        public var row: Int
        /// UTF-16 offset in the row's line; ignored on filler rows.
        public var offset: Int

        public init(row: Int, offset: Int) {
            self.row = row
            self.offset = offset
        }

        public static func < (a: Position, b: Position) -> Bool {
            (a.row, a.offset) < (b.row, b.offset)
        }
    }

    public var anchor: Position
    public var head: Position
    /// Selected by rows (in the gutter, or a whole change), not characters: every row
    /// from `start` to `end` is selected through its line end, even an empty one.
    public private(set) var wholeRows = false

    public init(anchor: Position, head: Position) {
        self.anchor = anchor
        self.head = head
    }

    /// Whole rows from `anchorRow` to `headRow`, either way round, as clicking and
    /// dragging in the line-number gutter selects them.
    public init(rows anchorRow: Int, to headRow: Int, in result: DiffResult,
                on side: KeyPath<DiffRow, Int32>, lines: [String]) {
        let length = { (row: Int) in Self.line(row, in: result, on: side, lines: lines)?.utf16.count ?? 0 }
        if headRow >= anchorRow {
            self.init(anchor: Position(row: anchorRow, offset: 0),
                      head: Position(row: headRow, offset: length(headRow)))
        } else {
            self.init(anchor: Position(row: anchorRow, offset: length(anchorRow)),
                      head: Position(row: headRow, offset: 0))
        }
        wholeRows = true
    }

    public var start: Position { min(anchor, head) }
    public var end: Position { max(anchor, head) }
    public var isEmpty: Bool { !wholeRows && anchor == head }

    /// The selected part of one row, for drawing.
    public struct Span: Equatable, Sendable {
        /// UTF-16 offsets in the row's line.
        public var offsets: Range<Int>
        /// The line break after the row is selected too, so the fill runs on to the
        /// pane's right edge and a block of rows reads as a block.
        public var throughLineEnd: Bool
    }

    /// The selected part of `row`, whose line is `lineLength` UTF-16 units long, or nil
    /// when none of it is selected. A row counts as selected (for accessibility) when
    /// this isn't nil.
    public func span(inRow row: Int, lineLength: Int) -> Span? {
        let start = self.start, end = self.end
        guard start.row <= row, row <= end.row else { return nil }
        if wholeRows { return Span(offsets: 0..<lineLength, throughLineEnd: true) }
        let lower = row == start.row ? min(start.offset, lineLength) : 0
        if row < end.row { return Span(offsets: lower..<max(lower, lineLength), throughLineEnd: true) }
        let upper = min(end.offset, lineLength)
        guard lower < upper else { return nil }
        return Span(offsets: lower..<upper, throughLineEnd: false)
    }

    /// The selected text of the file on `side` (`lines` are its document's lines):
    /// filler rows are skipped and lines are joined with "\n". Taken from the lines,
    /// not the display string, so tabs and invisible characters copy as themselves.
    public func text(in result: DiffResult, on side: KeyPath<DiffRow, Int32>, lines: [String]) -> String {
        let start = self.start, end = self.end
        let rows = (start.row..<end.row + 1).clamped(to: result.rows.indices)
        return rows.compactMap { row -> Substring? in
            guard let line = Self.line(row, in: result, on: side, lines: lines) else { return nil }
            let utf16 = line.utf16
            let lower = row == start.row && !wholeRows ? min(start.offset, utf16.count) : 0
            let upper = row == end.row && !wholeRows ? min(end.offset, utf16.count) : utf16.count
            guard lower < upper else { return "" }
            return line[utf16.index(utf16.startIndex, offsetBy: lower)..<utf16.index(utf16.startIndex, offsetBy: upper)]
        }.joined(separator: "\n")
    }

    /// The line shown on `side` in `row`, or nil on a filler row.
    static func line(_ row: Int, in result: DiffResult, on side: KeyPath<DiffRow, Int32>,
                     lines: [String]) -> String? {
        guard result.rows.indices.contains(row) else { return nil }
        let index = Int(result.rows[row][keyPath: side])
        return index >= 0 ? lines[index] : nil
    }

    // MARK: Recompute

    /// A position as one side's line and an offset in it.
    public struct LinePosition: Equatable, Sendable {
        public var line: Int
        public var offset: Int

        public init(line: Int, offset: Int) {
            self.line = line
            self.offset = offset
        }
    }

    /// The selection in terms of one side's lines, to keep it across a recompute:
    /// rows change with the result, lines don't.
    public struct Saved: Equatable, Sendable {
        public var anchor: LinePosition
        public var head: LinePosition
        public var wholeRows = false
    }

    /// The selection as `side`'s lines, or nil when it selects nothing there. An end on
    /// a filler row moves to the nearest edge of the lines it selects (the start of the
    /// next line, or the end of the previous one), which copies the same text.
    public func saved(in result: DiffResult, on side: KeyPath<DiffRow, Int32>, lines: [String]) -> Saved? {
        let start = self.start, end = self.end
        guard let shown = result.lines(in: start.row..<end.row + 1, on: side) else { return nil }
        // On a line, `line` is the line it is on; on a filler row, the line next to it.
        func position(_ position: Position, line: Int, fillerOffset: Int) -> LinePosition {
            let onLine = Self.line(position.row, in: result, on: side, lines: lines) != nil
            return LinePosition(line: line, offset: onLine ? min(position.offset, lines[line].utf16.count) : fillerOffset)
        }
        let first = position(start, line: shown.lowerBound, fillerOffset: 0)
        let last = position(end, line: shown.upperBound, fillerOffset: lines[shown.upperBound].utf16.count)
        guard wholeRows || (first.line, first.offset) < (last.line, last.offset) else { return nil }
        return anchor <= head ? Saved(anchor: first, head: last, wholeRows: wholeRows)
                              : Saved(anchor: last, head: first, wholeRows: wholeRows)
    }

    /// The same lines and offsets in a new result for the same documents, or nil when
    /// the result doesn't show them.
    public init?(_ saved: Saved, in result: DiffResult, on side: KeyPath<DiffRow, Int32>) {
        let forward = saved.anchor.line <= saved.head.line
        let (first, last) = forward ? (saved.anchor, saved.head) : (saved.head, saved.anchor)
        // A side's lines appear in order, so the first row shows `first` and the last `last`.
        guard let rows = result.rows(showing: first.line...last.line, on: side) else { return nil }
        let start = Position(row: rows.lowerBound, offset: first.offset)
        let end = Position(row: rows.upperBound - 1, offset: last.offset)
        self.init(anchor: forward ? start : end, head: forward ? end : start)
        wholeRows = saved.wholeRows
    }
}
