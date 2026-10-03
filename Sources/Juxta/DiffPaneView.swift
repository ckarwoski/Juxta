import AppKit
import JuxtaCore

/// Draws one side of the comparison. Only the rows intersecting the dirty rect are
/// rendered, so drawing cost is independent of file size.
final class DiffPaneView: NSView, NSMenuItemValidation {
    let side: Side
    private let presentation: DiffPresentation
    weak var controller: CompareWindowController?
    /// Called when selection changes so the line-number gutter can repaint.
    var onSelectionChange: (() -> Void)?

    private var selectionAnchor: Int?
    private(set) var selection: Range<Int>? {
        didSet {
            needsDisplay = true
            onSelectionChange?()
        }
    }

    /// Accessibility elements for rows VoiceOver has asked about, kept so an element
    /// stays the same object while it has focus; dropped when the rows change.
    private var rowElements: [Int: RowElement] = [:]

    init(side: Side, presentation: DiffPresentation) {
        self.side = side
        self.presentation = presentation
        super.init(frame: .zero)
        // Since macOS 14, dirtyRect can extend past bounds; clip so fills stay inside.
        clipsToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        onSelectionChange?()
        return true
    }

    override func resignFirstResponder() -> Bool {
        needsDisplay = true
        onSelectionChange?()
        return true
    }

    var hasFocus: Bool {
        window?.isKeyWindow == true && window?.firstResponder === self
    }

    func clearSelection() {
        selectionAnchor = nil
        selection = nil
    }

    /// The selection as this side's lines, and whether the anchor is at its end: rows
    /// change with the result, lines don't.
    struct LineSelection {
        var lines: ClosedRange<Int>
        var anchorAtEnd: Bool
    }

    func lineSelection() -> LineSelection? {
        guard let selection,
              let lines = presentation.result.lines(in: selection, on: side == .left ? \.left : \.right)
        else { return nil }
        return LineSelection(lines: lines, anchorAtEnd: selection.count > 1 && selectionAnchor == selection.upperBound - 1)
    }

    /// Selects the same lines in a new result for the same documents.
    func restore(_ saved: LineSelection?) {
        guard let saved,
              let rows = presentation.result.rows(showing: saved.lines, on: side == .left ? \.left : \.right)
        else { return clearSelection() }
        selectionAnchor = saved.anchorAtEnd ? rows.upperBound - 1 : rows.lowerBound
        selection = rows
    }

    /// Resizes to fit the content, but never smaller than the visible area.
    func updateSize() {
        guard let clip = enclosingScrollView?.contentView else { return }
        let p = presentation
        var size = clip.bounds.size
        if let document = p.document(side) {
            size.height = max(size.height, CGFloat(p.result.rows.count + 1) * p.lineHeight)
            size.width = max(size.width, p.textInset * 2 + CGFloat(document.maxColumns) * p.charWidth)
        }
        size = NSSize(width: ceil(size.width), height: ceil(size.height))
        if frame.size != size { setFrameSize(size) }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()
        let p = presentation
        guard let document = p.document(side) else {
            drawPlaceholder("Drop a file here\nor paste text with ⌘V", symbol: "doc.text", in: visibleRect)
            return
        }
        // Otherwise an empty file is a blank (or all-hatched) pane. Placed in the first
        // screen of the document, not the visible rect, so scrolling moves it with the
        // rows instead of smearing it.
        let firstScreen = document.lines.isEmpty ? enclosingScrollView.map { NSRect(origin: .zero, size: $0.contentView.bounds.size) } : nil
        defer {
            if let firstScreen { drawPlaceholder("Empty file", symbol: "doc", in: firstScreen, backed: true) }
        }
        let rows = p.result.rows
        let lh = p.lineHeight
        let first = max(0, Int(floor(dirtyRect.minY / lh)))
        let last = min(rows.count, Int(ceil(dirtyRect.maxY / lh)))
        guard first < last, let ctx = NSGraphicsContext.current?.cgContext else { return }

        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        let textColor = NSColor.textColor.cgColor
        let selectionColor = hasFocus
            ? NSColor.selectedTextBackgroundColor : NSColor.unemphasizedSelectedTextBackgroundColor

        for r in first..<last {
            let row = rows[r]
            let y = CGFloat(r) * lh
            let rowRect = NSRect(x: dirtyRect.minX, y: y, width: dirtyRect.width, height: lh)
            let index = Int(side == .left ? row.left : row.right)
            if index < 0 {
                Theme.drawFiller(in: rowRect)
                continue
            }
            let selected = selection?.contains(r) == true
            if selected {
                selectionColor.setFill()
                rowRect.fill()
            } else if let background = Theme.background(for: row.kind) {
                background.setFill()
                rowRect.fill()
            }

            let text = document.lines[index]
            if text.isEmpty { continue }
            // Laying out and drawing a huge line is slow even when clipped, so for long
            // lines only the columns inside dirtyRect are shaped, placed at their column.
            var shaped = text
            var columns: Range<Int>?
            if let visible = visibleColumns(of: text, in: dirtyRect) {
                let utf8 = text.utf8
                shaped = String(text[utf8.index(utf8.startIndex, offsetBy: visible.lowerBound)
                                     ..< utf8.index(utf8.startIndex, offsetBy: visible.upperBound)])
                columns = visible
            }
            let start = columns?.lowerBound ?? 0
            let originX = p.textInset + CGFloat(start) * p.charWidth
            // Invisibles are marked only on rows that differ: there they can explain the
            // difference, elsewhere they would be clutter.
            let atLineEnd = columns.map { $0.upperBound == text.utf8.count } ?? true
            let invisibles = row.kind == .same ? nil : Invisibles.layout(shaped[...], atLineEnd: atLineEnd)
            let display = invisibles?.display ?? shaped
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: display, attributes: p.textAttributes))
            // CTLineGetOffsetForStringIndex analyzes the line's grapheme clusters, which was
            // most of the time spent drawing a screen of changed rows. In printable ASCII
            // every character is one column of the monospaced font, so offsets are exact
            // (checked against CoreText for every printable pair at 8–36 pt). This relies on
            // DiffPresentation's font having no kerning or ligatures, like visibleColumns.
            let isPlainASCII = display.utf8.allSatisfy { $0 >= 0x20 && $0 < 0x7F }
            func offset(_ index: Int) -> CGFloat {
                isPlainASCII ? CGFloat(index) * p.charWidth : CTLineGetOffsetForStringIndex(line, index, nil)
            }

