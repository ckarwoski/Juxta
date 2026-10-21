import AppKit
import JuxtaCore
import UniformTypeIdentifiers

struct ScrollMetrics {
    var offset: CGFloat
    var visible: CGFloat
    var total: CGFloat
}

enum Preferences {
    private static var defaults: UserDefaults { .standard }

    static var options: DiffOptions {
        get {
            DiffOptions(ignoreWhitespace: defaults.bool(forKey: "ignoreWhitespace"),
                        ignoreCase: defaults.bool(forKey: "ignoreCase"),
                        ignoreTimers: defaults.bool(forKey: "ignoreTimers"))
        }
        set {
            defaults.set(newValue.ignoreWhitespace, forKey: "ignoreWhitespace")
            defaults.set(newValue.ignoreCase, forKey: "ignoreCase")
            defaults.set(newValue.ignoreTimers, forKey: "ignoreTimers")
        }
    }

    /// Every window follows it: setting it tells them all to redraw.
    static var textStyle: TextStyle {
        get {
            var style = TextStyle()
            style.fontName = defaults.string(forKey: "fontName")
            if defaults.object(forKey: "fontWeight") != nil {
                style.systemWeight = NSFont.Weight(defaults.double(forKey: "fontWeight"))
            }
            let size = defaults.double(forKey: "fontSize")
            if size > 0 { style.size = TextStyle.clamp(size) }
            style.zoom = defaults.double(forKey: "textZoom")
            if defaults.object(forKey: "lineSpacing") != nil {
                style.lineSpacing = TextStyle.LineSpacing(rawValue: defaults.integer(forKey: "lineSpacing")) ?? .normal
            }
            style.ligatures = defaults.bool(forKey: "ligatures")
            return style
        }
        set {
            guard newValue != textStyle else { return }
            defaults.set(newValue.fontName, forKey: "fontName")
            defaults.set(Double(newValue.systemWeight.rawValue), forKey: "fontWeight")
            defaults.set(Double(newValue.size), forKey: "fontSize")
            defaults.set(Double(newValue.zoom), forKey: "textZoom")
            defaults.set(newValue.lineSpacing.rawValue, forKey: "lineSpacing")
            defaults.set(newValue.ligatures, forKey: "ligatures")
            NotificationCenter.default.post(name: .textStyleDidChange, object: nil)
        }
    }
}

private extension NSToolbarItem.Identifier {
    static let navigate = Self("navigate")
    static let options = Self("options")
    static let swap = Self("swap")
    static let reload = Self("reload")
}

