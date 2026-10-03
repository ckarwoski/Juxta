import AppKit

/// A small floating bar over the panes while a slow load or comparison runs: spinner,
/// what is running, and Cancel.
final class ProgressOverlay: NSVisualEffectView {
    private let spinner = NSProgressIndicator()
    private let label = NSTextField(labelWithString: "")
    let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)

    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .popover
        blendingMode = .withinWindow
        state = .active
        // A mask rounds the material itself; a layer corner radius doesn't clip it.
        maskImage = Self.roundedMask(radius: 10)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        label.textColor = .labelColor
        cancelButton.bezelStyle = .rounded
        cancelButton.controlSize = .small
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.toolTip = "Cancel (⎋)"

        let stack = NSStackView(views: [spinner, label, cancelButton])
        stack.spacing = 10
        stack.setCustomSpacing(16, after: label)
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    static func roundedMask(radius: CGFloat) -> NSImage {
        let size = NSSize(width: radius * 2 + 1, height: radius * 2 + 1)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // The border is a CGColor, so it's refreshed for light/dark by hand.
    override func updateLayer() {
        super.updateLayer()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }

    func show(_ text: String) {
        label.stringValue = text
        guard isHidden else { return }
        isHidden = false
        spinner.startAnimation(nil)
    }

    func hide() {
        guard !isHidden else { return }
        isHidden = true
        spinner.stopAnimation(nil)
    }
}

/// A floating note over the panes for comparisons with nothing to step through
/// ("Files are identical"), which otherwise only the window subtitle would say.
/// Clicks pass through to the text.
final class NoticeOverlay: NSVisualEffectView {
    private let label = NSTextField(labelWithString: "")
    private let icon = NSImageView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .popover
        blendingMode = .withinWindow
        state = .active
        maskImage = ProgressOverlay.roundedMask(radius: 10)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        isHidden = true
        icon.contentTintColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        label.textColor = .labelColor
        let stack = NSStackView(views: [icon, label])
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 7, left: 12, bottom: 7, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateLayer() {
        super.updateLayer()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }

    /// Shows `text`, or hides the note when nil. A checkmark only when the files are
    /// byte-for-byte identical; same text that differs otherwise gets an info icon.
    func show(_ text: String?, identical: Bool = false) {
        isHidden = text == nil
        guard let text else { return }
        label.stringValue = text
        icon.image = NSImage(systemSymbolName: identical ? "checkmark.circle" : "info.circle",
                             accessibilityDescription: nil)
    }
}
