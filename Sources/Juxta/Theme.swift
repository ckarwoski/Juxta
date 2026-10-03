import AppKit
import JuxtaCore

enum Theme {
    private static let appearances: [NSAppearance.Name] = [
        .aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua,
    ]

    /// Increase Contrast switches the effective appearance to a high-contrast one; colors
    /// without their own high-contrast value keep the regular one.
    private static func dynamic(light: NSColor, dark: NSColor,
                                highContrastLight: NSColor? = nil, highContrastDark: NSColor? = nil) -> NSColor {
        NSColor(name: nil) { appearance in
            switch match(appearance) {
            case .darkAqua: dark
            case .accessibilityHighContrastAqua: highContrastLight ?? light
            case .accessibilityHighContrastDarkAqua: highContrastDark ?? dark
            default: light
            }
        }
    }

    /// Whether the view being drawn has Increase Contrast on.
    static var isHighContrast: Bool {
        let match = match(.currentDrawing())
        return match == .accessibilityHighContrastAqua || match == .accessibilityHighContrastDarkAqua
    }

    #if DEBUG
    /// For snapshots: AppKit makes the high-contrast appearances only for the real
    /// setting (`NSAppearance(named:)` turns their names into the plain ones).
    nonisolated(unsafe) static var forcesHighContrast = false
    #endif

    private static func match(_ appearance: NSAppearance) -> NSAppearance.Name? {
        let match = appearance.bestMatch(from: appearances)
        #if DEBUG
        if forcesHighContrast {
            if match == .aqua { return .accessibilityHighContrastAqua }
            if match == .darkAqua { return .accessibilityHighContrastDarkAqua }
        }
        #endif
        return match
    }

