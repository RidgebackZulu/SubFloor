import Accelerate
import DSPCore
import Foundation

/// Complex baseband as split real and imaginary parts.
struct Baseband {
    var re: [Float]
    var im: [Float]

    var count: Int { re.count }

    init(count: Int) {
        re = [Float](repeating: 0, count: count)
        im = [Float](repeating: 0, count: count)
    }

    init(re: [Float], im: [Float]) {
        precondition(re.count == im.count)
        self.re = re
        self.im = im
    }

    /// A real signal (zero imaginary part).
    static func real(_ x: [Float]) -> Baseband { Baseband(re: x, im: [Float](repeating: 0, count: x.count)) }

    /// Mean |x|² over the first `n` samples.
    func power(over n: Int) -> Double {
        let m = min(n, count)
        guard m > 0 else { return 0 }
        var a: Float = 0, b: Float = 0
        vDSP_svesq(re, 1, &a, vDSP_Length(m))
        vDSP_svesq(im, 1, &b, vDSP_Length(m))
        return Double(a + b) / Double(m)
    }

    /// Scales to unit mean power over the first `n` samples (left alone when silent there).
    mutating func normalisePower(over n: Int) {
        let p = power(over: n)
        guard p > 0 else { return }
        scale(by: Float(1 / p.squareRoot()))
    }

    mutating func scale(by k: Float) {
        var k = k
        let n = vDSP_Length(count)
        vDSP_vsmul(re, 1, &k, &re, 1, n)
        vDSP_vsmul(im, 1, &k, &im, 1, n)
    }

    /// Multiplies by a real gain of the same length.
    mutating func multiply(by gain: [Float]) {
        precondition(gain.count == count)
        let n = vDSP_Length(count)
        vDSP_vmul(re, 1, gain, 1, &re, 1, n)
        vDSP_vmul(im, 1, gain, 1, &im, 1, n)
    }

    /// Multiplies by e^{jφ}.
    mutating func rotate(by phase: [Double]) {
        precondition(phase.count == count)
        let u = SynthDSP.unitPhasor(phase)
        let n = vDSP_Length(count)
        var outRe = [Float](repeating: 0, count: count)
        var outIm = [Float](repeating: 0, count: count)
        // (a + jb)(c + js) = (ac − bs) + j(as + bc)
        vDSP_vmmsb(re, 1, u.re, 1, im, 1, u.im, 1, &outRe, 1, n)
        vDSP_vmma(re, 1, u.im, 1, im, 1, u.re, 1, &outIm, 1, n)
        re = outRe
        im = outIm
    }

    /// Adds `other` starting at sample `at` (clipped to this signal).
    mutating func add(_ other: Baseband, at: Int) {
        let from = max(0, -at)
        let to = min(other.count, count - at)
        guard to > from else { return }
        for k in from..<to {
            re[at + k] += other.re[k]
            im[at + k] += other.im[k]
        }
    }
}

enum SynthDSP {
    /// Half the taps per phase of the interpolator.
    static let interpolatorHalfSpan = 6

    // MARK: Phase and amplitude

    /// e^{jφ} for each phase.
    static func unitPhasor(_ phase: [Double]) -> Baseband {
        let n = phase.count
        var s = [Double](repeating: 0, count: n)
        var c = [Double](repeating: 0, count: n)
        var count = Int32(n)
        phase.withUnsafeBufferPointer { p in vvsincos(&s, &c, p.baseAddress!, &count) }
        var out = Baseband(count: n)
        vDSP_vdpsp(c, 1, &out.re, 1, vDSP_Length(n))
        vDSP_vdpsp(s, 1, &out.im, 1, vDSP_Length(n))
        return out
    }

    /// Running phase 2π∫f dt of an instantaneous frequency (Hz) sampled at `rate`, from `start`.
    static func integrate(_ frequency: [Double], rate: Double, start: Double = 0) -> [Double] {
        var phase = [Double](repeating: 0, count: frequency.count)
        var acc = start
        let k = 2 * Double.pi / rate
        for i in frequency.indices {
            phase[i] = acc
            acc += k * frequency[i]
        }
        return phase
    }

