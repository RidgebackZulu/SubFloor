import Foundation

/// Where the bookmark flags go above the spectrum: each in the first row where it doesn't touch its neighbour, so
/// flags that would overlap step down instead. Past `maxRows` the rest share the last row, overlapping.
enum BookmarkFlagLayout {
    struct Flag {
        var id: UUID
        /// The bookmark's frequency, in points across the view.
        var x: CGFloat
        var width: CGFloat
    }

    struct Placement: Equatable {
        /// The flag's centre: at `x`, unless that would put it past an edge of the view.
        var centerX: CGFloat
        var row: Int
    }

    static func place(_ flags: [Flag], viewWidth: CGFloat, maxRows: Int = 5, gap: CGFloat = 4) -> [UUID: Placement] {
        let lefts = flags.map { max(min($0.x - $0.width / 2, viewWidth - $0.width), 0) }
        var rightEdges: [CGFloat] = []
        var placements: [UUID: Placement] = [:]
        // Left to right, and in the list's order at one frequency, so the same flags always land in the same rows.
        for i in flags.indices.sorted(by: { (lefts[$0], $0) < (lefts[$1], $1) }) {
            let row = rightEdges.firstIndex { $0 + gap <= lefts[i] }
                ?? (rightEdges.count < maxRows ? rightEdges.count : maxRows - 1)
            let right = lefts[i] + flags[i].width
            if row < rightEdges.count { rightEdges[row] = max(rightEdges[row], right) } else { rightEdges.append(right) }
            placements[flags[i].id] = Placement(centerX: lefts[i] + flags[i].width / 2, row: row)
        }
        return placements
    }
}
