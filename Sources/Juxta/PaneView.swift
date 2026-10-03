import AppKit
import JuxtaCore

/// One side of the window: header, line numbers and the scrolling text pane.
/// Accepts file drops.
final class PaneView: NSView {
    let side: Side
    let header = PaneHeaderView()
    let lineNumbers: LineNumberView
    let scrollView = NSScrollView()
    let diffView: DiffPaneView
    private let dropHighlight = DropHighlightView()
    private var lineNumberWidth: NSLayoutConstraint!
    var onDrop: (([URL]) -> Void)?

    static let headerHeight: CGFloat = 44

    init(side: Side, presentation: DiffPresentation) {
        self.side = side
        lineNumbers = LineNumberView(side: side, presentation: presentation)
        diffView = DiffPaneView(side: side, presentation: presentation)
        super.init(frame: .zero)

        scrollView.documentView = diffView
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = true
        // Keep horizontal scrollers consistent on both sides so rows stay aligned
        // when the system uses legacy (always-visible) scroll bars.
        scrollView.autohidesScrollers = false
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.verticalScrollElasticity = .allowed
        scrollView.contentView.postsBoundsChangedNotifications = true

        lineNumbers.scrollView = scrollView
        lineNumbers.pane = diffView
        diffView.onSelectionChange = { [weak self] in self?.lineNumbers.needsDisplay = true }

        for view in [header, lineNumbers, scrollView, dropHighlight] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        lineNumberWidth = lineNumbers.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: Self.headerHeight),
            lineNumbers.topAnchor.constraint(equalTo: header.bottomAnchor),
            lineNumbers.leadingAnchor.constraint(equalTo: leadingAnchor),
            lineNumbers.bottomAnchor.constraint(equalTo: bottomAnchor),
            lineNumberWidth,
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: lineNumbers.trailingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            dropHighlight.topAnchor.constraint(equalTo: topAnchor),
            dropHighlight.leadingAnchor.constraint(equalTo: leadingAnchor),
            dropHighlight.trailingAnchor.constraint(equalTo: trailingAnchor),
            dropHighlight.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        diffView.updateSize()
    }

    /// Call after the document, diff result or font changes.
    func refresh(document: TextDocument?, comparedWith other: TextDocument?) {
        header.configure(with: document, comparedWith: other)
        lineNumberWidth.constant = lineNumbers.requiredWidth
        layoutSubtreeIfNeeded()
        diffView.updateSize()
        diffView.needsDisplay = true
        diffView.accessibilityRowsChanged()
        lineNumbers.needsDisplay = true
    }

    // MARK: Drag and drop

    private func fileURLs(from info: NSDraggingInfo) -> [URL] {
        let urls = info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { url in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                && !isDirectory.boolValue
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !fileURLs(from: sender).isEmpty else { return [] }
        dropHighlight.isHidden = false
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropHighlight.isHidden = true
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        dropHighlight.isHidden = true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropHighlight.isHidden = true
        let urls = fileURLs(from: sender)
        guard !urls.isEmpty else { return false }
        onDrop?(urls)
        return true
    }
}

private final class DropHighlightView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlAccentColor.withAlphaComponent(0.08).setFill()
        bounds.fill()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 6, yRadius: 6)
        path.lineWidth = 3
        NSColor.controlAccentColor.setStroke()
        path.stroke()
    }
}
