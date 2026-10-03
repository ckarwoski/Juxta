import AppKit
import JuxtaCore

/// Line numbers for one pane, each changed line marked +, − or ~ in a column on the left. Lives outside the scroll view so it stays put while the
/// text scrolls horizontally; it tracks the vertical offset of `scrollView`.
final class LineNumberView: NSView {
    private let side: Side
    private let presentation: DiffPresentation
    weak var scrollView: NSScrollView?
    weak var pane: DiffPaneView?

    init(side: Side, presentation: DiffPresentation) {
        self.side = side
        self.presentation = presentation
        super.init(frame: .zero)
        clipsToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    var requiredWidth: CGFloat {
        guard let document = presentation.document(side) else { return 0 }
        let digits = max(3, String(document.lines.count).count)
        return ceil(signColumn + CGFloat(digits) * digitWidth + 14)
    }

    private var digitWidth: CGFloat {
        ("0" as NSString).size(withAttributes: [.font: presentation.gutterFont]).width
    }

    /// Left padding plus room for the widest sign.
    private var signColumn: CGFloat { 6 + digitWidth * 1.2 }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()
        let p = presentation
        guard let scrollView, p.document(side) != nil else { return }
        let offset = scrollView.contentView.bounds.minY
        let lh = p.lineHeight
        let rows = p.result.rows
        let first = max(0, Int(floor((dirtyRect.minY + offset) / lh)))
        let last = min(rows.count, Int(ceil((dirtyRect.maxY + offset) / lh)))
        let selection = pane?.selection
        let selectionColor = pane?.hasFocus == true
            ? NSColor.selectedTextBackgroundColor : NSColor.unemphasizedSelectedTextBackgroundColor
        let attributes: [NSAttributedString.Key: Any] = [.font: p.gutterFont, .foregroundColor: Theme.lineNumber]
        var selectedAttributes = attributes
        selectedAttributes[.foregroundColor] = NSColor.labelColor
        let numberHeight = ceil(p.gutterFont.ascender - p.gutterFont.descender)

        if first < last {
            for r in first..<last {
                let row = rows[r]
                let y = CGFloat(r) * lh - offset
                let rowRect = NSRect(x: 0, y: y, width: bounds.width, height: lh)
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
                let label = String(index + 1) as NSString
                let style = selected ? selectedAttributes : attributes
                let textY = y + (lh - numberHeight) / 2
                let width = label.size(withAttributes: style).width
                label.draw(at: NSPoint(x: bounds.width - width - 8, y: textY), withAttributes: style)
                // Centered on the digits' middle, where a font's + and − sit.
                let size = digitWidth * 0.9
                let midY = textY + p.gutterFont.ascender - p.gutterFont.xHeight / 2
                Theme.drawSign(for: row.kind,
                               in: NSRect(x: (6 + signColumn - size) / 2, y: midY - size / 2, width: size, height: size),
                               color: style[.foregroundColor] as! NSColor)
            }
        }
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.width - 1, y: dirtyRect.minY, width: 1, height: dirtyRect.height).fill()
    }

    override func mouseDown(with event: NSEvent) { pane?.mouseDown(with: event) }
    override func mouseDragged(with event: NSEvent) { pane?.mouseDragged(with: event) }
    override func scrollWheel(with event: NSEvent) { scrollView?.scrollWheel(with: event) }
}

/// Vertical scroll bar that shows where every difference is. Click or drag to jump.
final class ChangeMapView: NSView {
    private let presentation: DiffPresentation
    weak var controller: CompareWindowController?
    private var dragOffset: CGFloat?
    private let inset: CGFloat = 4

