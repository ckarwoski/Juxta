import AppKit

/// How the panes draw text: the font chosen in Settings, plus the View menu's zoom.
struct TextStyle: Equatable {
    enum LineSpacing: Int, CaseIterable {
        case compact, normal, relaxed

        var title: String {
            switch self {
            case .compact: return "Compact"
            case .normal: return "Normal"
            case .relaxed: return "Relaxed"
            }
        }

        /// Space added to each row, as a fraction of the font size (3 pt at 12 pt for normal).
        var extra: CGFloat {
            switch self {
            case .compact: return 0.1
            case .normal: return 0.25
            case .relaxed: return 0.5
            }
        }
    }

    static let sizes: ClosedRange<CGFloat> = 8...36
    static let defaultSize: CGFloat = 12

    /// PostScript name of a monospaced face; nil is the system monospaced font (SF Mono).
    var fontName: String?
    /// The system font's weight, used when `fontName` is nil.
    var systemWeight: NSFont.Weight = .regular
    /// The size chosen in Settings.
    var size: CGFloat = TextStyle.defaultSize
    /// Points added by View → Bigger / Smaller; Actual Size sets it back to 0.
    var zoom: CGFloat = 0
    var lineSpacing: LineSpacing = .normal
    /// Off by default: a diff should show exactly which characters are in the file.
    var ligatures = false

    static func clamp(_ size: CGFloat) -> CGFloat {
        min(max(size, sizes.lowerBound), sizes.upperBound)
    }

    var effectiveSize: CGFloat { Self.clamp(size + zoom) }

    /// Whether the chosen face is installed; if not, text falls back to SF Mono.
    var isFontAvailable: Bool { fontName.map { NSFont(name: $0, size: 12) != nil } ?? true }

    func font(ofSize size: CGFloat) -> NSFont {
        var font = fontName.flatMap { NSFont(name: $0, size: size) }
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: fontName == nil ? systemWeight : .regular)
        if !ligatures {
            // Coding fonts draw their ligatures (->, !=) as contextual alternates, which the
            // ligature attribute alone leaves on.
            let off: [[NSFontDescriptor.FeatureKey: Int]] = [
                [.typeIdentifier: kLigaturesType, .selectorIdentifier: kCommonLigaturesOffSelector],
                [.typeIdentifier: kContextualAlternatesType, .selectorIdentifier: kContextualAlternatesOffSelector],
            ]
            let descriptor = font.fontDescriptor.addingAttributes([.featureSettings: off])
            font = NSFont(descriptor: descriptor, size: size) ?? font
        }
        return font
    }
}

/// The installed fonts whose letters, digits and spaces all have the same width, which
/// the panes need to keep columns lined up. Font traits alone miss some (Nerd Fonts) and
/// include whole families of which only one face is monospaced (Osaka).
enum MonospacedFonts {
    struct Face {
        let postScriptName: String
        let name: String
    }

    struct Family {
        let name: String
        let faces: [Face]
    }

    /// The system monospaced font's weights, as Settings offers them.
    static let systemWeights: [(name: String, weight: NSFont.Weight)] = [
        ("Light", .light), ("Regular", .regular), ("Medium", .medium),
        ("Semibold", .semibold), ("Bold", .bold), ("Heavy", .heavy),
    ]

    static let systemFamilyName = "SF Mono"

    /// Built on first use (a fraction of a second with many fonts installed).
    static let families: [Family] = {
        let manager = NSFontManager.shared
        var result: [Family] = []
        for family in manager.availableFontFamilies where !family.hasPrefix(".") && family != systemFamilyName {
            let faces = (manager.availableMembers(ofFontFamily: family) ?? []).compactMap { member -> Face? in
                guard member.count >= 2, let name = member[0] as? String, let face = member[1] as? String,
                      let font = NSFont(name: name, size: 12), isMonospaced(font) else { return nil }
                return Face(postScriptName: name, name: face)
            }
            if !faces.isEmpty { result.append(Family(name: family, faces: faces)) }
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }()

    private static func isMonospaced(_ font: NSFont) -> Bool {
        var characters = Array("iW0 .m".utf16)
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        guard CTFontGetGlyphsForCharacters(font, &characters, &glyphs, characters.count) else { return false }
        var advances = [CGSize](repeating: .zero, count: glyphs.count)
        CTFontGetAdvancesForGlyphs(font, .horizontal, glyphs, &advances, glyphs.count)
        return advances.allSatisfy { abs($0.width - advances[0].width) < 0.01 } && advances[0].width > 0
    }

    static func family(containing postScriptName: String) -> Family? {
        families.first { $0.faces.contains { $0.postScriptName == postScriptName } }
    }
}

extension Notification.Name {
    static let textStyleDidChange = Notification.Name("JuxtaTextStyleDidChange")
}
