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

    /// Where to estimate the floor when no spot is quiet: the channel at the 20th percentile of the channel levels
    /// within ±`radiusHz` of `hz`. A channel is a bin's frequency with its level the mean of the bins within
    /// ±`bandwidthHz` / 2 (as `pick` reads a channel); it lies in the capture's usable part and at least `bandwidthHz`
    /// from `hz`. The floor is then read as `signalDb` on it, which is already a channel power, so no conversion from
    /// bin levels is needed; the 20th percentile rather than the lowest keeps a dip (a filter edge) from passing for
    /// the floor. Nil when there is no such channel.
    static func lowSpot(_ s: SpectrumSnapshot, around hz: Double, radiusHz: Double = 50_000,
                        bandwidthHz: Double) -> Double? {
        let n = s.average.count
        guard n > 0, s.spanHz > 0, bandwidthHz <= radiusHz else { return nil }
        let usable = s.spanHz * 0.45
        var channels: [(hz: Double, level: Float)] = []
        for i in 0..<n {
            let c = s.hz(ofBin: i)
            guard abs(c - hz) <= radiusHz, abs(c - s.centerHz) <= usable, abs(c - hz) >= bandwidthHz else { continue }
            let levels = (0..<n).filter { abs(s.hz(ofBin: $0) - c) <= bandwidthHz / 2 }.map { s.average[$0] }
            guard !levels.isEmpty else { continue }
            channels.append((c, levels.reduce(0, +) / Float(levels.count)))
        }
        guard !channels.isEmpty else { return nil }
        channels.sort { $0.level != $1.level ? $0.level < $1.level : abs($0.hz - hz) < abs($1.hz - hz) }
        return channels[channels.count / 5].hz
    }
}

extension AppModel {
    /// Reads the channel level (`signalDb`) for `spotSeconds` on each quiet spot within `radiusHz` of `hz`, in the
    /// current mode and bandwidth, with the squelch not gating. Returns the median, and puts the VFO back on `hz`. Nil
    /// when no spot is found or the radio stops.
    ///
    /// It stops (nil) as soon as someone else moves the VFO off the spot it set or moves the centre, and then leaves
    /// the VFO alone, so an owner's retune is never undone; a cancelled task stops the same way.
    ///
    /// The level is measured before the squelch gate (Receiver.process), so the squelch is left alone. The level is
    /// read from the engine's stats: `signalDb` here is a 5 Hz copy that moves only in half-dB steps.
    func measureNoiseFloor(near hz: Double, spots: Int = 3, spotSeconds: Double = 3,
                           radiusHz: Double = 50_000) async -> Float? {
        let start = (vfo: vfoHz, centre: centerHz)   // waiting for a frame, the owner may retune
        guard isRunning, let snapshot = await currentSpectrumSnapshot() else { return nil }
        let picks = quietSpots(snapshot, hz, radiusHz, bandwidthHz, spots)
        return await readFloor(on: picks, returningTo: hz, spotSeconds: spotSeconds, from: start)
    }

    /// When no spot near `hz` is quiet: the level read for `spotSeconds` on the channel `QuietSpots.lowSpot` picks
    /// within 50 kHz, with the VFO back on `hz` after, as `measureNoiseFloor` does. Nil when there is none or it stops.
    func estimateNoiseFloor(near hz: Double, spotSeconds: Double = 3) async -> Float? {
        let start = (vfo: vfoHz, centre: centerHz)
        guard isRunning, let snapshot = await currentSpectrumSnapshot(),
              let spot = lowSpot(snapshot, hz, bandwidthHz) else { return nil }
        return await readFloor(on: [spot], returningTo: hz, spotSeconds: spotSeconds, from: start)
    }

    /// The median of the channel level read on each of `spots` (after half of `spotSeconds` to settle), then the VFO
    /// back on `hz`; see `measureNoiseFloor` for when it stops. `start` is the radio as the measurement began.
    private func readFloor(on spots: [Double], returningTo hz: Double, spotSeconds: Double,
                           from start: (vfo: Double, centre: Double)) async -> Float? {
        guard !spots.isEmpty else { return nil }
        let centre = start.centre
        var vfo = start.vfo   // where this measurement last put the VFO
        func undisturbed() -> Bool { isRunning && !Task.isCancelled && vfoHz == vfo && centerHz == centre }
        var medians: [Float] = []
        var completed = true
        for spot in spots {
            guard undisturbed() else { completed = false; break }
            setVFO(spot)   // inside the usable part (`QuietSpots`): the centre stays
            vfo = vfoHz
            // The AGC and the channel filter settle first.
            try? await Task.sleep(for: .seconds(spotSeconds / 2))
            var reads: [Float] = []
            let readEnd = Date().addingTimeInterval(spotSeconds / 2)
            repeat {
                guard undisturbed() else { break }
                reads.append(engine.stats.withLock { $0.signalDb })
                try? await Task.sleep(for: .milliseconds(100))
            } while Date() < readEnd
            guard undisturbed(), !reads.isEmpty else { completed = false; break }
            medians.append(Self.median(reads))
        }
        if undisturbed() { setVFO(hz) }
        guard completed else { return nil }
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