/// One comparison window: two panes whose scrolling is locked together, plus the
/// change map on the right.
final class CompareWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate,
    NSMenuItemValidation, NSToolbarItemValidation {
    let presentation: DiffPresentation
    private let leftPane: PaneView
    private let rightPane: PaneView
    private let changeMap: ChangeMapView
    private var isSyncingScroll = false
    private let progressOverlay = ProgressOverlay()
    private let noticeOverlay = NoticeOverlay()
    /// The comparison has a note to show; it hides while it would cover the last rows.
    private var noticeWanted = false
    private var generation = 0
    private var loadGeneration = 0
    /// The load each side is waiting for. Pasting into a side (or swapping) drops its
    /// entry, so a load that finishes later can't overwrite what the user did since.
    private var pendingLoads: [Side: Int] = [:] { didSet { busyChanged() } }
    /// Stops the running comparison's engine work once its result isn't wanted.
    private var cancellation: Cancellation?
    private(set) var isComparing = false { didSet { busyChanged() } }
    private var isLoading: Bool { !pendingLoads.isEmpty }
    /// The user cancelled the comparison, so the documents are shown unaligned.
    private var compareCancelled = false
    private var pendingProgress: DispatchWorkItem?
    /// A hunk navigated to whose long first row was still being diffed, and where the
    /// view was then: its change is revealed when it arrives unless the user scrolled.
    private var pendingReveal: (row: Int, origin: [NSPoint])?
    var onClose: ((CompareWindowController) -> Void)?

    /// The saved comparison shown, from the `.juxta` file this window opened or last saved
    /// to; nil once a side is replaced, since the window no longer shows it.
    private(set) var saved: SavedComparison?
    private var savedURL: URL?
    /// The sides of the comparison last opened or saved here. A side that came from a
    /// `.juxta` file has no file to read again, so saving takes its bytes from these.
    private var snapshotSides: [SavedComparison.Side] = []
    /// Sides whose bytes were edited after they were saved.
    private var editedSides: Set<Side> = []
    /// Counts document changes, swaps included, so a save that finishes after one
    /// doesn't relabel the window with the names it was given for the old sides.
    private var documentsVersion = 0
    /// Sides still showing what a `.juxta` file opened here. While there are any, the
    /// window keeps the options saved in that file instead of remembering its toggles.
    private var openedSides: Set<Side> = []
    /// Where each side shown from a `.juxta` file was loaded from, for exported pages.
    private var savedPaths: [Side: String] = [:]
    private var remembersOptions: Bool { openedSides.isEmpty }
    /// A save is writing; another waits until it's done.
    private var isSaving = false

    /// This window's options; new windows start from `Preferences.options`.
    private var options: DiffOptions {
        get { presentation.options }
        set { presentation.options = newValue }
    }

    init() {
        presentation = DiffPresentation(options: Preferences.options, textStyle: Preferences.textStyle)
        leftPane = PaneView(side: .left, presentation: presentation)
        rightPane = PaneView(side: .right, presentation: presentation)
        changeMap = ChangeMapView(presentation: presentation)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.minSize = NSSize(width: 640, height: 320)
        window.tabbingIdentifier = "JuxtaComparison"
        window.isReleasedWhenClosed = false
        window.title = "Juxta"
        super.init(window: window)
        window.delegate = self

        buildContent(in: window)
        buildToolbar(for: window)
        changeMap.controller = self
        for pane in [leftPane, rightPane] {
            pane.diffView.controller = self
            pane.header.openButton.target = self
            pane.header.openButton.action = pane.side == .left
                ? #selector(chooseLeftFile(_:)) : #selector(chooseRightFile(_:))
            let side = pane.side
            pane.onDrop = { [weak self] urls in self?.handleDrop(urls, on: side) }
            NotificationCenter.default.addObserver(
                self, selector: #selector(clipViewBoundsChanged(_:)),
                name: NSView.boundsDidChangeNotification, object: pane.scrollView.contentView)
        }
        presentation.onInlineChanges = { [weak self] row in
            self?.redraw(row: row)
            self?.inlineChangesArrived(row: row)
        }
        presentation.visibleRows = { [weak self] in self?.visibleRows() ?? 0..<0 }
        NotificationCenter.default.addObserver(
            self, selector: #selector(textStyleDidChange(_:)), name: .textStyleDidChange, object: nil)
        window.initialFirstResponder = leftPane.diffView
        documentsChanged()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var hasEmptySide: Bool { presentation.left == nil || presentation.right == nil }
    var isEmpty: Bool { presentation.left == nil && presentation.right == nil }
    /// Sides with no document and none on the way, which opening files may fill.
    var freeSides: [Side] { [Side.left, .right].filter { presentation.document($0) == nil && pendingLoads[$0] == nil } }

    // MARK: Layout

    private func buildContent(in window: NSWindow) {
        let content = NSView()
        let divider = NSBox()
        divider.boxType = .separator
        let corner = HeaderBackgroundView()
        progressOverlay.isHidden = true
        progressOverlay.cancelButton.target = self
        progressOverlay.cancelButton.action = #selector(cancelOperation(_:))
        for view in [leftPane, divider, rightPane, corner, changeMap, noticeOverlay, progressOverlay] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            leftPane.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            leftPane.topAnchor.constraint(equalTo: content.topAnchor),
            leftPane.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: leftPane.trailingAnchor),
            divider.topAnchor.constraint(equalTo: content.topAnchor),
            divider.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            rightPane.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            rightPane.topAnchor.constraint(equalTo: content.topAnchor),
            rightPane.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            rightPane.widthAnchor.constraint(equalTo: leftPane.widthAnchor),
            corner.leadingAnchor.constraint(equalTo: rightPane.trailingAnchor),
            corner.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            corner.topAnchor.constraint(equalTo: content.topAnchor),
            corner.heightAnchor.constraint(equalToConstant: PaneView.headerHeight),
            changeMap.leadingAnchor.constraint(equalTo: rightPane.trailingAnchor),
            changeMap.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            changeMap.topAnchor.constraint(equalTo: corner.bottomAnchor),
            changeMap.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            changeMap.widthAnchor.constraint(equalToConstant: 16),
            progressOverlay.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            progressOverlay.topAnchor.constraint(equalTo: content.topAnchor, constant: PaneView.headerHeight + 16),
            noticeOverlay.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            noticeOverlay.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24),
        ])
        window.contentView = content
    }

    private func buildToolbar(for window: NSWindow) {
        let toolbar = NSToolbar(identifier: "CompareToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.navigate, .flexibleSpace, .options, .swap, .reload]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        func symbol(_ name: String, _ description: String) -> NSImage {
            NSImage(systemSymbolName: name, accessibilityDescription: description) ?? NSImage()
        }
        switch identifier {
        case .navigate:
            let group = NSToolbarItemGroup(
                itemIdentifier: identifier,
                images: [symbol("chevron.up", "Previous Change"), symbol("chevron.down", "Next Change")],
                selectionMode: .momentary, labels: ["Previous", "Next"],
                target: self, action: #selector(navigateFromToolbar(_:)))
            group.label = "Changes"
            group.subitems[0].toolTip = "Previous Change (⌥⌘↑)"
            group.subitems[1].toolTip = "Next Change (⌥⌘↓)"
            return group
        case .options:
            let item = NSMenuToolbarItem(itemIdentifier: identifier)
            item.image = symbol("slider.horizontal.3", "Options")
            item.label = "Options"
            item.toolTip = "Comparison Options"
            let menu = NSMenu()
            menu.addItem(withTitle: "Ignore Whitespace", action: #selector(toggleIgnoreWhitespace(_:)), keyEquivalent: "")
            menu.addItem(withTitle: "Ignore Case", action: #selector(toggleIgnoreCase(_:)), keyEquivalent: "")
            menu.addItem(withTitle: "Ignore Timers", action: #selector(toggleIgnoreTimers(_:)), keyEquivalent: "")
            item.menu = menu
            return item
        case .swap:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.image = symbol("arrow.left.arrow.right", "Swap Sides")
            item.label = "Swap"
            item.toolTip = "Swap Left and Right"
            item.isBordered = true
            item.target = self
            item.action = #selector(swapSides(_:))
            return item
        case .reload:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.image = symbol("arrow.clockwise", "Reload")
            item.label = "Reload"
            item.toolTip = "Reload Files from Disk (⌘R)"
            item.isBordered = true
            item.target = self
            item.action = #selector(reloadDocuments(_:))
            return item
        default:
            return nil
        }
    }

    @objc private func navigateFromToolbar(_ sender: NSToolbarItemGroup) {
        navigate(forward: sender.selectedIndex == 1)
    }

    // MARK: Loading

    func load(left: URL?, right: URL?) {
        guard left != nil || right != nil else { return }
        loadGeneration += 1
        let token = loadGeneration
        if left != nil { pendingLoads[.left] = token }
        if right != nil { pendingLoads[.right] = token }
        busyChanged(restartingDelay: true)
        updateSubtitle()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let leftResult = left.map { url in Result { try TextDocument.load(from: url) } }
            let rightResult = right.map { url in Result { try TextDocument.load(from: url) } }
            DispatchQueue.main.async { [weak self] in
                // A cancelled or superseded load can't stop reading, so its documents
                // are dropped here, per side.
                guard let self else { return }
                let sides = [Side.left, .right].filter { self.pendingLoads[$0] == token }
                guard !sides.isEmpty else { return }
                let anchor = self.topLine()
                var failures: [String] = []
                for (side, result) in [(Side.left, leftResult), (Side.right, rightResult)] where sides.contains(side) {
                    switch result {
                    case .success(let document)?:
                        self.sideReplaced(side)
                        self.presentation.setDocument(document, for: side)
                    case .failure(let error)?:
                        failures.append("\(side == .left ? "Left" : "Right"): \(error.localizedDescription)")
                    case nil: break
                    }
                }
                self.documentsChanged(restoring: anchor)
                // Cleared after the comparison has started, so a visible bar stays up.
                for side in sides { self.pendingLoads[side] = nil }
                self.updateSubtitle()
                if !failures.isEmpty, let window = self.window {
                    let alert = NSAlert()
                    alert.messageText = failures.count == 1 ? "A file couldn't be opened" : "The files couldn't be opened"
                    alert.informativeText = failures.joined(separator: "\n")
                    alert.beginSheetModal(for: window)
                }
            }
        }
    }

    func load(_ url: URL, into side: Side) {
        load(left: side == .left ? url : nil, right: side == .right ? url : nil)
    }

    private func handleDrop(_ urls: [URL], on side: Side) {
        // A saved comparison opens in its own window, never on one side of this one.
        let comparisons = urls.filter(Self.isSavedComparison)
        if !comparisons.isEmpty { (NSApp.delegate as? AppDelegate)?.openFiles(comparisons) }
        let urls = urls.filter { !Self.isSavedComparison($0) }
        if urls.count >= 2 {
            load(left: urls[0], right: urls[1])
        } else if let url = urls.first {
            load(url, into: side)
        }
    }

    private func setPastedText(_ text: String, on side: Side) {
        let anchor = topLine()
        pendingLoads[side] = nil
        sideReplaced(side)
        presentation.setDocument(TextDocument(text: text, name: "Pasted Text"), for: side)
        documentsChanged(restoring: anchor)
    }

    func paste(_ text: String, into side: Side) {
        setPastedText(text, on: side)
    }

    /// Shows the interim result the presentation installed for the new documents,
    /// then compares them.
    private func documentsChanged(restoring anchor: (side: Side, line: Int)? = nil) {
        documentsVersion += 1
        leftPane.diffView.clearSelection()
        rightPane.diffView.clearSelection()
        updateTitle()
        showResult(restoring: anchor)
        recompute()
    }

    private func updateTitle() {
        guard let window else { return }
        window.representedURL = savedURL
        let names = [presentation.left?.name, presentation.right?.name]
        if let savedURL {
            window.title = FileManager.default.displayName(atPath: savedURL.path)
        } else if names.allSatisfy({ $0 == nil }) {
            window.title = "Juxta"
        } else {
            window.title = names.map { $0 ?? "…" }.joined(separator: " ⇄ ")
        }
    }

    /// A side loaded or pasted over leaves the saved comparison behind. Its sides are
    /// kept, since the other side may still be one of them.
    private func sideReplaced(_ side: Side) {
        editedSides.remove(side)
        openedSides.remove(side)
        savedPaths[side] = nil
        saved = nil
        savedURL = nil
    }

    // MARK: Saved comparisons

    static func isSavedComparison(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "juxta"
    }

    /// Declared in Info.plist; a SwiftPM build has no Info.plist, so it falls back to a
    /// type made from the extension.
    private static let comparisonType = UTType("com.moondustries.juxta.comparison")
        ?? UTType(filenameExtension: "juxta", conformingTo: .data) ?? .data

    /// Opens a `.juxta` file in this window, which is new. If it can't be read, an alert
    /// says why and the window closes.
    func open(savedAt url: URL) {
        loadGeneration += 1
        let token = loadGeneration
        pendingLoads = [.left: token, .right: token]
        busyChanged(restartingDelay: true)
        updateSubtitle()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { () -> (SavedComparison, TextDocument, TextDocument) in
                let saved = try SavedComparison(data: Data(contentsOf: url, options: .mappedIfSafe))
                let documents = try saved.documents()
                return (saved, documents.left, documents.right)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                // Half a saved comparison is never shown: pasting over a side drops it,
                // and the other side stops waiting for it.
                guard self.pendingLoads[.left] == token, self.pendingLoads[.right] == token else {
                    for side in [Side.left, .right] where self.pendingLoads[side] == token {
                        self.pendingLoads[side] = nil
                    }
                    self.updateSubtitle()
                    return
                }
                switch result {
                case .success(let (saved, left, right)):
                    self.saved = saved
                    self.savedURL = url
                    self.snapshotSides = [saved.left, saved.right]
                    self.editedSides = Set([(Side.left, saved.left), (.right, saved.right)]
                        .filter { !$0.1.matchesDigest }.map(\.0))
                    self.openedSides = [.left, .right]
                    self.savedPaths = Self.paths(saved)
                    self.options = saved.options
                    self.presentation.setDocument(left, for: .left)
                    self.presentation.setDocument(right, for: .right)
                    self.documentsChanged()
                    NSDocumentController.shared.noteNewRecentDocumentURL(url)
                    self.pendingLoads.removeAll()
                    self.updateSubtitle()
                case .failure(let error):
                    self.pendingLoads.removeAll()
                    self.updateSubtitle()
                    guard let window = self.window else { return }
                    let alert = NSAlert()
                    alert.messageText = "“\(url.lastPathComponent)” couldn't be opened"
                    alert.informativeText = error.localizedDescription
                    alert.beginSheetModal(for: window) { _ in self.close() }
                }
            }
        }
    }

    @objc func saveComparison(_ sender: Any?) {
        guard let window, let left = presentation.left, let right = presentation.right else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [Self.comparisonType]
        panel.isExtensionHidden = false
        let fields = SaveFields(panel: panel, left: left.name, right: right.name, note: saved?.note ?? "")
        panel.accessoryView = fields.view
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            self.write(to: url, leftName: fields.leftName, rightName: fields.rightName, note: fields.note) { error in
                if let error { self.saveFailed(error) }
            }
        }
    }

    /// Writes both sides to `url`, file sides read again from disk and checked against
    /// what was compared. Both the save panel and the debug `saveReopen` step save here.
    func write(to url: URL, leftName: String, rightName: String, note: String,
               completion: @escaping (Error?) -> Void) {
        guard let left = presentation.left, let right = presentation.right else {
            return completion(SaveError.emptySide)
        }
        let options = options, previous = snapshotSides, version = documentsVersion
        isSaving = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { () -> SavedComparison in
                func side(_ document: TextDocument, _ name: String) throws -> SavedComparison.Side {
                    let data = document.url.flatMap { try? Data(contentsOf: $0) }
                    var side = try SavedComparison.Side(document: document, fileData: data, previous: previous)
                    side.name = name.isEmpty ? document.name : name
                    return side
                }
                let saved = SavedComparison(note: note, options: options,
                                            left: try side(left, leftName), right: try side(right, rightName))
                try saved.encode().write(to: url, options: .atomic)
                return saved
            }
            DispatchQueue.main.async { [weak self] in
                self?.isSaving = false
                switch result {
                case .success(let saved):
                    NSDocumentController.shared.noteNewRecentDocumentURL(url)
                    if let self, version == self.documentsVersion { self.didSave(saved, to: url) }
                    completion(nil)
                case .failure(let error):
                    completion(error)
                }
            }
        }
    }

    private static func paths(_ saved: SavedComparison) -> [Side: String] {
        var paths: [Side: String] = [:]
        for (side, saved) in [(Side.left, saved.left), (.right, saved.right)] {
            if case .file(let path) = saved.source, !path.isEmpty { paths[side] = path }
        }
        return paths
    }

    // MARK: Exporting

    @objc func exportHTML(_ sender: Any?) {
        guard let window, let left = presentation.left, let right = presentation.right else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.html]
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = SaveFields.fileName(note: saved?.note ?? "", left: left.name, right: right.name,
                                                         extension: "html")
        let fields = ExportFields()
        panel.accessoryView = fields.view
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            fields.remember()
            self.exportHTML(to: url, extent: fields.extent, includesPaths: fields.includesPaths) { error in
                guard let error, let window = self.window else { return }
                let alert = NSAlert()
                alert.messageText = "The page couldn't be exported"
                alert.informativeText = error.localizedDescription
                alert.beginSheetModal(for: window)
            }
        }
    }

    /// Writes the comparison as shown, with this window's options, as an HTML page. Both
    /// the export panel and the debug `exportHTML` step export here.
    func exportHTML(to url: URL, extent: HTMLReport.Extent, includesPaths: Bool,
                    completion: @escaping (Error?) -> Void) {
        guard let left = presentation.left, let right = presentation.right else {
            return completion(SaveError.emptySide)
        }
        var report = HTMLReport(left: left, right: right, result: presentation.result, options: options)
        // Paths are left out unless asked for, since the page is meant to be shared.
        if includesPaths {
            report.leftPath = (left.url?.path ?? savedPaths[.left]).map(HTMLReport.displayPath)
            report.rightPath = (right.url?.path ?? savedPaths[.right]).map(HTMLReport.displayPath)
        }
        report.extent = extent
        if let saved {
            report.note = saved.note
            report.date = saved.saved
            report.dateLabel = "Saved"
        }
        report.notices = [editedNotice].compactMap { $0 }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try Data(report.render().utf8).write(to: url, options: .atomic) }
            DispatchQueue.main.async {
                if case .failure(let error) = result { completion(error) } else { completion(nil) }
            }
        }
    }

    private func didSave(_ saved: SavedComparison, to url: URL) {
        self.saved = saved
        savedURL = url
        snapshotSides = [saved.left, saved.right]
        savedPaths = Self.paths(saved)
        editedSides = Set([(Side.left, saved.left), (.right, saved.right)].filter { !$0.1.matchesDigest }.map(\.0))
        presentation.rename(.left, to: saved.left.name)
        presentation.rename(.right, to: saved.right.name)
        refreshViews()
        updateTitle()
        updateSubtitle()
    }

    private func saveFailed(_ error: Error) {
        guard let window else { return }
        let alert = NSAlert()
        switch error {
        case SavedComparisonError.fileChanged, SavedComparisonError.fileMissing:
            alert.messageText = error.localizedDescription
            alert.informativeText = "Juxta saves only what it compared. Reload to compare the files as they are now, then save again."
            alert.addButton(withTitle: "Reload")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) { [weak self] response in
                if response == .alertFirstButtonReturn { self?.reloadDocuments(nil) }
            }
        default:
            alert.messageText = "The comparison couldn't be saved"
            alert.informativeText = error.localizedDescription
            alert.beginSheetModal(for: window)
        }
    }

    // MARK: Comparing

    private func recompute() {
        generation += 1
        let token = generation
        let anchor = topLine()
        cancellation?.cancel()
        compareCancelled = false
        guard let left = presentation.left, let right = presentation.right else {
            isComparing = false
            apply(Comparator.passthrough(leftCount: presentation.left?.lines.count,
                                         rightCount: presentation.right?.lines.count),
                  restoring: anchor)
            return
        }
        isComparing = true
        // Chained after a load, the delay that started with the load carries on.
        busyChanged(restartingDelay: !isLoading)
        updateSubtitle()
        let options = options
        let cancellation = Cancellation()
        self.cancellation = cancellation
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            #if DEBUG
            Self.debugSlowCompare(cancellation)
            #endif
            let result = Comparator.compare(left.lines, right.lines, options: options, cancellation: cancellation)
            DispatchQueue.main.async { [weak self] in
                guard let self, token == self.generation, let result else { return }
                self.isComparing = false
                self.apply(result, restoring: anchor)
            }
        }
    }

    #if DEBUG
    /// `JUXTA_SLOW_COMPARE=<seconds>` delays each comparison (cancellably), to see the
    /// progress bar on inputs that compare quickly.
    private static func debugSlowCompare(_ cancellation: Cancellation) {
        guard let seconds = Double(ProcessInfo.processInfo.environment["JUXTA_SLOW_COMPARE"] ?? "") else { return }
        let end = Date(timeIntervalSinceNow: seconds)
        while Date() < end && !cancellation.isCancelled { Thread.sleep(forTimeInterval: 0.01) }
    }
    #endif

    /// Shows the progress bar once loading or comparing has run for a while; fast work
    /// finishes before it would appear, so it doesn't flash. A new operation restarts the
    /// delay, so the bar never shows sooner than 0.5 s into it.
    private func busyChanged(restartingDelay: Bool = false) {
        guard isLoading || isComparing else {
            pendingProgress?.cancel()
            pendingProgress = nil
            progressOverlay.hide()
            return
        }
        let text = isLoading ? "Loading…" : "Comparing…"
        if !progressOverlay.isHidden {
            progressOverlay.show(text)
            return
        }
        if restartingDelay {
            pendingProgress?.cancel()
            pendingProgress = nil
        }
        if pendingProgress == nil {
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pendingProgress = nil
                guard self.isLoading || self.isComparing else { return }
                self.progressOverlay.show(self.isLoading ? "Loading…" : "Comparing…")
            }
            pendingProgress = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
        }
    }

    var isShowingProgress: Bool { !progressOverlay.isHidden }

    /// Cancel (button or ⎋): stops waiting for the load and/or comparison. A cancelled
    /// load keeps the documents shown; a cancelled comparison leaves them unaligned.
    override func cancelOperation(_ sender: Any?) {
        guard isLoading || isComparing else { return }
        pendingLoads.removeAll()
        if isComparing {
            generation += 1
            cancellation?.cancel()
            isComparing = false
            compareCancelled = true
            apply(Comparator.passthrough(leftCount: presentation.left?.lines.count,
                                         rightCount: presentation.right?.lines.count),
                  restoring: topLine())
        }
        updateSubtitle()
    }

    /// The documents are the same, so each pane keeps the same lines selected.
    private func apply(_ result: DiffResult, restoring anchor: (side: Side, line: Int)?) {
        let panes = [leftPane.diffView, rightPane.diffView]
        let selected = panes.map { $0.savedSelection() }
        presentation.setResult(result)
        pendingReveal = nil
        for (pane, saved) in zip(panes, selected) { pane.restore(saved) }
        showResult(restoring: anchor)
    }

    private func showResult(restoring anchor: (side: Side, line: Int)?) {
        refreshViews()
        if let anchor {
            let rows = presentation.result.rows
            let row = rows.firstIndex { row in
                Int(anchor.side == .left ? row.left : row.right) >= anchor.line
            } ?? 0
            scroll(toY: CGFloat(row) * presentation.lineHeight)
        } else {
            scroll(toY: 0)
        }
        updateSubtitle()
    }

    private func redraw(row: Int) {
        let lh = presentation.lineHeight
        for view in [leftPane.diffView, rightPane.diffView] {
            view.setNeedsDisplay(NSRect(x: 0, y: CGFloat(row) * lh, width: view.bounds.width, height: lh))
        }
    }

    private func visibleRows() -> Range<Int> {
        guard let metrics = scrollMetrics else { return 0..<0 }
        let lh = presentation.lineHeight
        return Int(metrics.offset / lh)..<Int(ceil((metrics.offset + metrics.visible) / lh))
    }

    private func refreshViews() {
        leftPane.refresh(document: presentation.left, comparedWith: presentation.right)
        rightPane.refresh(document: presentation.right, comparedWith: presentation.left)
        changeMap.needsDisplay = true
    }

    /// The first line visible at the top of the window, used to keep the reader's
    /// place when the comparison is recomputed.
    private func topLine() -> (side: Side, line: Int)? {
        guard let metrics = scrollMetrics, metrics.offset > 0 else { return nil }
        let rows = presentation.result.rows
        var row = Int(metrics.offset / presentation.lineHeight)
        while row < rows.count {
            if rows[row].left >= 0 { return (.left, Int(rows[row].left)) }
            if rows[row].right >= 0 { return (.right, Int(rows[row].right)) }
            row += 1
        }
        return nil
    }

    private func updateSubtitle() {
        guard let window else { return }
        noticeWanted = false
        noticeOverlay.show(nil)
        if isLoading || isComparing {
            window.subtitle = isLoading ? "Loading…" : "Comparing…"
            return
        }
        if compareCancelled {
            window.subtitle = "Comparison cancelled · ⌘R to compare again"
            return
        }
        if isEmpty {
            window.subtitle = "Drop two files, open them with ⌘O, or paste text with ⌘V"
            return
        }
        if hasEmptySide {
            window.subtitle = "Add something to compare on the \(presentation.left == nil ? "left" : "right")"
            return
        }
        guard let left = presentation.left, let right = presentation.right else { return }
        let result = presentation.result
        let hidden = left.hiddenDifferences(from: right)
        let bytesSame = left.isByteIdentical(to: right)
        // A saved comparison names the options it was saved with up front.
        let parts = ComparisonSummary.parts(result, left: left, right: right, options: options, locale: .current,
                                            currentHunk: presentation.currentHunk,
                                            listsIgnored: options != saved?.options)
        var savedParts: [String] = []
        if let saved {
            savedParts.append("Saved " + saved.saved.formatted(date: .abbreviated, time: .omitted))
            if !saved.note.isEmpty { savedParts.append(saved.note) }
            let titles = ComparisonSummary.optionTitles(saved.options)
            if !titles.isEmpty { savedParts.append(ComparisonSummary.listed(titles)) }
        }
        let edited = editedNotice
        window.subtitle = (savedParts + [edited].compactMap { $0 } + parts).joined(separator: " · ")
        if result.isIdentical || edited != nil {
            let notice = ([edited].compactMap { $0 } + (result.isIdentical ? parts : [])).joined(separator: " · ")
            noticeOverlay.show(notice, identical: edited == nil && hidden.isEmpty && bytesSame == true)
            noticeWanted = true
            updateNoticeVisibility()
        }
    }

    private var editedNotice: String? {
        switch editedSides.count {
        case 0: nil
        case 1: "The \(editedSides.first == .left ? "left" : "right") side was edited after it was saved"
        default: "Both sides were edited after they were saved"
        }
    }

    /// The note floats over the bottom of the panes. Rows under it can be scrolled out
    /// from under it, except the last few, so it hides once the end of the document
    /// reaches it.
    private func updateNoticeVisibility() {
        guard noticeWanted else { return }
        guard let metrics = scrollMetrics else {
            noticeOverlay.isHidden = false
            return
        }
        let covered = noticeOverlay.fittingSize.height + 24 + 8
        // The pane is at least as tall as the window, so measure the rows themselves.
        let contentBottom = CGFloat(presentation.result.rows.count) * presentation.lineHeight - metrics.offset
        let endsAbove = contentBottom <= metrics.visible - covered
        let moreBelow = contentBottom > metrics.visible + covered
        noticeOverlay.isHidden = !(endsAbove || moreBelow)
    }

    // MARK: Scrolling

    private var primaryPane: PaneView {
        presentation.left != nil || presentation.right == nil ? leftPane : rightPane
    }

    var scrollMetrics: ScrollMetrics? {
        let pane = primaryPane
        guard presentation.document(pane.side) != nil else { return nil }
        let clip = pane.scrollView.contentView
        return ScrollMetrics(offset: clip.bounds.minY, visible: clip.bounds.height,
                             total: pane.diffView.frame.height)
    }

    func scroll(toY y: CGFloat) {
        let pane = primaryPane
        let clip = pane.scrollView.contentView
        let maxY = max(0, pane.diffView.frame.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: min(max(0, y), maxY)))
        pane.scrollView.reflectScrolledClipView(clip)
    }

    func scrollVertically(by delta: CGFloat) {
        guard let metrics = scrollMetrics else { return }
        scroll(toY: metrics.offset + delta)
    }

    func scrollHorizontally(by delta: CGFloat) {
        scroll(toX: visibleX.lowerBound + delta)
    }

    /// The pane with the wider document leads horizontal scrolling: syncing clamps the
    /// other to its own width, so x past that is still reachable.
    private var widerPane: PaneView {
        leftPane.diffView.frame.width >= rightPane.diffView.frame.width ? leftPane : rightPane
    }

    private func scroll(toX x: CGFloat) {
        let pane = widerPane
        let clip = pane.scrollView.contentView
        let maxX = max(0, pane.diffView.frame.width - clip.bounds.width)
        clip.scroll(to: NSPoint(x: min(max(0, x), maxX), y: clip.bounds.minY))
        pane.scrollView.reflectScrolledClipView(clip)
    }

    /// The columns on screen in both panes. Their gutters can differ in width (line
    /// counts with more digits), so the narrower clip decides how far right is visible.
    private var visibleX: Range<CGFloat> {
        let minX = widerPane.scrollView.contentView.bounds.minX
        let width = min(leftPane.scrollView.contentView.bounds.width, rightPane.scrollView.contentView.bounds.width)
        return minX..<minX + width
    }

    /// Both panes' scroll positions: the wider pane can scroll on horizontally after
    /// the other has stopped at its edge, so one alone can miss a scroll.
    private var scrollOrigin: [NSPoint] {
        [leftPane, rightPane].map { $0.scrollView.contentView.bounds.origin }
    }

    func forwardScrollWheel(_ event: NSEvent) {
        primaryPane.scrollView.scrollWheel(with: event)
    }

    @objc private func clipViewBoundsChanged(_ note: Notification) {
        guard let source = note.object as? NSClipView else { return }
        if !isSyncingScroll {
            isSyncingScroll = true
            let target = source === leftPane.scrollView.contentView ? rightPane : leftPane
            let clip = target.scrollView.contentView
            var origin = clip.bounds.origin
            if presentation.document(target.side) != nil {
                origin.y = source.bounds.minY
            }
            let maxX = max(0, target.diffView.frame.width - clip.bounds.width)
            origin.x = min(source.bounds.minX, maxX)
            if origin != clip.bounds.origin {
                clip.setBoundsOrigin(origin)
                target.scrollView.reflectScrolledClipView(clip)
            }
            isSyncingScroll = false
        }
        leftPane.lineNumbers.needsDisplay = true
        rightPane.lineNumbers.needsDisplay = true
        changeMap.needsDisplay = true
        presentation.startInlineRequest()
        updateNoticeVisibility()
    }

    // MARK: Navigation

    @objc func goToNextChange(_ sender: Any?) { navigate(forward: true) }
    @objc func goToPreviousChange(_ sender: Any?) { navigate(forward: false) }

    private func navigate(forward: Bool) {
        let result = presentation.result
        guard !result.hunks.isEmpty, let metrics = scrollMetrics else {
            NSSound.beep()
            return
        }
        let lh = presentation.lineHeight
        let top = Int(ceil(metrics.offset / lh))
        let bottom = Int(floor((metrics.offset + metrics.visible) / lh))
        let target: Int
        if let current = presentation.currentHunk,
           top <= result.hunks[current].rows.lowerBound, result.hunks[current].rows.lowerBound < bottom {
            if stepHighlight(in: current, forward: forward) { return }
            target = forward ? current + 1 : current - 1
        } else {
            let next = result.firstHunk(atOrAfter: top)
            target = forward ? next : next - 1
        }
        guard result.hunks.indices.contains(target) else {
            NSSound.beep()
            return
        }
        show(hunk: target)
    }

    private func show(hunk index: Int) {
        guard let metrics = scrollMetrics else { return }
        presentation.currentHunk = index
        let lh = presentation.lineHeight
        let rows = presentation.result.hunks[index].rows
        let height = CGFloat(rows.count) * lh
        let start = CGFloat(rows.lowerBound) * lh
        let y = height > metrics.visible * 0.6 ? start - lh * 2 : start - metrics.visible / 3
        scroll(toY: y)
        revealHorizontally(hunk: index)
        leftPane.diffView.needsDisplay = true
        rightPane.diffView.needsDisplay = true
        updateSubtitle()
        announce(hunk: index)
    }

    #if DEBUG
    var lastAnnouncement: String?
    var debugPanes: [DiffPaneView] { [leftPane.diffView, rightPane.diffView] }
    #endif

    /// Navigating only scrolls, which VoiceOver doesn't report, so say where we landed:
    /// "Change 3 of 12, 2 lines modified, at line 30".
    private func announce(hunk index: Int) {
        let result = presentation.result
        let rows = result.hunks[index].rows
        var counts: [RowKind: Int] = [:]
        for r in rows { counts[result.rows[r].kind, default: 0] += 1 }
        let parts = [(RowKind.changed, "modified"), (.deleted, "removed"), (.inserted, "added")]
            .compactMap { kind, word in counts[kind].map { "\($0) \($0 == 1 ? "line" : "lines") \(word)" } }
        let first = result.rows[rows.lowerBound]
        let place = first.right >= 0 ? "at line \(first.right + 1)" : "at line \(first.left + 1) on the left"
        let text = (["Change \(index + 1) of \(result.hunks.count)"] + parts + [place]).joined(separator: ", ")
        #if DEBUG
        lastAnnouncement = text
        #endif
        NSAccessibility.post(element: window as Any, notification: .announcementRequested, userInfo: [
            .announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }

    /// Where the inline highlights of a changed row start on each side, in pane
    /// coordinates and ascending; empty when it has none, nil while still being diffed.
    private func highlightStarts(row: Int) -> [[CGFloat]]? {
        let p = presentation
        let r = p.result.rows[row]
        guard r.kind == .changed, let left = p.left, let right = p.right else { return [] }
        guard let inline = p.inlineChanges(row: row) else { return p.isInlinePending(row: row) ? nil : [] }
        return [(inline.left, left.lines[Int(r.left)]), (inline.right, right.lines[Int(r.right)])]
            .map { ranges, line in
                HorizontalReveal.columns(ofOffsets: ranges.map(\.location), in: line)
                    .map { p.textInset + CGFloat($0) * p.charWidth }
            }
    }

    /// After navigating to a hunk, scrolls horizontally only when its change would
    /// otherwise be off screen: to the first highlight of each side (together) on a
    /// changed row; else back to the left edge when none of the hunk's text on screen
    /// reaches the visible columns (inserted, deleted or unhighlighted rows).
    private func revealHorizontally(hunk index: Int) {
        pendingReveal = nil
        let p = presentation
        let rows = p.result.hunks[index].rows
        let starts = highlightStarts(row: rows.lowerBound)
        let firsts = starts?.compactMap(\.first) ?? []
        if let lower = firsts.min(), let upper = firsts.max() {
            if let x = HorizontalReveal.scrollX(toShow: lower..<upper + p.charWidth, visible: visibleX,
                                                charWidth: p.charWidth) {
                scroll(toX: x)
            }
            return
        }
        let visible = visibleX
        if visible.lowerBound > 0 {
            let reaches = rows.clamped(to: visibleRows()).contains { row in
                [Side.left, .right].contains { side in
                    let index = p.lineIndex(row: row, side: side)
                    guard index >= 0, let line = p.document(side)?.lines[index] else { return false }
                    let end = HorizontalReveal.columns(ofOffsets: [line.utf16.count], in: line)[0]
                    return p.textInset + CGFloat(end) * p.charWidth > visible.lowerBound
                }
            }
            if !reaches { scroll(toX: 0) }
        }
        if starts == nil { pendingReveal = (rows.lowerBound, scrollOrigin) }
    }

    private func inlineChangesArrived(row: Int) {
        guard let pending = pendingReveal, pending.row == row else { return }
        pendingReveal = nil
        guard let current = presentation.currentHunk,
              presentation.result.hunks[current].rows.lowerBound == row,
              scrollOrigin == pending.origin else { return }
        revealHorizontally(hunk: current)
    }

    /// Next/previous first steps through the current hunk's first row: to the nearest
    /// highlight off screen in that direction, so changes far apart on one long line
    /// can each be reached. Returns false when there is none, to move to another hunk.
    private func stepHighlight(in hunk: Int, forward: Bool) -> Bool {
        let p = presentation
        guard let starts = highlightStarts(row: p.result.hunks[hunk].rows.lowerBound)?.joined().sorted()
        else { return false }
        let visible = visibleX
        let target = forward
            ? starts.first { $0 + p.charWidth > visible.upperBound }
            : starts.last { $0 < visible.lowerBound }
        guard let target,
              let x = HorizontalReveal.scrollX(toShow: target..<target + p.charWidth, visible: visible,
                                               charWidth: p.charWidth) else { return false }
        scroll(toX: x)
        // Stepping must make progress, or next would never leave this hunk.
        return visibleX.lowerBound != visible.lowerBound
    }

    // MARK: Actions

    private var focusedSide: Side? {
        (window?.firstResponder as? DiffPaneView)?.side
    }

    private func chooseFile(for side: Side) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Choose the \(side == .left ? "left" : "right") file (or two files to compare)"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self else { return }
            self.handleDrop(panel.urls, on: side)
        }
    }

    @objc func chooseLeftFile(_ sender: Any?) { chooseFile(for: .left) }
    @objc func chooseRightFile(_ sender: Any?) { chooseFile(for: .right) }

    private var hasFiles: Bool { presentation.left?.url != nil || presentation.right?.url != nil }
    private var canReload: Bool { hasFiles || compareCancelled }

    /// Also retries a cancelled comparison, which for pasted text has nothing to reload.
    @objc func reloadDocuments(_ sender: Any?) {
        if presentation.left?.url == nil && presentation.right?.url == nil {
            if compareCancelled { recompute() }
            return
        }
        load(left: presentation.left?.url, right: presentation.right?.url)
    }

    /// Pasting fills the first free side (no document and none loading); once both
    /// are taken it replaces the focused side.
    @objc func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.text else { return NSSound.beep() }
        if let side = freeSides.first {
            setPastedText(text, on: side)
        } else if let side = focusedSide {
            setPastedText(text, on: side)
        } else {
            NSSound.beep()
        }
    }

    @objc func pasteAsLeft(_ sender: Any?) {
        guard let text = NSPasteboard.general.text else { return NSSound.beep() }
        setPastedText(text, on: .left)
    }

    @objc func pasteAsRight(_ sender: Any?) {
        guard let text = NSPasteboard.general.text else { return NSSound.beep() }
        setPastedText(text, on: .right)
    }

    /// Pending loads are dropped: they would land on the side they were opened for.
    @objc func swapSides(_ sender: Any?) {
        pendingLoads.removeAll()
        editedSides = Set(editedSides.map { $0 == .left ? .right : .left })
        openedSides = Set(openedSides.map { $0 == .left ? .right : .left })
        savedPaths = Dictionary(uniqueKeysWithValues: savedPaths.map { ($0 == .left ? .right : .left, $1) })
        presentation.swapDocuments()
        documentsChanged(restoring: topLine())
    }

    @objc func toggleIgnoreWhitespace(_ sender: Any?) {
        options.ignoreWhitespace.toggle()
        optionsChanged()
    }

    @objc func toggleIgnoreCase(_ sender: Any?) {
        options.ignoreCase.toggle()
        optionsChanged()
    }

    @objc func toggleIgnoreTimers(_ sender: Any?) {
        options.ignoreTimers.toggle()
        optionsChanged()
    }

    private func optionsChanged() {
        if remembersOptions { Preferences.options = options }
        recompute()
    }

    /// Keeps the top row in place, so the text grows or shrinks around what was being read.
    @objc private func textStyleDidChange(_ notification: Notification) {
        let style = Preferences.textStyle
        guard style != presentation.textStyle else { return }
        let topRow = scrollMetrics.map { Int($0.offset / presentation.lineHeight) } ?? 0
        let current = presentation.currentHunk
        presentation.setTextStyle(style)
        refreshViews()
        presentation.currentHunk = current
        scroll(toY: CGFloat(topRow) * presentation.lineHeight)
    }

    private func zoom(by points: CGFloat) {
        var style = Preferences.textStyle
        style.zoom = TextStyle.clamp(style.effectiveSize + points) - style.size
        Preferences.textStyle = style
    }

    @objc func increaseFontSize(_ sender: Any?) { zoom(by: 1) }
    @objc func decreaseFontSize(_ sender: Any?) { zoom(by: -1) }

    /// Back to the size chosen in Settings.
    @objc func resetFontSize(_ sender: Any?) {
        var style = Preferences.textStyle
        style.zoom = 0
        Preferences.textStyle = style
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(toggleIgnoreWhitespace(_:)):
            item.state = options.ignoreWhitespace ? .on : .off
        case #selector(toggleIgnoreCase(_:)):
            item.state = options.ignoreCase ? .on : .off
        case #selector(toggleIgnoreTimers(_:)):
            item.state = options.ignoreTimers ? .on : .off
        case #selector(saveComparison(_:)):
            return !hasEmptySide && !isLoading && !isComparing && !isSaving
        case #selector(exportHTML(_:)):
            // A cancelled comparison isn't aligned, so it would look like no changes.
            return !hasEmptySide && !isLoading && !isComparing && !compareCancelled
        case #selector(goToNextChange(_:)), #selector(goToPreviousChange(_:)):
            return !presentation.result.hunks.isEmpty
        case #selector(reloadDocuments(_:)):
            return canReload
        case #selector(swapSides(_:)):
            return !isEmpty
        case #selector(paste(_:)):
            return NSPasteboard.general.text != nil && (!freeSides.isEmpty || focusedSide != nil)
        case #selector(pasteAsLeft(_:)), #selector(pasteAsRight(_:)):
            return NSPasteboard.general.text != nil
        case #selector(increaseFontSize(_:)):
            return presentation.textStyle.effectiveSize < TextStyle.sizes.upperBound
        case #selector(decreaseFontSize(_:)):
            return presentation.textStyle.effectiveSize > TextStyle.sizes.lowerBound
        case #selector(resetFontSize(_:)):
            return presentation.textStyle.effectiveSize != TextStyle.clamp(presentation.textStyle.size)
        default:
            break
        }
        return true
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        guard item.itemIdentifier == .reload else { return true }
        item.toolTip = hasFiles ? "Reload Files from Disk (⌘R)" : "Compare Again (⌘R)"
        return canReload
    }

    // MARK: Window

    func windowWillClose(_ notification: Notification) {
        // Nothing still running may land in (or show its bar over) the closed window.
        cancellation?.cancel()
        generation += 1
        pendingLoads.removeAll()
        pendingProgress?.cancel()
        pendingProgress = nil
        NotificationCenter.default.removeObserver(self)
        onClose?(self)
    }
}

