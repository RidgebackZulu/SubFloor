import Foundation

/// How much of Signal ID's synthetic sweeps a run makes (ruling R32).
///
/// A default `swift test` checks each family test once (at 10 dB, the harder of its two SNRs, on its first seed, over
/// the cases that stand for its families), names each row of the mode table once (`IdentifyTests.eachRowIsNamed`) and
/// leaves the accuracy matrix out. Each suite runs its tests one at a time (`.serialized`). So it costs about 2
/// CPU-minutes in a debug build and mostly one core, and doesn't starve the suites that run beside it (the modem
/// worker's, the MCP server's and Signal ID's own service timing tests).
///
/// `SUBFLOOR_SIGNALID_MATRIX=1` runs all of it: every SNR, seed and case of the family sweeps, every catalogue
/// placement, and the full accuracy matrix with its always-on subset (`AccuracyMatrixTests`). The targets are the
/// same either way: a default run checks fewer cases against them, never looser ones.
enum Sweep {
    /// `SUBFLOOR_SIGNALID_MATRIX=1`: every case.
    static var full: Bool { ProcessInfo.processInfo.environment["SUBFLOOR_SIGNALID_MATRIX"] == "1" }

    /// A family test's SNRs: 20 and 10 dB, or 10 dB alone.
    static var snrs: [Double] { full ? [20, 10] : [10] }

    /// `seeds`, or its first alone.
    static func seeds(_ seeds: ClosedRange<UInt64>) -> ClosedRange<UInt64> {
        full ? seeds : seeds.lowerBound...seeds.lowerBound
    }

    /// `all` with each case's index (a seed is often made from it), or only the cases at `picks`: the same cases a
    /// full run makes there, with the same seeds.
    static func cases<T>(_ all: [T], default picks: [Int]) -> [(offset: Int, element: T)] {
        let indexed = Array(all.enumerated()).map { (offset: $0.offset, element: $0.element) }
        return full ? indexed : indexed.filter { picks.contains($0.offset) }
    }
}
