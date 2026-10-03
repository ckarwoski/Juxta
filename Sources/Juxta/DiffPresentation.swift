import AppKit
import JuxtaCore

enum Side {
    case left, right
}

/// State shared by every view in one comparison window: the two documents, the diff
/// result, and font metrics.
final class DiffPresentation {
    struct Segment {
        let rows: Range<Int>
        let kind: RowKind
    }

    private(set) var left: TextDocument?
    private(set) var right: TextDocument?
    private(set) var result = DiffResult.empty
    /// Runs of identical non-`same` row kinds, for the change map.
    private(set) var segments: [Segment] = []
    /// Highlights depend on the options too, not just the result, so changing them
    /// drops the cache right away instead of waiting for the new comparison.
    var options: DiffOptions {
        didSet { if options != oldValue { resetInlineChanges() } }
    }
    var currentHunk: Int?

    private(set) var textStyle = TextStyle()
    private(set) var font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    /// Labels the badges drawn for invisible characters; a label must fit in as many columns as it has characters.
    private(set) var badgeFont = NSFont.monospacedSystemFont(ofSize: 8, weight: .medium)
    private(set) var gutterFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    private(set) var lineHeight: CGFloat = 16
    /// Distance from the top of a row to the text baseline.
    private(set) var baseline: CGFloat = 12
    private(set) var charWidth: CGFloat = 7
    private(set) var textAttributes: [NSAttributedString.Key: Any] = [:]
    let textInset: CGFloat = 8

    private var inlineCache: [Int: InlineChanges] = [:]
    private var inlineMisses: Set<Int> = []

    /// Long line pairs can take up to the diff's time limit each, so they are
    /// diffed one at a time on `inlineQueue`. `inlineGeneration` changes whenever
    /// the documents or result do, so late answers for stale rows are dropped.
    private static let inlineQueue = DispatchQueue(label: "Juxta.inlineChanges", qos: .userInitiated)
    private static let asyncInlineLength = 1_500
    private var inlineGeneration = 0
    private var inlinePending: Set<Int> = []
    private var inlineRunning = false
    /// Called with a row whose inline changes arrived in the background.
    var onInlineChanges: ((Int) -> Void)?
    /// The rows on screen, which are diffed first.
    var visibleRows: (() -> Range<Int>)?

    init(options: DiffOptions, textStyle: TextStyle) {
        self.options = options
        setTextStyle(textStyle)
    }

    func document(_ side: Side) -> TextDocument? {
        side == .left ? left : right
    }

    /// The result must never refer to lines a document lacks, so until the documents
    /// are compared again they are shown unaligned.
    func setDocument(_ document: TextDocument?, for side: Side) {
        if side == .left { left = document } else { right = document }
        setResult(Comparator.passthrough(leftCount: left?.lines.count, rightCount: right?.lines.count))
    }

    /// Swapping mirrors the result, which stays valid for the swapped documents.
    func swapDocuments() {
        swap(&left, &right)
        var mirrored = result
        mirrored.rows = result.rows.map { row in
            let kind: RowKind = row.kind == .inserted ? .deleted : row.kind == .deleted ? .inserted : row.kind
            return DiffRow(left: row.right, right: row.left, kind: kind)
        }
        swap(&mirrored.insertedLines, &mirrored.deletedLines)
        setResult(mirrored)
    }

    func lineIndex(row: Int, side: Side) -> Int {
        let r = result.rows[row]
        return Int(side == .left ? r.left : r.right)
    }

    func setResult(_ newResult: DiffResult) {
        result = newResult
        currentHunk = nil
        resetInlineChanges()
        var runs: [Segment] = []
        for hunk in newResult.hunks {
            var start = hunk.rows.lowerBound
            for row in hunk.rows.dropFirst() where newResult.rows[row].kind != newResult.rows[start].kind {
                runs.append(Segment(rows: start..<row, kind: newResult.rows[start].kind))
                start = row
            }
            runs.append(Segment(rows: start..<hunk.rows.upperBound, kind: newResult.rows[start].kind))
        }
        segments = runs
    }

