import CoreGraphics
import Foundation

/// Where things sit on the day timeline, in plotting coordinates: x runs 0…`width` over the 24 h UTC day
/// (the lane label column is not included), y runs down from the top of the first lane, one `laneHeight` per
/// lane. Kept apart from the drawing so the placement and the hit test are testable without a window.
struct TimelineGeometry {
    static let minMarkerWidth: CGFloat = 6, laneHeight: CGFloat = 34, popRowHeight: CGFloat = 22
    /// A marker's height, centred in its lane.
    static let markerHeight: CGFloat = 18
    /// How far outside a marker a click still lands on it: a 6 pt pill is a small target.
    static let hitSlop: CGFloat = 3

    let dayStart: Date        // UTC midnight
    let width: CGFloat        // the plotting width, after the lane label column

    /// 0…width over 24 h, clamped: a time before the day sits at 0, one after it at `width`.
    func x(for date: Date) -> CGFloat {
        let seconds = date.timeIntervalSince(dayStart)
        // Multiplied before dividing, so whole hours land on exact points.
        return min(max(CGFloat(seconds) * width / 86_400, 0), width)
    }

    /// The pill for a recording: at least `minMarkerWidth` wide so a 20 s clip is clickable, and cut at the
    /// end of the day. A recording belongs to the day it started on, so one that runs past midnight is
    /// clipped at `width`; a short one in the day's last seconds keeps its width by starting a little earlier.
    func markerRect(start: Date, seconds: Double, lane: Int) -> CGRect {
        let minX = x(for: start)
        let natural = x(for: start.addingTimeInterval(max(seconds, 0))) - minX
        let maxX = min(minX + max(natural, Self.minMarkerWidth), width)
        let left = max(min(minX, maxX - Self.minMarkerWidth), 0)
        let y = CGFloat(lane) * Self.laneHeight + (Self.laneHeight - Self.markerHeight) / 2
        return CGRect(x: left, y: y, width: maxX - left, height: Self.markerHeight)
    }

    /// The file under `point`, given the markers in drawing order (the last one is on top). A marker the point
    /// is inside wins over one it is only near; within each, the topmost wins.
    func recording(at point: CGPoint, in markers: [(file: String, rect: CGRect)]) -> String? {
        if let hit = markers.last(where: { $0.rect.contains(point) }) { return hit.file }
        let slop = -Self.hitSlop
        return markers.last(where: { $0.rect.insetBy(dx: slop, dy: slop).contains(point) })?.file
    }
}
