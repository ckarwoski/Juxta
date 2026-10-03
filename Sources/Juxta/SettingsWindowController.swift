import AppKit
import JuxtaCore

/// Juxta → Settings… (⌘,). One pane, so no toolbar: the window is titled "Juxta Settings"
/// and can't be minimized or zoomed, as the HIG asks. Changes apply as they are made.
final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSMenuDelegate {
    static let shared = SettingsWindowController()

    private let familyPopUp = NSPopUpButton()
    private let facePopUp = NSPopUpButton()
    private let sizeField = NSTextField()
    private let sizeStepper = NSStepper()
    private let spacingPopUp = NSPopUpButton()
    private let ligaturesCheckbox = NSButton(checkboxWithTitle: "Use ligatures", target: nil, action: nil)
    private let preview = TextPreviewView()

    private init() {
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable],
                              backing: .buffered, defer: true)
        window.title = "Juxta Settings"
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildContent(in: window)
        window.center()
        window.setFrameAutosaveName("Settings")
        NotificationCenter.default.addObserver(
            self, selector: #selector(textStyleDidChange(_:)), name: .textStyleDidChange, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func showWindow(_ sender: Any?) {
        update()
        super.showWindow(sender)
    }

    // MARK: Layout

    private func buildContent(in window: NSWindow) {
        familyPopUp.target = self
        familyPopUp.action = #selector(familyChosen(_:))
        familyPopUp.setAccessibilityLabel("Font")
        facePopUp.target = self
        facePopUp.action = #selector(faceChosen(_:))
        facePopUp.setAccessibilityLabel("Typeface")

        let formatter = NumberFormatter()
        formatter.minimum = TextStyle.sizes.lowerBound as NSNumber
        formatter.maximum = TextStyle.sizes.upperBound as NSNumber
        formatter.maximumFractionDigits = 1
        sizeField.formatter = formatter
        sizeField.alignment = .right
        sizeField.bezelStyle = .roundedBezel
        sizeField.target = self
        sizeField.action = #selector(sizeEntered(_:))
        sizeField.setAccessibilityLabel("Font size, in points")
        sizeStepper.minValue = Double(TextStyle.sizes.lowerBound)
        sizeStepper.maxValue = Double(TextStyle.sizes.upperBound)
        sizeStepper.increment = 1
        sizeStepper.valueWraps = false
        sizeStepper.target = self
        sizeStepper.action = #selector(sizeStepped(_:))
        sizeStepper.setAccessibilityLabel("Font size")
        let points = NSTextField(labelWithString: "pt")
        points.textColor = .secondaryLabelColor
        let sizeRow = NSStackView(views: [sizeField, sizeStepper, points])
        sizeRow.spacing = 4
        sizeField.widthAnchor.constraint(equalToConstant: 48).isActive = true
        // A rounded field draws its bezel 2 pt inside its frame, a pop-up 1.5 pt inside a
        // 25 pt frame, so at its natural 22 pt the field looks 1.5 pt shorter than the
        // pop-ups beside it.
        sizeField.heightAnchor.constraint(equalToConstant: 23.5).isActive = true

        for spacing in TextStyle.LineSpacing.allCases {
            spacingPopUp.addItem(withTitle: spacing.title)
            spacingPopUp.lastItem?.tag = spacing.rawValue
        }
        spacingPopUp.target = self
        spacingPopUp.action = #selector(spacingChosen(_:))
        spacingPopUp.setAccessibilityLabel("Line spacing")

        ligaturesCheckbox.target = self
        ligaturesCheckbox.action = #selector(ligaturesToggled(_:))
        let ligaturesNote = NSTextField(wrappingLabelWithString:
            "Shows pairs like -> and != as single symbols, in fonts that have them.")
        ligaturesNote.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        ligaturesNote.textColor = .secondaryLabelColor
        ligaturesNote.preferredMaxLayoutWidth = 300
        let ligatures = NSStackView(views: [ligaturesCheckbox, ligaturesNote])
        ligatures.orientation = .vertical
        ligatures.alignment = .leading
        ligatures.spacing = 2

        let fontRow = NSStackView(views: [familyPopUp, facePopUp])
        fontRow.spacing = 8
        familyPopUp.widthAnchor.constraint(equalToConstant: 200).isActive = true
        facePopUp.widthAnchor.constraint(greaterThanOrEqualToConstant: 110).isActive = true

        func label(_ text: String) -> NSTextField {
            let label = NSTextField(labelWithString: text)
            label.alignment = .right
            return label
        }
        let grid = NSGridView(views: [
            [label("Font:"), fontRow],
            [label("Size:"), sizeRow],
            [label("Line spacing:"), spacingPopUp],
            [NSGridCell.emptyContentView, ligatures],
            [label("Preview:"), preview],
        ])
        grid.rowSpacing = 10
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.row(at: 3).topPadding = -2
        grid.row(at: 4).topPadding = 8
        grid.row(at: 4).rowAlignment = .none
        grid.cell(for: preview)?.yPlacement = .top

        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.widthAnchor.constraint(equalToConstant: 340).isActive = true
        preview.heightAnchor.constraint(equalToConstant: 128).isActive = true

        let content = NSView()
        grid.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            grid.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
        ])
        window.contentView = content
        window.setContentSize(content.fittingSize)
        // Nothing focused on opening, so the size field doesn't open with its text selected.
        window.initialFirstResponder = familyPopUp
    }

    // MARK: Showing the current style

    @objc private func textStyleDidChange(_ notification: Notification) {
        update()
    }

    private func update() {
        let style = Preferences.textStyle
        rebuildFamilies(selecting: style)
        rebuildFaces(style)
        sizeField.doubleValue = Double(style.size)
        sizeStepper.doubleValue = Double(style.size)
        spacingPopUp.selectItem(withTag: style.lineSpacing.rawValue)
        ligaturesCheckbox.state = style.ligatures ? .on : .off
        // The size set here, without the View menu's zoom.
        var unzoomed = style
        unzoomed.zoom = 0
        preview.style = unzoomed
    }

    /// Fonts for the family menu's items, which name each family in that family (as the
    /// Fonts panel does) while the menu is open. The button keeps the system font.
    private var familyFonts: [String?: NSFont] = [:]

    private func rebuildFamilies(selecting style: TextStyle) {
        let menu = NSMenu()
        menu.delegate = self
        func add(_ title: String, family: String?) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.representedObject = family
            menu.addItem(item)
        }
        let menuSize = NSFont.systemFontSize
        familyFonts = [nil: .monospacedSystemFont(ofSize: menuSize, weight: .regular)]
        add(MonospacedFonts.systemFamilyName, family: nil)
        menu.addItem(.separator())
        for family in MonospacedFonts.families {
            familyFonts[family.name] = NSFont(name: family.faces[0].postScriptName, size: menuSize)
            add(family.name, family: family.name)
        }
        // A font that was uninstalled stays listed, so the window doesn't claim SF Mono
        // is in use when that's only the fallback.
        var selected: String? = nil
        if let name = style.fontName {
            if let family = MonospacedFonts.family(containing: name) {
                selected = family.name
            } else {
                menu.addItem(.separator())
                add("\(name) (missing)", family: name)
                menu.items.last?.isEnabled = false
                selected = name
            }
        }
        familyPopUp.autoenablesItems = false
        familyPopUp.menu = menu
        if let index = menu.items.firstIndex(where: { !$0.isSeparatorItem && ($0.representedObject as? String) == selected }) {
            familyPopUp.selectItem(at: index)
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        for item in menu.items where !item.isSeparatorItem {
            if let font = familyFonts[item.representedObject as? String] {
                item.attributedTitle = NSAttributedString(string: item.title, attributes: [.font: font])
            }
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        for item in menu.items { item.attributedTitle = nil }
    }

    private func rebuildFaces(_ style: TextStyle) {
        facePopUp.removeAllItems()
        if let name = style.fontName {
            guard let family = MonospacedFonts.family(containing: name) else {
                facePopUp.isEnabled = false
                return
            }
            for face in family.faces {
                facePopUp.addItem(withTitle: face.name)
                facePopUp.lastItem?.representedObject = face.postScriptName
                if face.postScriptName == name { facePopUp.select(facePopUp.lastItem) }
            }
        } else {
            for (title, weight) in MonospacedFonts.systemWeights {
                facePopUp.addItem(withTitle: title)
                facePopUp.lastItem?.representedObject = weight.rawValue
                if weight == style.systemWeight { facePopUp.select(facePopUp.lastItem) }
            }
        }
        facePopUp.isEnabled = facePopUp.numberOfItems > 1
    }

    // MARK: Changing it

    private func change(_ body: (inout TextStyle) -> Void) {
        var style = Preferences.textStyle
        body(&style)
        Preferences.textStyle = style
    }

    /// Keeps the weight and slant when the new family has the same face, else its regular one.
    @objc private func familyChosen(_ sender: NSPopUpButton) {
        let currentFace = facePopUp.titleOfSelectedItem ?? "Regular"
        change { style in
            guard let name = sender.selectedItem?.representedObject as? String,
                  let family = MonospacedFonts.families.first(where: { $0.name == name }) else {
                style.fontName = nil
                if !MonospacedFonts.systemWeights.contains(where: { $0.name == currentFace }) {
                    style.systemWeight = .regular
                }
                return
            }
            let regular = ["Regular", "Roman", "Book", "Medium"]
            let face = family.faces.first { $0.name == currentFace }
                ?? regular.lazy.compactMap { r in family.faces.first { $0.name == r } }.first
                ?? family.faces[0]
            style.fontName = face.postScriptName
        }
    }

    @objc private func faceChosen(_ sender: NSPopUpButton) {
        change { style in
            if let name = sender.selectedItem?.representedObject as? String {
                style.fontName = name
            } else if let weight = sender.selectedItem?.representedObject as? CGFloat {
                style.systemWeight = NSFont.Weight(weight)
            }
        }
    }

    /// A size set here replaces any View menu zoom, so windows show exactly this size.
    private func setSize(_ size: CGFloat) {
        change { style in
            style.size = TextStyle.clamp(size)
            style.zoom = 0
        }
        update()
    }

    @objc private func sizeEntered(_ sender: NSTextField) { setSize(CGFloat(sender.doubleValue)) }
    @objc private func sizeStepped(_ sender: NSStepper) { setSize(CGFloat(sender.doubleValue)) }

    @objc private func spacingChosen(_ sender: NSPopUpButton) {
        change { $0.lineSpacing = TextStyle.LineSpacing(rawValue: sender.selectedTag()) ?? .normal }
    }

    @objc private func ligaturesToggled(_ sender: NSButton) {
        change { $0.ligatures = sender.state == .on }
    }
}

