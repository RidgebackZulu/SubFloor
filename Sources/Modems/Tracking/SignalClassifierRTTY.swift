import Accelerate
import Foundation
import simd

/// The RTTY rule's wide shifts and rate (see `SignalClassifier`'s rule 1). RTTY is identified only.
extension SignalClassifier {
    /// "RTTY 45 · 170": the rate label and the shift; the rate is left out when it could not be read.
    static func rttySubmode(baud: String?, shiftHz: Int) -> String {
        "RTTY" + (baud.map { " \($0)" } ?? "") + " · \(shiftHz)"
    }
}

extension SignalClassifier.Analysis {
    /// The last 4 s mixed to complex baseband at the track's frequency, 2 kHz wide (±1 kHz), so two
    /// tones up to 850 Hz apart and their keying both show.
    typealias WideBaseband = (z: [SIMD2<Float>], rate: Double, spectrum: SignalClassifier.Spectrum)

    func wideBaseband() -> WideBaseband? {
        let keep = min(tail.count, Int(SignalClassifier.rttyWideSeconds * sampleRate))
        let (z, rate) = SignalClassifier.baseband(
            tail[(tail.endIndex - keep)...], centreHz: track.frequencyHz, sampleRate: sampleRate,
            stage1Rate: 2 * SignalClassifier.rttyWideRate, basebandRate: SignalClassifier.rttyWideRate,
            firCutoffHz: SignalClassifier.rttyWideCutoffHz)
        guard Double(z.count) >= 1.5 * rate else { return nil }
        return (z, rate, SignalClassifier.Spectrum(z, rate: rate, halfWidthHz: rate / 2))
    }

    /// Rule 1 for the shifts the tracker does not pair (425 and 850 Hz): the track is one tone, and the
    /// other lies one shift above or below it, within 6 dB, with energy that is anticorrelated to its
    /// own (keying). Both tones' tracks classify alike.
    func wideRTTY() -> Classification? {
        guard let wide = wideBaseband(), let own = wide.spectrum.lump(around: 0) else { return nil }
        let noise = SignalClassifier.regionThreshold * wide.spectrum.median
        var best: (shiftHz: Double, partnerHz: Double, shiftError: Double, power: Float)?
        for (shift, tolerance) in SignalClassifier.rttyWideShifts {
            for side in [-1.0, 1.0] {
                // Each candidate tone: the strongest bin where the partner should be, then its centroid.
                let expected = side * shift
                guard let peak = wide.spectrum.peak(in: (expected - tolerance)...(expected + tolerance)),
                      peak.power > noise, own.power > noise, let partner = wide.spectrum.lump(around: peak.hz)
                else { continue }
                let shiftError = abs(abs(partner.hz - own.hz) - shift)
                let levelDb = abs(10 * log10(partner.power / own.power))
                guard shiftError <= tolerance, levelDb <= SignalClassifier.rttyLevelDb else { continue }
                if best == nil || partner.power > best!.power {
                    best = (shift, partner.hz, shiftError, partner.power)
                }
            }
        }
        guard let pair = best,
              let correlation = energyCorrelation(wide, 0, pair.partnerHz),
              correlation <= SignalClassifier.rttyMaxCorrelation else { return nil }
        let tolerance = SignalClassifier.rttyWideShifts.first { $0.hz == pair.shiftHz }?.toleranceHz ?? 30
        let confidence = min(
            SignalClassifier.score(pair.shiftError, threshold: tolerance, solid: tolerance / 3),
            SignalClassifier.score(correlation, threshold: SignalClassifier.rttyMaxCorrelation,
                                   solid: SignalClassifier.rttySolidCorrelation))
        let baud = rttyBaud(wide, 0, pair.partnerHz)
        return Classification(mode: .rtty, submode: SignalClassifier.rttySubmode(baud: baud, shiftHz: Int(pair.shiftHz)),
                              confidence: confidence)
    }

    /// The rate label ("45", "50" or "75") of two tones at baseband `aHz` and `bHz` of the wide
    /// baseband, or nil when too few keying runs show.
    func rttyBaud(lowHz: Double, highHz: Double) -> String? {
        wideBaseband().flatMap { rttyBaud($0, lowHz, highHz) }
    }

