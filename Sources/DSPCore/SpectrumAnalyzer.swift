import Accelerate

/// Windowed complex FFT producing an FFT-shifted power spectrum in dBFS.
/// Output index 0 is −fs/2, index size/2 is DC. A unit-amplitude complex tone reads 0 dB.
public final class SpectrumAnalyzer {
    public let size: Int
    public let window: WindowKind
    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private let coefficients: [Float]
    private var re: [Float]
    private var im: [Float]
    private var power: [Float]
    private let normalization: Float

    public init(size: Int, window: WindowKind = .blackmanHarris) {
        precondition(size >= 16 && size & (size - 1) == 0, "FFT size must be a power of two")
        self.size = size
        self.window = window
        log2n = vDSP_Length(size.trailingZeroBitCount)
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        coefficients = window.coefficients(count: size)
        re = .init(repeating: 0, count: size)
        im = .init(repeating: 0, count: size)
        power = .init(repeating: 0, count: size)
        let sum = coefficients.reduce(0, +)
        normalization = 1 / (sum * sum)
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    public func process(_ iq: UnsafeBufferPointer<DSPComplex>, into db: UnsafeMutableBufferPointer<Float>) {
        precondition(iq.count == size && db.count == size)
        let n = vDSP_Length(size)
        let half = size / 2
        re.withUnsafeMutableBufferPointer { rp in
            im.withUnsafeMutableBufferPointer { ip in
                power.withUnsafeMutableBufferPointer { pp in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    vDSP_ctoz(iq.baseAddress!, 2, &split, 1, n)
                    vDSP_vmul(rp.baseAddress!, 1, coefficients, 1, rp.baseAddress!, 1, n)
                    vDSP_vmul(ip.baseAddress!, 1, coefficients, 1, ip.baseAddress!, 1, n)
                    vDSP_fft_zip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
                    vDSP_zvmags(&split, 1, pp.baseAddress!, 1, n)
                    var norm = normalization
                    vDSP_vsmul(pp.baseAddress!, 1, &norm, pp.baseAddress!, 1, n)
                    var floor: Float = 1e-20
                    vDSP_vthr(pp.baseAddress!, 1, &floor, pp.baseAddress!, 1, n)
                    var reference: Float = 1
                    vDSP_vdbcon(pp.baseAddress!, 1, &reference, pp.baseAddress!, 1, n, 0)
                    db.baseAddress!.update(from: pp.baseAddress! + half, count: half)
                    (db.baseAddress! + half).update(from: pp.baseAddress!, count: half)
                }
            }
        }
    }
}

/// Exponential averaging in the dB domain plus peak hold.
public final class SpectrumAverager {
    public var alpha: Float
    public private(set) var average: [Float]
    public private(set) var peak: [Float]
    private var primed = false

    public init(size: Int, alpha: Float = 0.5) {
        self.alpha = alpha
        average = .init(repeating: -200, count: size)
        peak = .init(repeating: -200, count: size)
    }

    public func add(_ frame: UnsafeBufferPointer<Float>) {
        precondition(frame.count == average.count)
        let n = vDSP_Length(frame.count)
        average.withUnsafeMutableBufferPointer { a in
            if !primed {
                a.baseAddress!.update(from: frame.baseAddress!, count: frame.count)
            } else {
                var c = alpha
                // a = a + c * (frame − a)
                vDSP_vintb(a.baseAddress!, 1, frame.baseAddress!, 1, &c, a.baseAddress!, 1, n)
            }
        }
        peak.withUnsafeMutableBufferPointer { p in
            if !primed {
                p.baseAddress!.update(from: frame.baseAddress!, count: frame.count)
            } else {
                vDSP_vmax(p.baseAddress!, 1, frame.baseAddress!, 1, p.baseAddress!, 1, n)
            }
        }
        primed = true
    }

    public func resetPeak() { peak = average }
}