private enum SaveError: LocalizedError {
    case emptySide

    var errorDescription: String? {
        switch self {
        case .emptySide: return "Both sides need something to compare first."
        }
    }
}

/// The save panel's fields for the names and note. The file name follows them until it
/// is edited: the note when there is one, else "<left> vs <right>".
private final class SaveFields: NSObject, NSTextFieldDelegate {
    let view: NSView
    private let panel: NSSavePanel
    private let fields: [NSTextField]
    private var suggested = ""

    var leftName: String { fields[0].stringValue }
    var rightName: String { fields[1].stringValue }
    var note: String { fields[2].stringValue }

    init(panel: NSSavePanel, left: String, right: String, note: String) {
        self.panel = panel
        fields = [left, right, note].map { NSTextField(string: $0) }
        fields[2].placeholderString = "A ticket number or purpose"
        let grid = NSGridView(views: zip(["Left name:", "Right name:", "Note:"], fields).map { title, field in
            [NSTextField(labelWithString: title), field]
        })
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        for field in fields { field.widthAnchor.constraint(equalToConstant: 320).isActive = true }
        let container = NSView()
        grid.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            grid.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            grid.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
        ])
        view = container
        super.init()
        for field in fields { field.delegate = self }
        suggestName()
    }

    func controlTextDidChange(_ notification: Notification) {
        suggestName()
    }

    private func suggestName() {
        let name = Self.fileName(note: note, left: leftName, right: rightName, extension: "juxta")
        if panel.nameFieldStringValue.isEmpty || panel.nameFieldStringValue == suggested {
            panel.nameFieldStringValue = name
        }
        suggested = name
    }

    /// The note, else "<left> vs <right>", made fit for a file name.
    static func fileName(note: String, left: String, right: String, extension ext: String) -> String {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "\(left) vs \(right)" : trimmed
        // "/" and ":" can't be in a file name.
        var name = base.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        // A leading dot would hide the file.
        name = String(name.drop { $0 == "." || $0 == " " })
        if name.count > 80 {
            let cut = name.prefix(80)
            // At the last space, unless that leaves too little.
            name = String(cut.lastIndex(of: " ").map { cut[..<$0] }.flatMap { $0.count >= 40 ? $0 : nil } ?? cut)
                .trimmingCharacters(in: .whitespaces)
        }
        return (name.isEmpty ? "Comparison" : name) + "." + ext
    }
}