/// A few rows drawn the way the panes draw them, so the font can be judged before any
/// files are open.
private final class TextPreviewView: NSView {
    private static let rows: [(String, RowKind)] = [
        ("interface GigabitEthernet0/1", .same),
        (" description uplink -> core-sw-02", .same),
        (" ip address 10.0.0.1 255.255.255.0", .deleted),
        (" ip address 10.0.0.10 255.255.255.0", .inserted),
        (" mtu 9216", .changed),
        ("!", .same),
    ]

    var style = TextStyle() {
        didSet {
            presentation.setTextStyle(style)
            needsDisplay = true
        }
    }

    private let presentation = DiffPresentation(options: DiffOptions(), textStyle: TextStyle())

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Preview of the font")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let frame = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        NSColor.textBackgroundColor.setFill()
        frame.fill()
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        defer {
            ctx.restoreGState()
            NSColor.separatorColor.setStroke()
            frame.stroke()
        }
        frame.addClip()
        let p = presentation
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.setFillColor(NSColor.textColor.cgColor)
        var y: CGFloat = 6
        // Only whole rows: at large sizes the last ones are left out rather than cut off.
        for (text, kind) in Self.rows where y + p.lineHeight <= bounds.maxY - 4 {
            if let background = Theme.background(for: kind) {
                background.setFill()
                NSRect(x: 0, y: y, width: bounds.width, height: p.lineHeight).fill()
            }
            if kind == .changed, let range = text.range(of: "9216") {
                let start = CGFloat(text.distance(from: text.startIndex, to: range.lowerBound))
                Theme.drawChangedHighlight(in: NSRect(x: p.textInset + start * p.charWidth, y: y + 1,
                                                      width: 4 * p.charWidth, height: p.lineHeight - 2))
            }
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: p.textAttributes))
            ctx.setFillColor(NSColor.textColor.cgColor)
            ctx.textPosition = CGPoint(x: p.textInset, y: y + p.baseline)
            CTLineDraw(line, ctx)
            y += p.lineHeight
        }
    }
}
