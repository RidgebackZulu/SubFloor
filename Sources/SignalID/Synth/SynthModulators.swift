import Accelerate
import DSPCore
import Foundation

/// Complex baseband of each family at a working rate, centred on its occupied band.
enum SynthModulators {
    static func baseband(_ spec: SynthSpec, rate: Double, count n: Int, random: inout SynthRandom) -> Baseband {
        switch spec {
        case .noise:
            return Baseband(count: n)
        case .carrier:
            return constant(n, phase: 2 * .pi * random.uniform())
        case .cw(let wpm):
            var x = Baseband.real(morseKey(wpm: wpm, rate: rate, count: n, random: &random))
            x.rotate(by: [Double](repeating: 2 * .pi * random.uniform(), count: n))
            return x
        case .am(let audio, let depth):
            let a = SynthAudio.make(audio, rate: rate, count: n, random: &random)
            var x = Baseband.real(a.map { 1 + Float(depth) * $0 })
            x.rotate(by: [Double](repeating: 2 * .pi * random.uniform(), count: n))
            return x
        case .ssb(let upper, let low, let high):
            return ssb(upper: upper, low: low, high: high, rate: rate, count: n, random: &random)
        case .fm(let audio, let deviation):
            let a = SynthAudio.make(audio, rate: rate, count: n, preEmphasis: true, random: &random)
            return SynthDSP.frequencyModulate(a.map { deviation * Double($0) }, rate: rate, random: &random)
        case .fsk(let fsk):
            return SynthDSP.frequencyModulate(fskFrequency(fsk, rate: rate, count: n, random: &random),
                                              rate: rate, random: &random)
        case .psk(let psk):
            return self.psk(psk, rate: rate, count: n, random: &random)
        case .ofdm(let ofdm):
            return self.ofdm(ofdm, rate: rate, count: n, random: &random)
        case .bursts(let inner, let schedule):
            return bursts(inner, schedule, rate: rate, count: n, random: &random)
        }
    }

    private static func constant(_ n: Int, phase: Double) -> Baseband {
        Baseband(re: [Float](repeating: Float(cos(phase)), count: n),
                 im: [Float](repeating: Float(sin(phase)), count: n))
    }

    // MARK: CW and SSB

    private static let words = ["CQ", "DE", "TEST", "K", "PSE", "QTH", "NAME", "RST", "599", "TU", "73", "UR",
                                "ES", "HR", "WX", "RIG", "ANT", "FB", "OM", "BK", "QRZ", "AGN", "GM", "5NN"]

    /// 0…1 key of random Morse text at `wpm`, starting at a random point of the text, smoothed by a Hann
    /// kernel 15 ms long (half a dot above 40 WPM): raised-cosine edges, 10–90% rise about 7 ms.
    static func morseKey(wpm: Double, rate: Double, count n: Int, random: inout SynthRandom) -> [Float] {
        let unit = MorseCode.dotSeconds(wpm: wpm)
        let skip = random.uniform(0...2)
        let needed = (Double(n) / rate + skip) / unit + 60
        var elements: [(on: Bool, units: Int)] = []
        var units = 0
        while Double(units) < needed {
            if !elements.isEmpty { elements.append((false, 7)) }
            let word = MorseCode.timeline(for: words[random.int(words.count)])
            elements += word.map { ($0.on, $0.units) }
            units += 7 + word.reduce(0) { $0 + $1.units }
        }
        var key = [Float](repeating: 0, count: n)
        var t = -skip
        for e in elements {
            let end = t + Double(e.units) * unit
            if e.on {
                let from = max(0, Int((t * rate).rounded())), to = min(n, Int((end * rate).rounded()))
                if to > from { for i in from..<to { key[i] = 1 } }
            }
            t = end
            if t * rate >= Double(n) { break }
        }
        return SynthDSP.smoothKey(key, rate: rate, seconds: min(0.015, unit / 2))
    }

    /// Speech-like noise in the passband (the lower audio frequencies at the carrier side), −6 dB tilt
    /// across it, with a syllabic envelope.
    private static func ssb(upper: Bool, low: Double, high: Double, rate: Double, count n: Int,
                            random: inout SynthRandom) -> Baseband {
        let width = high - low
        var x = SynthDSP.shapedNoise(count: n, rate: rate, random: &random) { f in
            guard abs(f) <= width / 2 else { return 0 }
            let fromCarrier = upper ? f + width / 2 : width / 2 - f       // 0 at the audio's low edge
            return pow(10, -6 * fromCarrier / width / 20)
        }
        x.multiply(by: SynthAudio.syllables(rate: rate, count: n, random: &random))
        return x
    }