/// The export panel's choice of how much to include, remembered for next time.
private final class ExportFields: NSObject {
    let view: NSView
    private let changes = NSButton(radioButtonWithTitle: "Changes with", target: nil, action: nil)
    private let all = NSButton(radioButtonWithTitle: "All lines", target: nil, action: nil)
    private let context = NSTextField(string: "")
    private let paths = NSButton(checkboxWithTitle: "Include file paths", target: nil, action: nil)

    private static let allKey = "exportAllLines", contextKey = "exportContext", pathsKey = "exportIncludesPaths"

    var includesPaths: Bool { paths.state == .on }

    var extent: HTMLReport.Extent {
        all.state == .on ? .all : .context(max(0, min(context.integerValue, 999)))
    }

    override init() {
        let defaults = UserDefaults.standard
        let lines = defaults.object(forKey: Self.contextKey) == nil ? 3 : defaults.integer(forKey: Self.contextKey)
        context.integerValue = lines
        let formatter = NumberFormatter()
        formatter.minimum = 0
        formatter.maximum = 999
        formatter.allowsFloats = false
        context.formatter = formatter
        context.alignment = .right
        context.widthAnchor.constraint(equalToConstant: 44).isActive = true
        (defaults.bool(forKey: Self.allKey) ? all : changes).state = .on
        paths.state = defaults.bool(forKey: Self.pathsKey) ? .on : .off
        let row = NSStackView(views: [changes, context, NSTextField(labelWithString: "lines of context")])
        row.spacing = 6
        row.alignment = .firstBaseline
        let column = NSStackView(views: [row, all, paths])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        let container = NSView()
        column.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            column.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -20),
            column.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            column.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
        ])
        view = container
        super.init()
        // Radio buttons with the same action in one superview act as a group.
        for button in [changes, all] {
            button.target = self
            button.action = #selector(choose(_:))
        }
    }

    @objc private func choose(_ sender: NSButton) {
        changes.state = sender === changes ? .on : .off
        all.state = sender === all ? .on : .off
    }

    func remember() {
        UserDefaults.standard.set(all.state == .on, forKey: Self.allKey)
        UserDefaults.standard.set(context.integerValue, forKey: Self.contextKey)
        UserDefaults.standard.set(includesPaths, forKey: Self.pathsKey)
    }
}
