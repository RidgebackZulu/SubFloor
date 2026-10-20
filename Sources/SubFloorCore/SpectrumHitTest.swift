import Foundation

/// What a pointer press on the spectrum lands on, in the order the spectrum view tests them.
public enum SpectrumHit: Equatable, Sendable {
    /// The modem box's grab tab: drags the box.
    case boxGrabTab
    /// A VFO passband edge: drags the bandwidth.
    case passbandEdge(upper: Bool)
    /// Inside the modem box: a click locks the modem cursor, a drag pans the spectrum.
    case boxBody
    /// Anywhere else: a click tunes the VFO, a drag pans.
    case elsewhere
}

/// Pointer hit-testing for the spectrum view, in points with y measured from the top of the view.
/// The model supplies horizontal extents as fractions of the view width; the grab tab is the top
/// `tabHeight` points over the box, widened to `minTabWidth` (centred on the box) so a box only a
/// few points wide when zoomed out can still be grabbed. The overlay draws the tab with
/// `tabExtent` too, so what is drawn is what is hit.
public enum SpectrumHitTest {
    /// How close, in points, the pointer must be to a passband edge.
    public static let edgeTolerance = 5.0
    public static let tabHeight = 18.0
    public static let minTabWidth = 110.0

    /// The grab tab's horizontal extent, in points, for a box spanning `lower…upper` points.
    public static func tabExtent(lower: Double, upper: Double) -> (lower: Double, upper: Double) {
        guard upper - lower < minTabWidth else { return (lower, upper) }
        let mid = (lower + upper) / 2
        return (mid - minTabWidth / 2, mid + minTabWidth / 2)
    }

    /// What the point `(x, y)` hits in a view `width` points wide: the grab tab first, then a
    /// passband edge (the upper one first), then the box body. Nil extents are absent (no box, an
    /// inactive box's body, no passband).
    public static func hit(x: Double, y: Double, width: Double,
                           grabTab: (lower: Double, upper: Double)?,
                           box: (lower: Double, upper: Double)?,
                           passbandEdges: (lower: Double, upper: Double)?) -> SpectrumHit {
        if let tab = grabTab, y >= 0, y < tabHeight {
            let t = tabExtent(lower: tab.lower * width, upper: tab.upper * width)
            if x >= t.lower && x <= t.upper { return .boxGrabTab }
        }
        if let edges = passbandEdges {
            if abs(x - edges.upper * width) < edgeTolerance { return .passbandEdge(upper: true) }
            if abs(x - edges.lower * width) < edgeTolerance { return .passbandEdge(upper: false) }
        }
        if let box, x >= box.lower * width, x <= box.upper * width { return .boxBody }
        return .elsewhere
    }
}
