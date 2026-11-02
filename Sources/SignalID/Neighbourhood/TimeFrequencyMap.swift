import Accelerate
import DSPCore
import Foundation

/// A picture of frequency against time around a point: what `TraceFinder` reads.
///
/// `z` is cut into overlapping Hann-windowed frames 1 / `binHz` long, whatever its rate: at any capture rate the same
/// frequency resolution and the same scatter in the noise. Each frame is zero-padded to a power of two, and the map's
/// bins are that spectrum's nearest ones `binHz` apart.
///
/// Each row is its own moment's power over that moment's noise level. The level is the row's 20th percentile, less
/// that percentile's bias for noise (a bin's power in noise is exponential: its 20th percentile is −ln 0.8 of its mean), so
/// a bin of noise averages 0 dB over rows and a level jump across the band leaves the rows alike. A low percentile
/// because a crowded view is mostly signals: its median would be one of them, and they would read as noise.
struct TimeFrequencyMap {
    /// Which of a row's bins, sorted, gives its noise level, and what that percentile is of noise's mean.
    static let noiseShare = 0.2
    static let noiseBias = -log(0.8)

    let binHz: Double
    let hopSeconds: Double
    /// Bin 0, relative to the capture centre.
    let lowerOffsetHz: Double
    let rows: Int
    let bins: Int
    /// Power over that moment's own noise level, in dB, row by row.
    let relativeDb: [Float]
    /// Each row's noise level, in dB relative to 1 per Hz.
    let noiseDbPerHz: [Float]
    /// Each row's first sample, in seconds within `z`, is `row × hopSeconds`; this is how long a row lasts.
    var frameSeconds: Double { 1 / binHz }

    /// The bin of `offsetHz` (relative to the capture centre), not limited to the map.
    func bin(_ offsetHz: Double) -> Int { Int(((offsetHz - lowerOffsetHz) / binHz).rounded()) }
    /// The offset (relative to the capture centre) of a bin position.
    func offsetHz(_ bin: Double) -> Double { lowerOffsetHz + bin * binHz }

    /// `z` at `rate`, its 0 Hz `centerOffsetHz` from the capture centre, over ±`halfSpanHz` of that (as far as the
    /// rate holds). Empty when `z` is shorter than one frame.
    static func build(_ z: [DSPComplex], rate: Double, centerOffsetHz: Double, binHz: Double, hopSeconds: Double,
                      halfSpanHz: Double = .infinity) -> TimeFrequencyMap {
        let frame = Int((rate / binHz).rounded())
        let hop = max(1, Int((hopSeconds * rate).rounded()))
        let half = Int(min(halfSpanHz, rate / 2 - binHz) / binHz)
        func empty() -> TimeFrequencyMap {
            TimeFrequencyMap(binHz: binHz, hopSeconds: hopSeconds, lowerOffsetHz: centerOffsetHz, rows: 0, bins: 0,
                             relativeDb: [], noiseDbPerHz: [])
        }
        guard frame >= 8, half >= 8, z.count >= frame else { return empty() }
        let rows = (z.count - frame) / hop + 1
        let bins = 2 * half + 1
        let size = FFT.size(atLeast: frame)
        let log2n = vDSP_Length(size.trailingZeroBitCount)
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return empty() }
        defer { vDSP_destroy_fftsetup(setup) }

        // A periodic Hann window scaled so white noise of unit power reads 1 in every bin.
        var window = (0..<frame).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(frame))) }
        var energy: Float = 0
        vDSP_svesq(window, 1, &energy, vDSP_Length(frame))
        var scale = 1 / energy.squareRoot()
        vDSP_vsmul(window, 1, &scale, &window, 1, vDSP_Length(frame))
        // Each map bin's place in the FFT's (unshifted) output, counting from 1 as vDSP does.
        let picks = (0..<bins).map { b -> vDSP_Length in
            let k = Int((Double(b - half) * binHz * Double(size) / rate).rounded())
            return vDSP_Length((k + size) % size + 1)
        }

        var relative = [Float](repeating: 0, count: rows * bins)
        var noise = [Float](repeating: 0, count: rows)
        var re = [Float](repeating: 0, count: size), im = [Float](repeating: 0, count: size)
        var power = [Float](repeating: 0, count: size)
        var row = [Float](repeating: 0, count: bins), sorted = row
        let quantile = min(bins - 1, Int(Self.noiseShare * Double(bins)))
        let bias = Float(Self.noiseBias)
        for r in 0..<rows {
            z.withUnsafeBufferPointer { samples in
                re.withUnsafeMutableBufferPointer { rp in
                    im.withUnsafeMutableBufferPointer { ip in
                        var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                        vDSP_vclr(rp.baseAddress!, 1, vDSP_Length(size))
                        vDSP_vclr(ip.baseAddress!, 1, vDSP_Length(size))
                        vDSP_ctoz(samples.baseAddress! + r * hop, 2, &split, 1, vDSP_Length(frame))
                        vDSP_vmul(rp.baseAddress!, 1, window, 1, rp.baseAddress!, 1, vDSP_Length(frame))
                        vDSP_vmul(ip.baseAddress!, 1, window, 1, ip.baseAddress!, 1, vDSP_Length(frame))
                        vDSP_fft_zip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
                        vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(size))
                    }
                }
            }
            vDSP_vgathr(power, picks, 1, &row, 1, vDSP_Length(bins))
            sorted = row
            vDSP_vsort(&sorted, vDSP_Length(bins), 1)
            let level = max(sorted[quantile] / bias, 1e-20)
            noise[r] = 10 * log10(level / Float(rate))
            relative.withUnsafeMutableBufferPointer { out in
                let start = out.baseAddress! + r * bins
                var reference = level
                vDSP_vthr(row, 1, [Float(1e-20)], &row, 1, vDSP_Length(bins))
                vDSP_vdbcon(row, 1, &reference, start, 1, vDSP_Length(bins), 0)
            }
        }
        return TimeFrequencyMap(binHz: binHz, hopSeconds: Double(hop) / rate,
                                lowerOffsetHz: centerOffsetHz - Double(half) * binHz, rows: rows, bins: bins,
                                relativeDb: relative, noiseDbPerHz: noise)
    }
}