    // MARK: FSK

    /// Instantaneous frequency of random FSK symbols: rectangular, or Gaussian-filtered with BT.
    static func fskFrequency(_ fsk: SynthSpec.FSK, rate: Double, count n: Int,
                             random: inout SynthRandom) -> [Double] {
        let period = 1 / fsk.rate
        let clock = random.uniform() * period                 // symbol k spans [kT, (k+1)T) at time t + clock
        let lead = 8
        let symbols = Int((Double(n) / rate + clock) * fsk.rate) + 2 * lead + 1
        let centre = Double(fsk.tones - 1) / 2
        let tone = (0..<symbols).map { _ in (Double(random.int(fsk.tones)) - centre) * fsk.spacingHz }
        guard let bt = fsk.gaussianBT else {
            return (0..<n).map { i in tone[Int((Double(i) / rate + clock) * fsk.rate) + lead] }
        }
        let sigma = log(2).squareRoot() / (2 * .pi * bt * fsk.rate)
        let reach = min(lead - 1, Int((3 * sigma * fsk.rate).rounded(.up)) + 1)
        let scale = 1 / (2.squareRoot() * sigma)
        return (0..<n).map { i in
            let tau = Double(i) / rate + clock
            let k0 = Int(tau * fsk.rate)
            var f = 0.0
            for k in (k0 - reach)...(k0 + reach) {
                let a = tau - Double(k) * period
                let g = 0.5 * (erf(a * scale) - erf((a - period) * scale))
                f += tone[k + lead] * g
            }
            return f
        }
    }

    // MARK: PSK

    private static func psk(_ psk: SynthSpec.PSK, rate: Double, count n: Int,
                            random: inout SynthRandom) -> Baseband {
        let period = 1 / psk.rate
        let spanSymbols: Double
        let pulse: (Double) -> Double                          // of t / T
        switch psk.shape {
        case .rootRaisedCosine(let alpha):
            spanSymbols = 8
            pulse = { rootRaisedCosine($0, alpha: alpha) }
        case .cosine:
            spanSymbols = 1
            pulse = { abs($0) >= 1 ? 0 : 0.5 * (1 + cos(.pi * $0)) }
        }
        // Pulse table at T/256, linearly interpolated.
        let resolution = 256.0
        let tableCount = Int(2 * spanSymbols * resolution) + 2
        let table = (0..<tableCount).map { Float(pulse(Double($0) / resolution - spanSymbols)) }
        let clock = random.uniform() * period
        let span = spanSymbols * period
        var out = Baseband(count: n)
        let duration = Double(n) / rate
        var k = Int(((-span - clock) / period).rounded(.down))
        while Double(k) * period - clock <= duration + span {
            let centre = Double(k) * period - clock
            let angle = 2 * Double.pi * Double(random.int(psk.order)) / Double(psk.order)
            let c = Float(cos(angle)), s = Float(sin(angle))
            let from = max(0, Int(((centre - span) * rate).rounded(.up)))
            let to = min(n - 1, Int(((centre + span) * rate).rounded(.down)))
            if to >= from {
                for i in from...to {
                    let u = ((Double(i) / rate - centre) / period + spanSymbols) * resolution
                    let j = min(max(Int(u), 0), tableCount - 2)
                    let w = Float(u - Double(j))
                    let v = table[j] + (table[j + 1] - table[j]) * w
                    out.re[i] += v * c
                    out.im[i] += v * s
                }
            }
            k += 1
        }
        return out
    }

    /// Root-raised-cosine impulse response at t/T.
    static func rootRaisedCosine(_ t: Double, alpha a: Double) -> Double {
        if abs(t) < 1e-9 { return 1 - a + 4 * a / .pi }
        if a > 0 && abs(abs(t) - 1 / (4 * a)) < 1e-9 {
            return a / 2.squareRoot() * ((1 + 2 / .pi) * sin(.pi / (4 * a)) + (1 - 2 / .pi) * cos(.pi / (4 * a)))
        }
        let num = sin(.pi * t * (1 - a)) + 4 * a * t * cos(.pi * t * (1 + a))
        let den = .pi * t * (1 - (4 * a * t) * (4 * a * t))
        return num / den
    }

    // MARK: OFDM

