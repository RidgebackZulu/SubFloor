import Foundation

/// A spot a pirate watch has found standing over the noise: its centre, width and height over the span's floor.
public struct WatchCandidate: Equatable, Sendable {
    public var hz: Double
    public var widthHz: Double
    public var overFloorDb: Float

    public init(hz: Double, widthHz: Double, overFloorDb: Float) {
        self.hz = hz
        self.widthHz = widthHz
        self.overFloorDb = overFloorDb
    }
}

/// Finds a watch's candidates in its span's spectrum levels, fed about once a second: peaks at least `overFloorDb`
/// over the span's median (its floor), at least `minWidthHz` wide (wider than a bare carrier), that have stood for
/// `holdSeconds`. A peak is a run of adjacent points over the threshold; one seen again within `sameSpotHz` of where
/// it was is the same spot, and one not seen for longer than `holdSeconds` (frames pause while a station records)
/// holds again from scratch.
public struct WatchDetector: Sendable {
    public static let overFloorDb: Float = 10
    public static let holdSeconds: Double = 3
    public static let minWidthHz: Double = 1_000
    /// The 40 m ham band starts at 7000 kHz: peaks within this of the top edge, or running off it, are ignored.
    public static let edgeGuardHz: Double = 3_000
    public static let sameSpotHz: Double = 2_000

    public let lowHz: Double
    public let highHz: Double

    private struct Spot {
        var candidate: WatchCandidate
        let since: Date
        var seen: Date
    }

    /// The spots in the last frame, the first found first.
    private var spots: [Spot] = []
    private var rejected: [(hz: Double, until: Date)] = []

    public init(lowHz: Double, highHz: Double) {
        self.lowHz = lowHz
        self.highHz = highHz
    }

    /// One frame of levels from `fromHz` in steps of `binHz`. Returns the spots that have now stood ≥10 dB over the
    /// span's median, at least `minWidthHz` wide, for `holdSeconds`, and aren't rejected or within `edgeGuardHz` of `highHz`.
    public mutating func feed(levels: [Float], fromHz: Double, binHz: Double, at: Date) -> [WatchCandidate] {
        rejected.removeAll { $0.until <= at }
        guard !levels.isEmpty, binHz > 0 else {
            spots = []
            return []
        }
        let floor = levels.sorted()[levels.count / 2]
        let threshold = floor + Self.overFloorDb
        var next: [Spot] = []
        var i = 0
        while i < levels.count {
            guard levels[i] >= threshold else {
                i += 1
                continue
            }
            var j = i, top = levels[i]
            while j + 1 < levels.count, levels[j + 1] >= threshold {
                j += 1
                top = max(top, levels[j])
            }
            let low = fromHz + Double(i) * binHz, high = fromHz + Double(j + 1) * binHz
            let peak = WatchCandidate(hz: (low + high) / 2, widthHz: high - low, overFloorDb: top - floor)
            let offTheTop = j == levels.count - 1 || peak.hz >= highHz - Self.edgeGuardHz
            i = j + 1
            guard !offTheTop, peak.widthHz >= Self.minWidthHz else { continue }
            if let k = spots.firstIndex(where: { abs($0.candidate.hz - peak.hz) <= Self.sameSpotHz
                                                  && at.timeIntervalSince($0.seen) <= Self.holdSeconds }) {
                var spot = spots.remove(at: k)
                spot.candidate = peak
                spot.seen = at
                next.append(spot)
            } else {
                next.append(Spot(candidate: peak, since: at, seen: at))
            }
        }
        spots = next.sorted { $0.since < $1.since }   // stable: on one frame, the lower first
        return spots.filter { spot in
            at.timeIntervalSince(spot.since) >= Self.holdSeconds
                && !rejected.contains { abs($0.hz - spot.candidate.hz) <= Self.sameSpotHz }
        }.map(\.candidate)
    }

    /// Skips the spot within `sameSpotHz` of `hz` until `until`.
    public mutating func reject(_ hz: Double, until: Date) {
        rejected.append((hz, until))
    }
}
