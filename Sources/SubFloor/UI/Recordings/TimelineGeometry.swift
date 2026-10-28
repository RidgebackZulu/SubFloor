import CoreGraphics
import Foundation

/// Where things sit on the day timeline, in plotting coordinates: x runs 0…`width` over the 24 h UTC day
/// (the lane label column is not included), y runs down from the top of the first lane. A lane is one
/// `laneHeight` high, and `rowPitch` taller for each extra row its markers are stacked in. Kept apart from the
/// drawing so the placement, the stacking and the hit test are testable without a window.
struct TimelineGeometry {
    static let minMarkerWidth: CGFloat = 6, laneHeight: CGFloat = 34, popRowHeight: CGFloat = 22
    /// A marker's height, centred in its lane's first row.
    static let markerHeight: CGFloat = 18
    /// How far outside a marker a click still lands on it: a 6 pt pill is a small target.
    static let hitSlop: CGFloat = 3
    /// The least space between two markers in one row; closer than that, the later one goes a row down.
    static let stackGap: CGFloat = 2
    /// One more stacked row: a pill, and room above it for the unheard dot (`MarkerPaint.dotRect`).
    static let rowPitch: CGFloat = 26

    let dayStart: Date        // UTC midnight
    let width: CGFloat        // the plotting width, after the lane label column

    /// The height of a lane whose markers are stacked `rows` deep: a single-row lane is `laneHeight`.
    static func laneHeight(rows: Int) -> CGFloat {
        laneHeight + CGFloat(max(rows, 1) - 1) * rowPitch
    }

    /// 0…width over 24 h, clamped: a time before the day sits at 0, one after it at `width`.
    func x(for date: Date) -> CGFloat {
        let seconds = date.timeIntervalSince(dayStart)
        // Multiplied before dividing, so whole hours land on exact points.
        return min(max(CGFloat(seconds) * width / 86_400, 0), width)
    }

    /// Where a recording's pill runs: at least `minMarkerWidth` wide so a 20 s clip is clickable, and cut at
    /// the end of the day. A recording belongs to the day it started on, so one that runs past midnight is
    /// clipped at `width`; a short one in the day's last seconds keeps its width by starting a little earlier.
    func markerSpan(start: Date, seconds: Double) -> ClosedRange<CGFloat> {
        let minX = x(for: start)
        let natural = x(for: start.addingTimeInterval(max(seconds, 0))) - minX
        let maxX = min(minX + max(natural, Self.minMarkerWidth), width)
        let left = max(min(minX, maxX - Self.minMarkerWidth), 0)
        return left...maxX
    }

    /// The pill for a recording on `row` of the lane whose top is `laneTop`.
    func markerRect(start: Date, seconds: Double, laneTop: CGFloat = 0, row: Int = 0) -> CGRect {
        let span = markerSpan(start: start, seconds: seconds)
        let y = laneTop + (Self.laneHeight - Self.markerHeight) / 2 + CGFloat(row) * Self.rowPitch
        return CGRect(x: span.lowerBound, y: y, width: span.upperBound - span.lowerBound, height: Self.markerHeight)
    }

    /// A row for each of one lane's markers, given where each runs, so that no two in a row come closer than
    /// `stackGap`: at the default window a minute is under a point wide, and Auto can catch three
    /// recordings in five minutes. Each goes on the first row free at its start, in start order, which uses
    /// as few rows as any placement can. A lane whose markers are apart keeps them all on row 0.
    static func rows(for spans: [ClosedRange<CGFloat>]) -> [Int] {
        var rows = [Int](repeating: 0, count: spans.count)
        var ends: [CGFloat] = []   // each row's rightmost edge so far
        for i in spans.indices.sorted(by: { (spans[$0].lowerBound, $0) < (spans[$1].lowerBound, $1) }) {
            let span = spans[i]
            if let free = ends.firstIndex(where: { $0 + stackGap <= span.lowerBound }) {
                rows[i] = free
                ends[free] = span.upperBound
            } else {
                rows[i] = ends.count
                ends.append(span.upperBound)
            }
        }
        return rows
    }

    /// The file under `point`, given the markers in drawing order (the last one is on top). A marker the point
    /// is inside wins over one it is only near; within each, the topmost wins.
    func recording(at point: CGPoint, in markers: [(file: String, rect: CGRect)]) -> String? {
        if let hit = markers.last(where: { $0.rect.contains(point) }) { return hit.file }
        let slop = -Self.hitSlop
        return markers.last(where: { $0.rect.insetBy(dx: slop, dy: slop).contains(point) })?.file
    }
}
