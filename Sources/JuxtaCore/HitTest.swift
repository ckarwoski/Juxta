import Foundation

/// Finds the place in a line under the mouse, for selecting text. The pane lays a row
/// out and asks CoreText where a point falls; these are the parts that don't need it.
public enum HitTest {
    public enum Rounding: Sendable {
        /// The boundary between characters nearest the point, where a click or drag
        /// puts an end of the selection.
        case nearestEdge
        /// The start of the character the point is over, whose word a double-click
        /// selects.
        case characterUnder
    }

    /// The offset at `x`, measured from where the text starts, in a line of `length`
    /// printable ASCII characters, each one `charWidth` wide. Clamped to the line, so a
    /// point left of the text is offset 0 and one past its end is the end.
    public static func offset(atX x: CGFloat, charWidth: CGFloat, length: Int, rounding: Rounding) -> Int {
        guard charWidth > 0 else { return 0 }
        let columns = x / charWidth
        let offset = rounding == .nearestEdge ? columns.rounded() : floor(columns)
        guard offset.isFinite else { return 0 }
        return Int(min(max(offset, 0), CGFloat(length)))
    }

    /// The line offset for `index` in `layout`'s display string. Inside a badge,
    /// `.nearestEdge` goes to the nearer side of the character it stands for, and
    /// `.characterUnder` to its start, since the badge is that character.
    public static func sourceOffset(_ index: Int, in layout: Invisibles.Layout, rounding: Rounding) -> Int {
        let offset = layout.sourceOffset(index)
        // Rounded up to the end of a badged character: step back onto it. Badged
        // characters are all one UTF-16 unit.
        if rounding == .characterUnder, offset > 0, layout.displayOffset(offset) > index { return offset - 1 }
        return offset
    }
}