    /// Unit-amplitude FM: e^{j2π∫f dt}, starting at a random phase.
    static func frequencyModulate(_ frequency: [Double], rate: Double, random: inout SynthRandom) -> Baseband {
        unitPhasor(integrate(frequency, rate: rate, start: 2 * .pi * random.uniform()))
    }

    /// Smooths a 0/1 key with a Hann kernel `seconds` long (raised-cosine edges, area kept).
    static func smoothKey(_ key: [Float], rate: Double, seconds: Double) -> [Float] {
        let m = max(1, Int((seconds * rate).rounded())) | 1
        guard m > 1, key.count > 0 else { return key }
        var kernel = WindowKind.hann.coefficients(count: m + 2)
        kernel = Array(kernel[1...m])
        let sum = kernel.reduce(0, +)
        kernel = kernel.map { $0 / sum }
        let half = m / 2
        var padded = [Float](repeating: 0, count: key.count + m - 1)
        for i in key.indices { padded[i + half] = key[i] }
        // Edge samples repeat the key's first and last values so the ends don't ramp.
        for i in 0..<half {
            padded[i] = key[0]
            padded[key.count + half + i] = key[key.count - 1]
        }
        var out = [Float](repeating: 0, count: key.count)
        vDSP_conv(padded, 1, kernel, 1, &out, 1, vDSP_Length(key.count), vDSP_Length(m))
        return out
    }

    // MARK: Interpolation

    /// Upsamples `x` by an integer factor into interleaved IQ `out` (the first `count` complex samples):
    /// polyphase windowed sinc (Blackman-Harris, 12 taps per phase), cutoff at half the input rate.
    /// Output sample qL lines up with input sample q.
    static func interpolate(_ x: Baseband, factor: Int, into out: inout [Float], count n: Int) {
        if factor == 1 {
            precondition(x.count >= n)
            var one: Float = 1
            out.withUnsafeMutableBufferPointer { o in
                vDSP_vsmul(x.re, 1, &one, o.baseAddress!, 2, vDSP_Length(n))
                vDSP_vsmul(x.im, 1, &one, o.baseAddress! + 1, 2, vDSP_Length(n))
            }
            return
        }
        let phases = polyphaseTaps(factor: factor)
        out.withUnsafeMutableBufferPointer { o in
            polyphase(x.re, factor: factor, count: n, phases: phases, into: o.baseAddress!, stride: 2)
            polyphase(x.im, factor: factor, count: n, phases: phases, into: o.baseAddress! + 1, stride: 2)
        }
    }

    /// Upsamples a real signal by an integer factor to `count` samples.
    static func interpolate(_ x: [Float], factor: Int, count n: Int) -> [Float] {
        if factor == 1 { return Array(x.prefix(n)) + [Float](repeating: 0, count: max(0, n - x.count)) }
        var out = [Float](repeating: 0, count: n)
        let phases = polyphaseTaps(factor: factor)
        out.withUnsafeMutableBufferPointer { o in
            polyphase(x, factor: factor, count: n, phases: phases, into: o.baseAddress!, stride: 1)
        }
        return out
    }

    /// Each phase's taps, reversed for vDSP_conv and scaled by the factor (zero-stuffing loses 1/L).
    private static func polyphaseTaps(factor: Int) -> [[Float]] {
        let k = 2 * interpolatorHalfSpan
        let h = FIRDesign.lowpass(taps: k * factor + 1, cutoff: 0.5 / Double(factor))
        return (0..<factor).map { p in
            (0..<k).map { s in Float(factor) * h[(k - 1 - s) * factor + p] }
        }
    }