    init(presentation: DiffPresentation) {
        self.presentation = presentation
        super.init(frame: .zero)
        clipsToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    private var trackHeight: CGFloat { max(1, bounds.height - inset * 2) }

    /// The visible portion of the document, as fractions of its total height.
    private var viewport: (top: CGFloat, height: CGFloat)? {
        guard let metrics = controller?.scrollMetrics, metrics.total > 0 else { return nil }
        return (metrics.offset / metrics.total, min(1, metrics.visible / metrics.total))
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        dirtyRect.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: dirtyRect.minY, width: 1, height: dirtyRect.height).fill()

        // When everything fits on screen the panes already show every change, and
        // stretching a few rows over the whole track would exaggerate them.
        let scrolls = viewport.map { $0.height < 1 } ?? false
        let tip = scrolls ? "Change map — click to jump" : nil
        if toolTip != tip { toolTip = tip }
        guard scrolls, let viewport else { return }

        let p = presentation
        let rowCount = p.result.rows.count
        if rowCount > 0 {
            let scale = trackHeight / CGFloat(rowCount)
            for segment in p.segments {
                let y = inset + CGFloat(segment.rows.lowerBound) * scale
                let h = max(2, CGFloat(segment.rows.count) * scale)
                Theme.marker(for: segment.kind).setFill()
                NSRect(x: 4, y: y, width: bounds.width - 7, height: h).fill()
            }
        }

        let path = NSBezierPath(roundedRect: knobRect(viewport), xRadius: 3, yRadius: 3)
        NSColor.labelColor.withAlphaComponent(0.13).setFill()
        path.fill()
        NSColor.labelColor.withAlphaComponent(0.35).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    private func knobRect(_ viewport: (top: CGFloat, height: CGFloat)) -> NSRect {
        let h = max(16, viewport.height * trackHeight)
        let y = inset + viewport.top * (trackHeight - h) / max(0.0001, 1 - viewport.height)
        return NSRect(x: 1.5, y: y, width: bounds.width - 3, height: h).insetBy(dx: 0.5, dy: 0.5)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let viewport, viewport.height < 1 {
            let knob = knobRect(viewport)
            dragOffset = knob.contains(point) ? point.y - knob.minY : knob.height / 2
            scrollKnob(to: point.y)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        scrollKnob(to: convert(event.locationInWindow, from: nil).y)
    }

    override func mouseUp(with event: NSEvent) {
        dragOffset = nil
    }

    private func scrollKnob(to y: CGFloat) {
        guard let viewport, let dragOffset, let controller,
              let metrics = controller.scrollMetrics else { return }
        let knobHeight = knobRect(viewport).height
        let travel = trackHeight - knobHeight
        guard travel > 0 else { return }
        let fraction = min(max((y - dragOffset - inset) / travel, 0), 1)
        controller.scroll(toY: fraction * (metrics.total - metrics.visible))
    }

    override func scrollWheel(with event: NSEvent) {
        controller?.forwardScrollWheel(event)
    }

    // MARK: Accessibility

    // A slider whose increment and decrement step through the changes, and whose value
    // says how many there are and what is on screen.
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .slider }
    override func accessibilityLabel() -> String? { "Change map" }
    override func accessibilityHelp() -> String? { "Increment or decrement to go to the next or previous change" }
    override func accessibilityValue() -> Any? { NSNumber(value: Double(viewport?.top ?? 0)) }
    override func accessibilityMinValue() -> Any? { NSNumber(value: 0.0) }
    override func accessibilityMaxValue() -> Any? { NSNumber(value: 1.0) }

    override func accessibilityValueDescription() -> String? {
        let p = presentation
        let count = p.result.hunks.count
        var parts = [count == 0 ? "No changes" : count == 1 ? "1 change" : "\(count.formatted()) changes"]
        if let current = p.currentHunk { parts.append("at change \(current + 1)") }
        if let metrics = controller?.scrollMetrics, !p.result.rows.isEmpty {
            let first = min(Int(metrics.offset / p.lineHeight) + 1, p.result.rows.count)
            let last = min(Int((metrics.offset + metrics.visible) / p.lineHeight), p.result.rows.count)
            parts.append("showing rows \(first) to \(max(first, last)) of \(p.result.rows.count.formatted())")
        }
        return parts.joined(separator: ", ")
    }

    override func accessibilityPerformIncrement() -> Bool {
        controller?.goToNextChange(nil)
        return true
    }

    override func accessibilityPerformDecrement() -> Bool {
        controller?.goToPreviousChange(nil)
        return true
    }
}

/// Plain header strip background with a bottom hairline.
class HeaderBackgroundView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: dirtyRect.minX, y: bounds.height - 1, width: dirtyRect.width, height: 1).fill()
    }
}