    private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
        NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: 1)
    }

    // High-contrast values: rows stand further apart from unchanged ones, and all text,
    // line numbers included, stays at 7:1 or more on every row background.
    static let deletedBackground = dynamic(
        light: rgb(255, 233, 233), dark: rgb(84, 33, 37),
        highContrastLight: rgb(255, 204, 206), highContrastDark: rgb(110, 30, 38))
    static let insertedBackground = dynamic(
        light: rgb(228, 247, 229), dark: rgb(27, 70, 38),
        highContrastLight: rgb(196, 238, 200), highContrastDark: rgb(22, 88, 40))
    static let changedBackground = dynamic(
        light: rgb(230, 239, 255), dark: rgb(29, 50, 88),
        highContrastLight: rgb(204, 222, 255), highContrastDark: rgb(28, 56, 112))
    static let changedHighlight = dynamic(
        light: rgb(178, 205, 255), dark: rgb(50, 92, 170),
        highContrastLight: rgb(128, 170, 250), highContrastDark: rgb(40, 82, 164))
    /// Outlines highlights under Increase Contrast, where the fill alone is too close to
    /// the modified row (1.5–1.7:1); the outline is 6:1 against the row.
    static let changedHighlightBorder = dynamic(light: rgb(0, 64, 190), dark: rgb(150, 195, 255))
    /// Marks for invisible characters on changed rows: present but faint.
    static let invisible = NSColor.tertiaryLabelColor
    static let badgeFill = dynamic(
        light: NSColor(white: 0, alpha: 0.07), dark: NSColor(white: 1, alpha: 0.1),
        highContrastLight: NSColor(white: 0, alpha: 0.14), highContrastDark: NSColor(white: 1, alpha: 0.2))
    static let trailingWhitespace = dynamic(
        light: NSColor(srgbRed: 1, green: 0.62, blue: 0.1, alpha: 0.22),
        dark: NSColor(srgbRed: 1, green: 0.62, blue: 0.1, alpha: 0.28),
        highContrastLight: NSColor(srgbRed: 1, green: 0.55, blue: 0, alpha: 0.4),
        highContrastDark: NSColor(srgbRed: 1, green: 0.62, blue: 0.1, alpha: 0.45))
    /// Line numbers: tertiary label gray was under 2.3:1 on every row; these clear 4.5:1
    /// on all row backgrounds (selected rows use the label color instead).
    static let lineNumber = dynamic(
        light: rgb(105, 105, 110), dark: rgb(170, 170, 176),
        highContrastLight: rgb(64, 64, 68), highContrastDark: rgb(232, 232, 236))
    /// Format parts that differ between the files. System orange is 2.3:1 on the light
    /// header, so light mode uses a darker orange (5:1); dark keeps system orange (7.5:1).
    static let formatDiffers = dynamic(light: rgb(168, 78, 0), dark: .systemOrange,
                                       highContrastLight: rgb(140, 62, 0))
    static let filler = dynamic(
        light: rgb(246, 246, 247), dark: rgb(36, 36, 38),
        highContrastLight: rgb(238, 238, 240), highContrastDark: rgb(40, 40, 43))
    static let fillerHatch = dynamic(
        light: rgb(226, 226, 229), dark: rgb(54, 54, 58),
        highContrastLight: rgb(176, 176, 182), highContrastDark: rgb(84, 84, 90))

    static func background(for kind: RowKind) -> NSColor? {
        switch kind {
        case .same: return nil
        case .changed: return changedBackground
        case .deleted: return deletedBackground
        case .inserted: return insertedBackground
        }
    }

    static func marker(for kind: RowKind) -> NSColor {
        switch kind {
        case .same: return .clear
        case .changed: return .systemBlue
        case .deleted: return .systemRed
        case .inserted: return .systemGreen
        }
    }

    /// Draws the gutter's sign for a row — what happened to this side's line, as in a
    /// unified diff, so the kind doesn't rest on color alone. Drawn as strokes rather than
    /// glyphs: at gutter sizes a font's ~ is barely taller than its −. `rect` is a square.
    static func drawSign(for kind: RowKind, in rect: NSRect, color: NSColor) {
        let path = NSBezierPath()
        let w = rect.width, cx = rect.midX, cy = rect.midY
        switch kind {
        case .same:
            return
        case .inserted:
            path.move(to: NSPoint(x: rect.minX, y: cy))
            path.line(to: NSPoint(x: rect.maxX, y: cy))
            path.move(to: NSPoint(x: cx, y: rect.minY))
            path.line(to: NSPoint(x: cx, y: rect.maxY))
        case .deleted:
            path.move(to: NSPoint(x: rect.minX, y: cy))
            path.line(to: NSPoint(x: rect.maxX, y: cy))
        case .changed:
            // One full sine period, tall enough to read as a wave, not a dash.
            let amplitude = w * 0.28
            path.move(to: NSPoint(x: rect.minX, y: cy))
            for step in 1...24 {
                let t = CGFloat(step) / 24
                path.line(to: NSPoint(x: rect.minX + w * t, y: cy - amplitude * sin(2 * .pi * t)))
            }
        }
        path.lineWidth = max(1.5, w * 0.16)
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        color.setStroke()
        path.stroke()
    }

    /// Fills a changed-characters highlight, outlined under Increase Contrast.
    static func drawChangedHighlight(in rect: NSRect) {
        changedHighlight.setFill()
        rect.fill()
        guard isHighContrast else { return }
        changedHighlightBorder.setStroke()
        let outline = NSBezierPath(rect: rect.insetBy(dx: 0.75, dy: 0.75))
        outline.lineWidth = 1.5
        outline.stroke()
    }

    /// Diagonal hatching aligned to view coordinates so it stays continuous across rows.
    static func drawFiller(in rect: NSRect) {
        filler.setFill()
        rect.fill()
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.clip(to: rect)
        ctx.setStrokeColor(fillerHatch.cgColor)
        ctx.setLineWidth(1)
        let spacing: CGFloat = 7
        var c = floor((rect.minX + rect.minY) / spacing) * spacing
        while c <= rect.maxX + rect.maxY {
            ctx.move(to: CGPoint(x: c - rect.maxY, y: rect.maxY))
            ctx.addLine(to: CGPoint(x: c - rect.minY, y: rect.minY))
            c += spacing
        }
        ctx.strokePath()
        ctx.restoreGState()
    }
}