    /// y[qL + p] = Σₛ g_p[s] · x[q + K/2 − s].
    private static func polyphase(_ x: [Float], factor: Int, count n: Int, phases: [[Float]],
                                  into out: UnsafeMutablePointer<Float>, stride: Int) {
        let half = interpolatorHalfSpan
        let k = 2 * half
        let used = (n + factor - 1) / factor
        var padded = [Float](repeating: 0, count: used + k + half)
        for i in 0..<min(x.count, padded.count - (half - 1)) { padded[i + half - 1] = x[i] }
        for p in 0..<min(factor, n) {
            let m = (n - p + factor - 1) / factor
            vDSP_conv(padded, 1, phases[p], 1, out + p * stride, factor * stride,
                      vDSP_Length(m), vDSP_Length(k))
        }
    }

    /// Mixes interleaved IQ by e^{j2πft} (see `BlockMixer`).
    static func mix(_ iq: inout [Float], frequency: Double, sampleRate: Double) {
        var mixer = BlockMixer(frequency: frequency, sampleRate: sampleRate)
        let n = iq.count / 2
        iq.withUnsafeMutableBufferPointer { buffer in
            buffer.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n) { z in
                var start = 0
                while start < n {
                    let m = min(BlockMixer.blockSize, n - start)
                    mixer.mix(z + start, count: m)
                    start += m
                }
            }
        }
    }

    // MARK: Impairments

    /// Linear drift (centred on the middle of the span) and a smooth fade of up to `fadeDepthDb`.
    static func impair(_ x: inout Baseband, _ impairments: SynthImpairments, rate: Double, seconds: Double,
                       random: inout SynthRandom) {
        let n = x.count
        let drift = impairments.driftHzPerSecond
        if drift != 0 {
            let mid = seconds / 2
            x.rotate(by: (0..<n).map { i in
                let t = Double(i) / rate - mid
                return Double.pi * drift * t * t
            })
        }
        let depth = impairments.fadeDepthDb
        if depth > 0 {
            let f = [0.6, 1.0, 1.7].map { $0 * impairments.fadeRateHz * random.uniform(0.8...1.2) }
            let phase = f.map { _ in 2 * Double.pi * random.uniform() }
            let gain = (0..<n).map { i -> Float in
                let t = Double(i) / rate
                var s = 0.0
                for j in 0..<3 { s += sin(2 * .pi * f[j] * t + phase[j]) }
                let u = 0.5 + s / 6                         // 0…1
                return Float(pow(10, -depth * u / 20))
            }
            x.multiply(by: gain)
        }
    }

    // MARK: Shaped noise

    /// Complex Gaussian noise of `count` samples whose amplitude spectrum follows `gain(f)` (f in Hz, signed),
    /// with unit mean power. Built by overlap-adding inverse FFTs of random spectra under a sqrt-Hann
    /// window at 50% overlap, so it is stationary with about rate/M Hz of resolution.
    static func shapedNoise(count n: Int, rate: Double, random: inout SynthRandom,
                            gain: (Double) -> Double) -> Baseband {
        var size = 256
        while size < Int(rate / 4) && size < 65_536 { size *= 2 }
        let log2n = vDSP_Length(size.trailingZeroBitCount)
        let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        defer { vDSP_destroy_fftsetup(setup) }
        let shape = (0..<size).map { k -> Float in
            let f = Double(k < size / 2 ? k : k - size) * rate / Double(size)
            return Float(gain(f))
        }
        let active = shape.indices.filter { shape[$0] != 0 }
        let window = (0..<size).map { Float(sin(Double.pi * Double($0) / Double(size))) }
        let hop = size / 2
        var out = Baseband(count: n)
        var re = [Float](repeating: 0, count: size)
        var im = [Float](repeating: 0, count: size)
        var start = -hop
        while start < n {
            for k in 0..<size { re[k] = 0; im[k] = 0 }
            for k in active {
                re[k] = shape[k] * Float(random.gaussian())
                im[k] = shape[k] * Float(random.gaussian())
            }
            re.withUnsafeMutableBufferPointer { rp in
                im.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    vDSP_fft_zip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Inverse))
                }
            }
            for i in 0..<size {
                let j = start + i
                guard j >= 0 && j < n else { continue }
                out.re[j] += re[i] * window[i]
                out.im[j] += im[i] * window[i]
            }
            start += hop
        }
        out.normalisePower(over: n)
        return out
    }
}