    /// Token-level changes for a `.changed` row. Short pairs are diffed right
    /// away; long ones return nil until a background diff finishes and
    /// `onInlineChanges` asks for the row to be redrawn.
    func inlineChanges(row: Int) -> InlineChanges? {
        if let cached = inlineCache[row] { return cached }
        if inlineMisses.contains(row) { return nil }
        guard let (a, b) = linePair(row: row) else { return nil }
        if a.utf16.count + b.utf16.count >= Self.asyncInlineLength {
            if inlinePending.insert(row).inserted { startInlineRequest() }
            return nil
        }
        store(Comparator.inlineChanges(a, b, options: options), row: row)
        return inlineCache[row]
    }

    /// Whether a row's inline changes are still being diffed in the background.
    func isInlinePending(row: Int) -> Bool { inlinePending.contains(row) }

    private func linePair(row: Int) -> (String, String)? {
        let r = result.rows[row]
        guard r.kind == .changed, let left, let right, r.left >= 0, r.right >= 0 else { return nil }
        return (left.lines[Int(r.left)], right.lines[Int(r.right)])
    }

    private func store(_ changes: InlineChanges?, row: Int) {
        if let changes { inlineCache[row] = changes } else { inlineMisses.insert(row) }
    }

    private func resetInlineChanges() {
        inlineGeneration += 1
        inlineCache = [:]
        inlineMisses = []
        inlinePending = []
    }

    /// Starts diffing the pending row nearest the screen, unless a diff is running.
    /// Rows more than a screen away wait, so this is called again on scrolling:
    /// AppKit may show such rows from its cache without drawing them again.
    func startInlineRequest() {
        guard !inlineRunning, let row = nextInlineRow(), let (a, b) = linePair(row: row) else { return }
        let generation = inlineGeneration, options = options
        inlineRunning = true
        Self.inlineQueue.async { [weak self] in
            let changes = Comparator.inlineChanges(a, b, options: options)
            DispatchQueue.main.async {
                guard let self else { return }
                self.inlineRunning = false
                if generation == self.inlineGeneration {
                    self.inlinePending.remove(row)
                    self.store(changes, row: row)
                    if changes != nil { self.onInlineChanges?(row) }
                }
                self.startInlineRequest()
            }
        }
    }

    /// Visible rows top down, then outward up to a screen either side.
    private func nextInlineRow() -> Int? {
        guard !inlinePending.isEmpty else { return nil }
        let visible = visibleRows?() ?? 0..<0
        if let row = visible.first(where: inlinePending.contains) { return row }
        for distance in 1...(visible.count + 1) {
            for row in [visible.upperBound - 1 + distance, visible.lowerBound - distance]
            where inlinePending.contains(row) {
                return row
            }
        }
        return nil
    }

    func setTextStyle(_ style: TextStyle) {
        textStyle = style
        let fontSize = style.effectiveSize
        font = style.font(ofSize: fontSize)
        gutterFont = NSFont.monospacedDigitSystemFont(ofSize: fontSize - 1, weight: .regular)
        badgeFont = NSFont.monospacedSystemFont(ofSize: round(fontSize * 0.65), weight: .medium)
        let ascent = font.ascender
        let descent = -font.descender
        lineHeight = ceil(ascent + descent + font.leading) + round(fontSize * style.lineSpacing.extra)
        baseline = round((lineHeight - (ascent + descent)) / 2 + ascent)
        charWidth = font.advancement(forGlyph: font.glyph(withName: "zero")).width
        if charWidth <= 0 { charWidth = fontSize * 0.6 }

        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = []
        paragraph.defaultTabInterval = charWidth * 4
        textAttributes = [
            .font: font,
            .paragraphStyle: paragraph,
            .ligature: style.ligatures ? 1 : 0,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]
    }
}