/// File name, location and an Open button above each pane.
final class PaneHeaderView: HeaderBackgroundView {
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    /// Encoding, line endings and so on; parts that differ from the other file are
    /// highlighted, since lines are compared without them.
    private let formatLabel = NSTextField(labelWithString: "")
    let openButton = NSButton()

    override init(frame: NSRect) {
        super.init(frame: frame)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        // Decorative; the name label says what the file is.
        iconView.setAccessibilityElement(false)
        nameLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingMiddle
        for label in [nameLabel, detailLabel] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        formatLabel.font = .systemFont(ofSize: 11)
        formatLabel.textColor = .secondaryLabelColor
        formatLabel.setContentHuggingPriority(.required, for: .horizontal)
        openButton.bezelStyle = .accessoryBarAction
        openButton.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "Open")
        openButton.title = "Open…"
        openButton.imagePosition = .imageLeading
        openButton.controlSize = .small
        openButton.setContentHuggingPriority(.required, for: .horizontal)

        let labels = NSStackView(views: [nameLabel, detailLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 0
        labels.setHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [iconView, labels, formatLabel, openButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.distribution = .fill
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 24),
            iconView.heightAnchor.constraint(equalToConstant: 24),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            row.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -0.5),
        ])
        configure(with: nil, comparedWith: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(with document: TextDocument?, comparedWith other: TextDocument?) {
        configureFormat(document?.format, comparedWith: other?.format)
        guard let document else {
            nameLabel.stringValue = "No file"
            nameLabel.textColor = .secondaryLabelColor
            detailLabel.stringValue = "Drop, open or paste"
            iconView.image = NSImage(systemSymbolName: "doc", accessibilityDescription: nil)
            toolTip = nil
            return
        }
        nameLabel.stringValue = document.name
        nameLabel.textColor = .labelColor
        let lineCount = document.lines.count.formatted() + (document.lines.count == 1 ? " line" : " lines")
        if let url = document.url {
            let folder = (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
            detailLabel.stringValue = "\(folder) · \(lineCount)"
            iconView.image = NSWorkspace.shared.icon(forFile: url.path)
            toolTip = url.path
        } else {
            detailLabel.stringValue = "Pasted text · \(lineCount)"
            iconView.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: nil)
            toolTip = nil
        }
    }

    private func configureFormat(_ format: TextFormat?, comparedWith other: TextFormat?) {
        guard let format else {
            formatLabel.attributedStringValue = NSAttributedString()
            formatLabel.toolTip = nil
            return
        }
        let differing = other.map { format.differences(from: $0) } ?? []
        let text = NSMutableAttributedString()
        for aspect in TextFormat.Aspect.allCases {
            guard let label = format.label(for: aspect) else { continue }
            if text.length > 0 {
                text.append(NSAttributedString(string: " · ", attributes: [.foregroundColor: NSColor.tertiaryLabelColor]))
            }
            let differs = differing.contains(aspect)
            text.append(NSAttributedString(string: label, attributes: [
                .foregroundColor: differs ? Theme.formatDiffers : NSColor.secondaryLabelColor,
                .font: NSFont.systemFont(ofSize: 11, weight: differs ? .semibold : .regular),
            ]))
        }
        formatLabel.attributedStringValue = text
        formatLabel.toolTip = differing.isEmpty ? nil
            : "Differs from the other file: " + differing.map(\.rawValue).joined(separator: ", ")
            + ". Lines are compared without these, so they're shown here instead."
    }
}