    /// QPSK on every carrier, built by inverse FFT at carriers' natural rate (a power-of-two multiple of
    /// the spacing) and resampled to `rate`.
    private static func ofdm(_ o: SynthSpec.OFDM, rate: Double, count n: Int,
                             random: inout SynthRandom) -> Baseband {
        var size = 64
        while size < 2 * o.carriers { size *= 2 }
        let natural = Double(size) * o.spacingHz
        let prefix = Int((o.cpFraction * Double(size)).rounded())
        let symbol = size + prefix
        let resampled = abs(natural - rate) > 1e-6 * rate
        // The resampler's first outputs ramp in from its empty history (its kernel spans 32 samples of the
        // lower rate): skip them.
        let kernel = 32 * max(1, natural / rate)
        let skip = resampled ? Int((kernel * rate / natural).rounded(.up)) + 1 : 0
        let lead = random.int(symbol)
        let needed = Int((Double(n + skip) / rate * natural).rounded(.up)) + lead + 4
        let bins: [Int] = o.carriers.isMultiple(of: 2)
            ? Array(-(o.carriers / 2)...(-1)) + Array(1...(o.carriers / 2))
            : Array(-((o.carriers - 1) / 2)...((o.carriers - 1) / 2))
        let log2n = vDSP_Length(size.trailingZeroBitCount)
        let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        defer { vDSP_destroy_fftsetup(setup) }
        var re = [Float](), im = [Float]()
        re.reserveCapacity(needed + symbol)
        im.reserveCapacity(needed + symbol)
        var fr = [Float](repeating: 0, count: size), fi = [Float](repeating: 0, count: size)
        let level = Float(0.5.squareRoot())
        while re.count < needed {
            for i in 0..<size { fr[i] = 0; fi[i] = 0 }
            for b in bins {
                let q = random.int(4)
                let j = (b + size) % size
                fr[j] = q & 1 == 0 ? level : -level
                fi[j] = q & 2 == 0 ? level : -level
            }
            fr.withUnsafeMutableBufferPointer { rp in
                fi.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    vDSP_fft_zip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Inverse))
                }
            }
            re += fr[(size - prefix)...] + fr
            im += fi[(size - prefix)...] + fi
        }
        re.removeFirst(lead)
        im.removeFirst(lead)
        guard resampled else { return Baseband(re: Array(re.prefix(n)), im: Array(im.prefix(n))) }
        var outRe = [Float](), outIm = [Float]()
        var a = FractionalResampler(inputRate: natural, outputRate: rate)
        var b = FractionalResampler(inputRate: natural, outputRate: rate)
        re.withUnsafeBufferPointer { a.process($0, into: &outRe) }
        im.withUnsafeBufferPointer { b.process($0, into: &outIm) }
        let usable = min(outRe.count, outIm.count)
        precondition(usable - skip >= n, "OFDM synthesis came up short")
        return Baseband(re: Array(outRe[skip..<(skip + n)]), im: Array(outIm[skip..<(skip + n)]))
    }

    // MARK: Bursts

    /// Each transmission overlapping the capture is a fresh stretch of the inner signal at unit power,
    /// with raised-cosine ramps at its true start and end.
    private static func bursts(_ inner: SynthSpec, _ b: SynthSpec.Bursts, rate: Double, count n: Int,
                               random: inout SynthRandom) -> Baseband {
        var out = Baseband(count: n)
        let c0 = b.captureStartSeconds
        let c1 = c0 + Double(n) / rate
        var j = Int(((c0 - b.startSeconds - b.onSeconds) / b.periodSeconds).rounded(.down))
        while true {
            let on = Double(j) * b.periodSeconds + b.startSeconds
            if on >= c1 { break }
            let off = on + b.onSeconds
            j += 1
            guard off > c0 else { continue }
            let from = max(on, c0), to = min(off, c1)
            let at = Int(((from - c0) * rate).rounded())
            let m = min(n - at, Int(((to - from) * rate).rounded()))
            guard m > 0 else { continue }
            var segment = baseband(inner, rate: rate, count: m, random: &random)
            segment.normalisePower(over: m)
            let ramp = b.rampSeconds
            segment.multiply(by: (0..<m).map { i in
                let t = from + Double(i) / rate
                let edge = min(t - on, off - t)
                return edge >= ramp ? 1 : Float(0.5 - 0.5 * cos(.pi * max(edge, 0) / ramp))
            })
            out.add(segment, at: at)
        }
        return out
    }
}
