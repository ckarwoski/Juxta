import Foundation

/// Where to scroll horizontally so a change inside a long line can be seen: panes
/// don't wrap, so a change far along a line is otherwise off screen.
public enum HorizontalReveal {
    /// The columns UTF-16 `offsets` (ascending) are drawn at on a changed row: tabs
    /// advance to the next multiple of four and badged characters take their label's
    /// width, as when drawn. Other characters count one column per UTF-16 unit, which
    /// is exact for the ASCII long lines this matters most for.
    public static func columns(ofOffsets offsets: [Int], in line: String) -> [Int] {
        var result: [Int] = []
        result.reserveCapacity(offsets.count)
        var pending = offsets[...]
        var offset = 0, column = 0
        for scalar in line.unicodeScalars {
            while let next = pending.first, next <= offset {
                result.append(column)
                pending.removeFirst()
            }
            if pending.isEmpty { return result }
            if scalar == "\t" {
                column = (column / 4 + 1) * 4
            } else {
                column += Invisibles.badgeLabel(scalar)?.count ?? scalar.utf16.count
            }
            offset += scalar.utf16.count
        }
        return result + pending.map { _ in column }
    }

    /// The scroll x that shows `span` with some context to its left, or nil when it is
    /// already in view, so a change on screen never moves.
    public static func scrollX(toShow span: Range<CGFloat>, visible: Range<CGFloat>,
                               charWidth: CGFloat) -> CGFloat? {
        if visible.lowerBound <= span.lowerBound && span.upperBound <= visible.upperBound { return nil }
        return max(0, span.lowerBound - margin(visibleWidth: visible.upperBound - visible.lowerBound,
                                               charWidth: charWidth))
    }

    /// Room left of a revealed change, enough to read the token before it.
    static func margin(visibleWidth: CGFloat, charWidth: CGFloat) -> CGFloat {
        min(visibleWidth / 3, charWidth * 16)
    }
}