    func rttyBaud(_ wide: WideBaseband, _ aHz: Double, _ bHz: Double) -> String? {
        let length = max(1, Int((SignalClassifier.rttyEnergySeconds * wide.rate).rounded()))
        let a = SignalClassifier.toneEnergy(wide.z, rate: wide.rate, hz: aHz, length: length)
        let b = SignalClassifier.toneEnergy(wide.z, rate: wide.rate, hz: bHz, length: length)
        // Which tone is mark does not matter: only the runs between changes. Where neither tone is on
        // (silence before the transmission, a fade) the balance is noise: nan, which ends a run.
        var total = [Float](repeating: 0, count: a.count)
        vDSP_vadd(a, 1, b, 1, &total, 1, vDSP_Length(a.count))
        let floor = SignalClassifier.rttyActiveFraction * SignalClassifier.percentile(total, 0.9)
        var balance = [Float](repeating: .nan, count: a.count)
        for i in a.indices where total[i] >= floor && total[i] > 0 { balance[i] = (a[i] - b[i]) / total[i] }
        let runs = SignalClassifier.keyingRuns(balance, rate: wide.rate, hysteresis: SignalClassifier.rttyHysteresis)
        var best: (cost: Double, label: String)?
        for (baud, label) in SignalClassifier.rttyBauds {
            // The tone keyed on at a start bit (the space) runs a whole number of bits; the other one
            // too, except where it holds the stop bit's extra half. So the better-fitting tone counts.
            let costs = runs.filter { $0.count >= SignalClassifier.rttyMinRuns }.map {
                SignalClassifier.wholeBitError($0, bitSeconds: 1 / baud)
            }
            guard let cost = costs.min() else { return nil }
            if best == nil || cost < best!.cost { best = (cost, label) }
        }
        return best?.label
    }

    /// Pearson correlation of the short-time energies at two baseband frequencies of `wide`, each
    /// with its ±100 ms moving average removed (as `toneEnergyCorrelation`).
    private func energyCorrelation(_ wide: WideBaseband, _ aHz: Double, _ bHz: Double) -> Float? {
        let length = max(1, Int((SignalClassifier.rttyEnergySeconds * wide.rate).rounded()))
        let h = Int((0.1 * wide.rate).rounded())
        let a = SignalClassifier.toneEnergy(wide.z, rate: wide.rate, hz: aHz, length: length)
        let b = SignalClassifier.toneEnergy(wide.z, rate: wide.rate, hz: bHz, length: length)
        guard a.count > 2 * h + 16 else { return nil }
        return SignalClassifier.correlation(SignalClassifier.highPass(a, h), SignalClassifier.highPass(b, h))
    }
}

extension SignalClassifier {
    /// Short-time energy of `z` at baseband `hz`: mixed to zero, `length`-sample boxcar, |·|².
    static func toneEnergy(_ z: [SIMD2<Float>], rate: Double, hz: Double, length: Int) -> [Float] {
        let w = -2 * Double.pi * hz / rate
        var shifted = [SIMD2<Float>](repeating: .zero, count: z.count)
        for (n, v) in z.enumerated() {
            let p = w * Double(n)
            shifted[n] = cmul(v, SIMD2(Float(cos(p)), Float(sin(p))))
        }
        return boxcar(shifted, length).map { simd_length_squared($0) }
    }

    /// The lengths (seconds) of the complete runs of each sign of `x` (a series in -1...1, nan where
    /// there is no signal): a run ends where the series, after crossing zero, passes the other side
    /// of the dead band `hysteresis`. Crossings are placed between samples by linear interpolation.
    /// The runs cut off by the capture or by a nan are not counted. Returns the runs of the positive
    /// and negative side.
    static func keyingRuns(_ x: [Float], rate: Double, hysteresis: Float) -> [[Double]] {
        var runs: [[Double]] = [[], []]
        guard x.count > 1 else { return runs }
        var state = 0                   // 1: above the dead band, -1: below, 0: not yet known
        var lastCrossing = 0.0
        var lastChange: Double?
        for i in 1..<x.count {
            let previous = x[i - 1], current = x[i]
            if current.isNaN {
                state = 0
                lastChange = nil
                continue
            }
            if !previous.isNaN, (previous <= 0) != (current <= 0) {
                lastCrossing = (Double(i - 1) + Double(previous / (previous - current))) / rate
            }
            let side = current > hysteresis ? 1 : (current < -hysteresis ? -1 : 0)
            guard side != 0, side != state else { continue }
            if state != 0 {
                if let start = lastChange { runs[state == 1 ? 0 : 1].append(lastCrossing - start) }
                lastChange = lastCrossing
            }
            state = side
        }
        return runs
    }

    /// Mean distance of `runs` from whole multiples of `bitSeconds`, in bits (a run under half a bit
    /// counts as a whole one): 0 when every run is a whole number of bits.
    static func wholeBitError(_ runs: [Double], bitSeconds: Double) -> Double {
        let total = runs.reduce(0.0) { sum, run in
            let bits = run / bitSeconds
            return sum + abs(bits - max(bits.rounded(), 1))
        }
        return total / Double(runs.count)
    }
}