            // Under the inline highlights: on changed rows those already mark trailing
            // whitespace that changed, while this marks it on inserted and deleted rows.
            if let invisibles, let trailing = invisibles.trailingStart, !selected {
                Theme.trailingWhitespace.setFill()
                let x0 = offset(trailing)
                let x1 = offset(invisibles.display.utf16.count)
                NSRect(x: originX + x0, y: y + 1, width: x1 - x0, height: lh - 2).fill()
            }
            if row.kind == .changed, !selected, let inline = p.inlineChanges(row: r) {
                for range in side == .left ? inline.left : inline.right {
                    var lower = range.location, upper = range.location + range.length
                    if let columns {
                        // Clip to the slice; skip highlights that lie wholly outside it.
                        if range.length > 0
                            ? upper <= columns.lowerBound || lower >= columns.upperBound
                            : lower < columns.lowerBound || lower > columns.upperBound { continue }
                        lower = max(lower, columns.lowerBound) - start
                        upper = min(upper, columns.upperBound) - start
                    }
                    if let invisibles {
                        lower = invisibles.displayOffset(lower)
                        upper = invisibles.displayOffset(upper)
                    }
                    let x0 = offset(lower)
                    let x1 = offset(upper)
                    Theme.drawChangedHighlight(in: NSRect(x: originX + x0, y: y + 1,
                                                          width: max(x1 - x0, 2), height: lh - 2))
                }
            }
            ctx.setFillColor(textColor)
            ctx.textPosition = CGPoint(x: originX, y: y + p.baseline)
            CTLineDraw(line, ctx)
            if let invisibles { drawInvisibles(invisibles, offset: offset, originX: originX, y: y, in: ctx) }
        }

        // Outline the hunk most recently navigated to.
        if let current = p.currentHunk, current < p.result.hunks.count {
            let hunkRows = p.result.hunks[current].rows
            NSColor.controlAccentColor.setFill()
            for edge in [CGFloat(hunkRows.lowerBound) * lh, CGFloat(hunkRows.upperBound) * lh - 1.5] {
                NSRect(x: dirtyRect.minX, y: edge, width: dirtyRect.width, height: 1.5).fill()
            }
        }
    }

    /// Draws faint marks for whitespace and badges for characters that draw nothing.
    /// Badges cover the spaces `Invisibles` put in their place in the display string.
    private func drawInvisibles(_ invisibles: Invisibles.Layout, offset: (Int) -> CGFloat, originX: CGFloat,
                                y: CGFloat, in ctx: CGContext) {
        let p = presentation
        let midY = y + p.baseline - p.font.xHeight / 2
        let ink = Theme.invisible.cgColor
        ctx.saveGState()
        ctx.setStrokeColor(ink)
        ctx.setFillColor(ink)
        ctx.setLineWidth(1)
        ctx.setLineCap(.round)
        for marker in invisibles.markers {
            let x0 = originX + offset(marker.range.lowerBound)
            let x1 = originX + offset(marker.range.upperBound)
            let midX = (x0 + x1) / 2
            switch marker.kind {
            case .tab:
                // An arrow spanning the tab, with its head at the tab stop.
                let head = min(3, (x1 - x0) / 3)
                let left = x0 + 2, right = max(x1 - 2, left + head)
                ctx.move(to: CGPoint(x: left, y: midY))
                ctx.addLine(to: CGPoint(x: right, y: midY))
                ctx.move(to: CGPoint(x: right - head, y: midY - head))
                ctx.addLine(to: CGPoint(x: right, y: midY))
                ctx.addLine(to: CGPoint(x: right - head, y: midY + head))
                ctx.strokePath()
            case .space:
                ctx.fillEllipse(in: CGRect(x: midX - 1.25, y: midY - 1.25, width: 2.5, height: 2.5))
            case .unusualSpace:
                // A ring where a space would be, so it can't pass for a plain space.
                ctx.strokeEllipse(in: CGRect(x: midX - 2, y: midY - 2, width: 4, height: 4))
            case .badge(let label):
                drawBadge(label, in: CGRect(x: x0 + 1, y: y + 2, width: x1 - x0 - 2, height: p.lineHeight - 4),
                          ctx: ctx)
            }
        }
        ctx.restoreGState()
    }

    private func drawBadge(_ label: String, in rect: CGRect, ctx: CGContext) {
        let p = presentation
        let path = CGPath(roundedRect: rect, cornerWidth: 3, cornerHeight: 3, transform: nil)
        ctx.addPath(path)
        ctx.setFillColor(Theme.badgeFill.cgColor)
        ctx.fillPath()
        ctx.addPath(path)
        ctx.setStrokeColor(Theme.invisible.cgColor)
        ctx.setLineWidth(0.5)
        ctx.strokePath()
        let text = CTLineCreateWithAttributedString(NSAttributedString(string: label, attributes: [
            .font: p.badgeFont,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]))
        let width = CTLineGetTypographicBounds(text, nil, nil, nil)
        // Text color: secondary label was under 4.5:1 on the badge fill at 8 pt.
        ctx.setFillColor(NSColor.textColor.cgColor)
        ctx.textPosition = CGPoint(x: rect.midX - width / 2,
                                   y: rect.midY + p.badgeFont.capHeight / 2)
        CTLineDraw(text, ctx)
    }

    /// The columns of a long line worth laying out for `rect`, or nil to draw it whole.
    /// Only printable ASCII qualifies: there each UTF-16 unit is exactly one column,
    /// whereas tabs, wide characters and combining marks break that correspondence.
    private func visibleColumns(of text: String, in rect: NSRect) -> Range<Int>? {
        let count = text.utf8.count
        guard count > 1_000 else { return nil }
        var text = text
        guard text.withUTF8({ $0.allSatisfy { $0 >= 0x20 && $0 < 0x7F } }) else { return nil }
        let p = presentation
        let margin = 4
        let lower = Int(floor((rect.minX - p.textInset) / p.charWidth)) - margin
        let upper = Int(ceil((rect.maxX - p.textInset) / p.charWidth)) + margin
        let clampedLower = min(max(lower, 0), count)
        return clampedLower..<min(max(upper, clampedLower), count)
    }

    /// A centered symbol and message in `visible`; `backed` puts a plate behind them
    /// so they read over hatched rows.
    private func drawPlaceholder(_ message: String, symbol name: String, in visible: NSRect, backed: Bool = false) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineSpacing = 3
        let attributed = NSAttributedString(string: message, attributes: [
            .font: NSFont.systemFont(ofSize: 14),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ])
        let textSize = attributed.boundingRect(
            with: NSSize(width: visible.width - 40, height: 200), options: [.usesLineFragmentOrigin]
        ).size
        var top = visible.midY - textSize.height / 2
        let config = NSImage.SymbolConfiguration(pointSize: 44, weight: .light)
            .applying(.init(paletteColors: [.tertiaryLabelColor]))
        let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        if backed {
            let iconHeight = (symbol?.size.height ?? 0) + 8
            let plate = NSRect(x: visible.midX - textSize.width / 2 - 20, y: top - iconHeight - 12,
                               width: textSize.width + 40, height: textSize.height + iconHeight + 28)
            NSColor.textBackgroundColor.setFill()
            NSBezierPath(roundedRect: plate, xRadius: 8, yRadius: 8).fill()
        }
        if let symbol {
            let iconRect = NSRect(
                x: visible.midX - symbol.size.width / 2, y: top - symbol.size.height - 8,
                width: symbol.size.width, height: symbol.size.height)
            symbol.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1,
                        respectFlipped: true, hints: nil)
            top += 8
        }
        attributed.draw(with: NSRect(x: visible.minX + 20, y: top, width: visible.width - 40,
                                     height: textSize.height + 4),
                        options: [.usesLineFragmentOrigin])
    }

    // MARK: Selection

    private func row(at event: NSEvent) -> Int {
        let point = convert(event.locationInWindow, from: nil)
        let count = presentation.result.rows.count
        return min(max(Int(point.y / presentation.lineHeight), 0), max(count - 1, 0))
    }

    private func select(from anchor: Int, to row: Int) {
        selection = min(anchor, row)..<(max(anchor, row) + 1)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard presentation.document(side) != nil, !presentation.result.rows.isEmpty else { return }
        let clicked = row(at: event)
        if event.clickCount == 2, let hunk = presentation.result.hunk(containing: clicked) {
            let rows = presentation.result.hunks[hunk].rows
            selectionAnchor = rows.lowerBound
            selection = rows
            return
        }
        if event.modifierFlags.contains(.shift), let anchor = selectionAnchor {
            select(from: anchor, to: clicked)
        } else {
            selectionAnchor = clicked
            select(from: clicked, to: clicked)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let anchor = selectionAnchor else { return }
        autoscroll(with: event)
        select(from: anchor, to: row(at: event))
    }

    @objc func copy(_ sender: Any?) {
        guard let selection, let document = presentation.document(side) else { return }
        let lines = selection.clamped(to: presentation.result.rows.indices).compactMap { row -> String? in
            let index = presentation.lineIndex(row: row, side: side)
            return index >= 0 ? document.lines[index] : nil
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    override func selectAll(_ sender: Any?) {
        guard presentation.document(side) != nil, !presentation.result.rows.isEmpty else { return }
        selectionAnchor = 0
        selection = 0..<presentation.result.rows.count
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(copy(_:)): return selection != nil
        case #selector(selectAll(_:)): return presentation.document(side) != nil
        default: return true
        }
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
        if modifiers.isEmpty, let key = event.charactersIgnoringModifiers {
            switch key {
            case "n", "j": controller?.goToNextChange(nil); return
            case "p", "k": controller?.goToPreviousChange(nil); return
            case " ": scrollPageDown(nil); return
            case "\u{1b}":
                if controller?.isShowingProgress == true {
                    controller?.cancelOperation(nil)
                } else {
                    clearSelection()
                }
                return
            default: break
            }
        }
        interpretKeyEvents([event])
    }

    private func scrollVertically(by delta: CGFloat) {
        controller?.scrollVertically(by: delta)
    }

    override func moveDown(_ sender: Any?) { scrollVertically(by: presentation.lineHeight) }
    override func moveUp(_ sender: Any?) { scrollVertically(by: -presentation.lineHeight) }
    override func moveLeft(_ sender: Any?) { controller?.scrollHorizontally(by: -presentation.charWidth * 4) }
    override func moveRight(_ sender: Any?) { controller?.scrollHorizontally(by: presentation.charWidth * 4) }
    override func scrollPageDown(_ sender: Any?) { scrollVertically(by: pageHeight) }
    override func scrollPageUp(_ sender: Any?) { scrollVertically(by: -pageHeight) }
    override func pageDown(_ sender: Any?) { scrollPageDown(sender) }
    override func pageUp(_ sender: Any?) { scrollPageUp(sender) }
    override func scrollToBeginningOfDocument(_ sender: Any?) { scrollVertically(by: -.greatestFiniteMagnitude / 4) }
    override func scrollToEndOfDocument(_ sender: Any?) { scrollVertically(by: .greatestFiniteMagnitude / 4) }
    override func moveToBeginningOfDocument(_ sender: Any?) { scrollToBeginningOfDocument(sender) }
    override func moveToEndOfDocument(_ sender: Any?) { scrollToEndOfDocument(sender) }

    private var pageHeight: CGFloat {
        max(presentation.lineHeight, visibleRect.height - presentation.lineHeight * 2)
    }

    // MARK: Accessibility

    // The pane draws its rows itself, so it exposes the visible ones to VoiceOver as
    // static text: "Line 30, modified: ip address …". Only visible rows, so the cost
    // doesn't grow with the file.

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .list }

    override func accessibilityLabel() -> String? {
        let name = side == .left ? "Left" : "Right"
        guard let document = presentation.document(side) else { return "\(name): no file" }
        return "\(name): \(document.name)" + (document.lines.isEmpty ? ", empty file" : "")
    }

    /// Call when the documents, result or font change.
    func accessibilityRowsChanged() {
        rowElements = [:]
        NSAccessibility.post(element: self, notification: .layoutChanged)
    }

    private var visibleRowRange: Range<Int> {
        let lh = presentation.lineHeight
        let count = presentation.document(side) == nil ? 0 : presentation.result.rows.count
        let first = min(max(0, Int(floor(visibleRect.minY / lh))), count)
        return first..<min(count, max(first, Int(ceil(visibleRect.maxY / lh))))
    }

    private func element(row: Int) -> RowElement {
        if let element = rowElements[row] { return element }
        let element = RowElement(row: row, pane: self)
        rowElements[row] = element
        return element
    }

    override func accessibilityChildren() -> [Any]? {
        let rows = visibleRowRange
        // Forget elements far off screen so scrolling a long file doesn't keep them all.
        if rowElements.count > rows.count * 4 { rowElements = rowElements.filter { rows.contains($0.key) } }
        return rows.map(element(row:))
    }

    override func accessibilityVisibleChildren() -> [Any]? { accessibilityChildren() }

    override func accessibilitySelectedChildren() -> [Any]? {
        guard let selection else { return [] }
        return selection.clamped(to: visibleRowRange).map(element(row:))
    }

    override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        guard let window else { return self }
        let local = convert(window.convertPoint(fromScreen: point), from: nil)
        let row = Int(floor(local.y / presentation.lineHeight))
        return visibleRowRange.contains(row) ? element(row: row) : self
    }

    fileprivate func screenFrame(row: Int) -> NSRect {
        guard let window else { return .zero }
        let lh = presentation.lineHeight
        let rect = NSRect(x: visibleRect.minX, y: CGFloat(row) * lh, width: visibleRect.width, height: lh)
        return window.convertToScreen(convert(rect.intersection(visibleRect), to: nil))
    }

    /// What VoiceOver reads for a row: line number, kind, text, and on modified rows
    /// the highlighted parts.
    fileprivate func accessibilityDescription(row r: Int) -> String {
        let p = presentation
        guard r < p.result.rows.count, let document = p.document(side) else { return "" }
        let row = p.result.rows[r]
        let index = p.lineIndex(row: r, side: side)
        guard index < document.lines.count else { return "" }
        guard index >= 0 else {
            let other = side == .left ? "right" : "left"
            return "No line, \(row.kind == .inserted ? "added" : "removed") on the \(other)"
        }
        let text = document.lines[index]
        let kind: String
        switch row.kind {
        case .same: kind = ""  // most rows; saying "unchanged" on each would be noise
        case .changed: kind = ", modified"
        case .deleted: kind = ", removed"
        case .inserted: kind = ", added"
        }
        var label = "Line \(index + 1)\(kind): " + (text.isEmpty ? "blank" : Self.truncated(text, 300))
        if row.kind == .changed, let inline = p.inlineChanges(row: r) {
            let ns = text as NSString
            let parts = (side == .left ? inline.left : inline.right)
                .filter { $0.length > 0 && NSMaxRange($0) <= ns.length }
                .prefix(4).map { Self.truncated(ns.substring(with: $0).trimmingCharacters(in: .whitespaces), 40) }
                .filter { !$0.isEmpty }
            if !parts.isEmpty { label += ". Changed: " + parts.joined(separator: ", ") }
        }
        return label
    }

    private static func truncated(_ text: String, _ limit: Int) -> String {
        text.count > limit ? text.prefix(limit) + "…" : text
    }
}

/// One visible row of a `DiffPaneView`, for VoiceOver. Frame and label are computed
/// when asked, so they follow scrolling and font changes.
private final class RowElement: NSAccessibilityElement {
    let row: Int
    weak var pane: DiffPaneView?

    init(row: Int, pane: DiffPaneView) {
        self.row = row
        self.pane = pane
        super.init()
        setAccessibilityRole(.staticText)
        setAccessibilityParent(pane)
    }

    override func accessibilityLabel() -> String? { pane?.accessibilityDescription(row: row) }
    override func accessibilityFrame() -> NSRect { pane?.screenFrame(row: row) ?? .zero }
    override func accessibilityParent() -> Any? { pane }
    override func isAccessibilitySelected() -> Bool { pane?.selection?.contains(row) == true }
}
