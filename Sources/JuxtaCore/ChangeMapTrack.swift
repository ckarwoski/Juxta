import Foundation

/// Geometry of the change map's track: the view's `height` less an inset at each end,
/// with markers placed by row and a knob showing the viewport. Points, y down.
public struct ChangeMapTrack {
    public var height: CGFloat
    public var top: CGFloat
    public var bottom: CGFloat

    public init(height: CGFloat, top: CGFloat, bottom: CGFloat) {
        self.height = height
        self.top = top
        self.bottom = bottom
    }

    public var length: CGFloat { max(1, height - top - bottom) }

    /// The bottom inset that keeps a marker whose right edge is `edge` in from the view's
    /// right clear of a rounded window corner of `radius` (1 pt to spare), rounded up to
    /// whole `pixel`s; at least `minimum`.
    public static func bottomInset(cornerRadius radius: CGFloat, edge: CGFloat = 3,
                                   pixel: CGFloat = 1, minimum: CGFloat = 4) -> CGFloat {
        guard radius > edge else { return minimum }
        let d = radius - edge
        let clearance = radius - (radius * radius - d * d).squareRoot() + 1
        return max(minimum, (clearance / pixel).rounded(.up) * pixel)
    }

    /// A marker for `rows` of `rowCount`, at least 2 pt tall and kept inside the track.
    public func marker(rows: Range<Int>, of rowCount: Int) -> (y: CGFloat, height: CGFloat) {
        let scale = length / CGFloat(max(1, rowCount))
        let h = max(2, CGFloat(rows.count) * scale)
        return (min(top + CGFloat(rows.lowerBound) * scale, top + length - h), h)
    }

    /// The knob for a viewport given as fractions of the document; at least 16 pt tall.
    public func knob(top viewTop: CGFloat, height viewHeight: CGFloat) -> (y: CGFloat, height: CGFloat) {
        let h = max(16, viewHeight * length)
        return (top + viewTop * (length - h) / max(0.0001, 1 - viewHeight), h)
    }

    /// How far down the document (0…1) a knob of `knobHeight` whose top is at `y` is,
    /// or nil when it fills the track.
    public func fraction(knobY y: CGFloat, knobHeight: CGFloat) -> CGFloat? {
        let travel = length - knobHeight
        guard travel > 0 else { return nil }
        return min(max((y - top) / travel, 0), 1)
    }
}
