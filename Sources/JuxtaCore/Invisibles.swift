import Foundation

/// Finds characters on a line that render as nothing, or look like something they
/// aren't, so changed lines can show why they differ.
///
/// Characters that would otherwise draw nothing (controls, zero-width characters) are
/// shown as a badge naming them. The badge needs room, so the line is laid out from a
/// display string in which each such character is replaced by spaces as wide as its
/// label; the badge is then drawn over those spaces. `displayOffset(_:)` maps UTF-16
/// offsets in the line to offsets in that string.
public enum Invisibles {
    public enum Kind: Equatable, Sendable {
        case tab
        /// A plain space; only marked when trailing.
        case space
        /// A no-break or other unusual space, which looks like a plain space.
        case unusualSpace
        /// A character that draws nothing, shown as a badge with this label.
        case badge(String)
    }

    public struct Marker: Equatable, Sendable {
        public var kind: Kind
        /// UTF-16 range in the display string.
        public var range: Range<Int>
        /// Part of the whitespace at the end of the line.
        public var trailing: Bool
    }

    public struct Layout: Equatable, Sendable {
        /// The line with badge characters replaced by spaces as wide as their labels.
        public var display: String
        public var markers: [Marker]
        /// Start of the trailing whitespace in `display`, if any.
        public var trailingStart: Int?
        /// Line offset and growth for each badge, in line order.
        var shifts: [Shift] = []

        struct Shift: Equatable, Sendable {
            var offset: Int
            var growth: Int
        }

        /// Maps a UTF-16 offset in the line to one in `display`.
        public func displayOffset(_ offset: Int) -> Int {
            var result = offset
            for shift in shifts {
                guard shift.offset < offset else { break }
                result += shift.growth
            }
            return result
        }
    }

    private static let c0Names = [
        "NUL", "SOH", "STX", "ETX", "EOT", "ENQ", "ACK", "BEL", "BS", "HT", "LF", "VT", "FF", "CR", "SO", "SI",
        "DLE", "DC1", "DC2", "DC3", "DC4", "NAK", "SYN", "ETB", "CAN", "EM", "SUB", "ESC", "FS", "GS", "RS", "US",
    ]

    /// Whether a character draws nothing (other than a tab), and so gets a badge.
    public static func isBadged(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09: return false
        case 0x00..<0x20, 0x7F...0x9F,
             0xAD, // soft hyphen
             0x200B...0x200F, // zero-width space, joiners, direction marks
             0x2028, 0x2029, // line and paragraph separators
             0x202A...0x202E, 0x2066...0x2069, // bidi embeddings and isolates
             0x2060...0x2064, 0xFEFF: // word joiner, invisible operators, zero-width no-break space
            return true
        default: return false
        }
    }

    /// The badge label for a character that draws nothing, or nil for other characters.
    public static func badgeLabel(_ scalar: Unicode.Scalar) -> String? {
        guard isBadged(scalar) else { return nil }
        switch scalar.value {
        case 0x00..<0x20: return c0Names[Int(scalar.value)]
        case 0x7F: return "DEL"
        default: return String(format: "U+%04X", scalar.value)
        }
    }

    public static func isUnusualSpace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0xA0, 0x2000...0x200A, 0x202F, 0x3000: return true
        default: return false
        }
    }

    /// Extra columns a line needs for its badges; zero for most lines.
    public static func extraColumns(_ line: String) -> Int {
        line.unicodeScalars.reduce(0) { $0 + (badgeLabel($1)?.count ?? 0) }
    }

    /// The markers for a line, or nil when it has nothing worth marking. Trailing
    /// whitespace is only marked when `atLineEnd`, so a slice from the middle of a
    /// long line doesn't mark its last spaces.
    public static func layout(_ line: Substring, atLineEnd: Bool = true) -> Layout? {
        let scalars = line.unicodeScalars
        var markers: [Marker] = []
        var shifts: [Layout.Shift] = []
        var display = String.UnicodeScalarView()
        var copiedUpTo = scalars.startIndex
        var offset = 0, displayOffset = 0
        for index in scalars.indices {
            let scalar = scalars[index]
            let width = scalar.utf16.count
            if scalar == "\t" {
                markers.append(Marker(kind: .tab, range: displayOffset..<displayOffset + 1, trailing: false))
            } else if isUnusualSpace(scalar) {
                markers.append(Marker(kind: .unusualSpace, range: displayOffset..<displayOffset + width, trailing: false))
            } else if let label = badgeLabel(scalar) {
                display.append(contentsOf: scalars[copiedUpTo..<index])
                display.append(contentsOf: String(repeating: " ", count: label.count).unicodeScalars)
                copiedUpTo = scalars.index(after: index)
                markers.append(Marker(kind: .badge(label), range: displayOffset..<displayOffset + label.count, trailing: false))
                shifts.append(Layout.Shift(offset: offset, growth: label.count - width))
                displayOffset += label.count - width
            }
            offset += width
            displayOffset += width
        }

        // Badges end the trailing run, so it is the same in the line and the display.
        var trailingStart: Int?
        if atLineEnd {
            var start = displayOffset
            for scalar in scalars.reversed() {
                guard scalar == " " || scalar == "\t" || isUnusualSpace(scalar) else { break }
                start -= scalar.utf16.count
                if scalar == " " { markers.append(Marker(kind: .space, range: start..<start + 1, trailing: true)) }
            }
            if start < displayOffset {
                trailingStart = start
                for i in markers.indices where markers[i].range.lowerBound >= start { markers[i].trailing = true }
                markers.sort { $0.range.lowerBound < $1.range.lowerBound }
            }
        }
        guard !markers.isEmpty else { return nil }
        let text: String
        if shifts.isEmpty {
            text = String(line)
        } else {
            display.append(contentsOf: scalars[copiedUpTo...])
            text = String(display)
        }
        var layout = Layout(display: text, markers: markers, trailingStart: trailingStart)
        layout.shifts = shifts
        return layout
    }

    public static func layout(_ line: String) -> Layout? {
        layout(line[...])
    }
}
