import Foundation

/// Where to listen for the noise beside a frequency.
enum QuietSpots {
    /// Up to `count` frequencies within ±`radiusHz` of `hz` whose spectrum level is within 3 dB of the local median and
    /// at least `bandwidthHz` from any bin 6 dB over it, from `hz` itself, and from each other; nearest to `hz` first.
    /// The local median is that of the bins within ±`radiusHz`; spots lie in the capture's usable part
    /// (`centerHz ± spanHz × 0.45`).
    static func pick(_ s: SpectrumSnapshot, around hz: Double, radiusHz: Double = 50_000, bandwidthHz: Double,
                     count: Int) -> [Double] {
        let n = s.average.count
        guard n > 0, count > 0, s.spanHz > 0, bandwidthHz <= radiusHz else { return [] }
        let inRadius = (0..<n).filter { abs(s.hz(ofBin: $0) - hz) <= radiusHz }
        guard !inRadius.isEmpty else { return [] }
        let sorted = inRadius.map { s.average[$0] }.sorted()
        let median = sorted[sorted.count / 2]
        let hot = inRadius.filter { s.average[$0] >= median + 6 }.map { s.hz(ofBin: $0) }
        let usable = s.spanHz * 0.45
        var candidates: [Double] = []
        for i in inRadius where abs(s.average[i] - median) <= 3 {
            let c = s.hz(ofBin: i)
            guard abs(c - s.centerHz) <= usable, abs(c - hz) >= bandwidthHz else { continue }
            if hot.contains(where: { abs($0 - c) < bandwidthHz }) { continue }
            // The whole channel (spot ± bandwidth / 2), not only its centre bin, sits at the median.
            let channel = (0..<n).filter { abs(s.hz(ofBin: $0) - c) <= bandwidthHz / 2 }.map { s.average[$0] }
            guard !channel.isEmpty, abs(channel.reduce(0, +) / Float(channel.count) - median) <= 3 else { continue }
            candidates.append(c)
        }
        candidates.sort { abs($0 - hz) < abs($1 - hz) }
        var chosen: [Double] = []
        for c in candidates where chosen.allSatisfy({ abs($0 - c) >= bandwidthHz }) {
            chosen.append(c)
            if chosen.count == count { break }
        }
        return chosen
    }
}

extension AppModel {
    /// Reads the channel level (`signalDb`) for `spotSeconds` on each quiet spot near `hz`, in the current mode and
    /// bandwidth, with the squelch not gating. Returns the median, and puts the VFO back on `hz`. Nil when no spot is
    /// found or the radio stops.
    ///
    /// The level is measured before the squelch gate (Receiver.process), so the squelch is left alone. The level is
    /// read from the engine's stats: `signalDb` here is a 5 Hz copy that moves only in half-dB steps.
    func measureNoiseFloor(near hz: Double, spots: Int = 3, spotSeconds: Double = 3) async -> Float? {
        guard isRunning, let snapshot = await currentSpectrumSnapshot() else { return nil }
        let picks = QuietSpots.pick(snapshot, around: hz, bandwidthHz: bandwidthHz, count: spots)
        guard !picks.isEmpty else { return nil }
        var medians: [Float] = []
        var completed = true
        for spot in picks {
            guard isRunning, !Task.isCancelled else { completed = false; break }
            setVFO(spot)
            // The AGC and the channel filter settle first.
            try? await Task.sleep(for: .seconds(spotSeconds / 2))
            var reads: [Float] = []
            let readEnd = Date().addingTimeInterval(spotSeconds / 2)
            repeat {
                guard isRunning, !Task.isCancelled else { completed = false; break }
                reads.append(engine.stats.withLock { $0.signalDb })
                try? await Task.sleep(for: .milliseconds(100))
            } while Date() < readEnd
            guard completed else { break }
            medians.append(Self.median(reads))
        }
        if isRunning { setVFO(hz) }
        guard completed, !medians.isEmpty else { return nil }
        return Self.median(medians)
    }

    /// The latest spectrum frame once it is of the current capture (its centre and span as the model's), polling for
    /// up to a second after a retune; nil when none arrives or the task is cancelled.
    func currentSpectrumSnapshot() async -> SpectrumSnapshot? {
        let end = Date().addingTimeInterval(1)
        while isRunning, !Task.isCancelled {
            if let s = spectrumSnapshot(), abs(s.centerHz - centerHz) < 1, abs(s.spanHz - sampleRate) < 1 { return s }
            guard Date() < end else { return nil }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }

    private static func median(_ values: [Float]) -> Float {
        let s = values.sorted()
        return s[s.count / 2]
    }
}
