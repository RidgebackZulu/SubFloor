import Accelerate
import DSPCore
import Foundation

/// One signal cut out of a capture: mixed to 0 Hz (DSPCore's NCO turning a vDSP phasor table, see
/// `BlockMixer`), low-passed to its bandwidth and decimated.
///
/// The decimation runs in stages of 8, 4 or 2 (DSPCore's `DecimationPlan`) down to the lowest rate at or
/// above 4 × the bandwidth (and at least 8 kHz). Earlier stages only stop aliases from landing on the
/// signal; the last is the channel filter: flat to ±bandwidth/2, stopping from ±0.75 × bandwidth
/// (Blackman-Harris windowed sinc, at most 4095 taps). Every stage's delay is taken out, so output sample k
/// is input time k × the decimation.
public struct Channel {
    /// The lowest output rate.
    public static let minimumRate = 8000.0
    static let maxTaps = 4095

    /// Interleaved IQ in, complex baseband out (`rate` is the output sample rate).
    public static func extract(_ iq: [Float], sampleRate: Double, offsetHz: Double,
                               bandwidthHz: Double) -> (samples: [DSPComplex], rate: Double) {
        let n = iq.count / 2
        guard n > 0, sampleRate > 0 else { return ([], sampleRate) }
        let bandwidth = min(max(bandwidthHz, 1), sampleRate)
        let factors = DecimationPlan.stages(inputRate: sampleRate, minimumRate: max(4 * bandwidth, minimumRate))
        var stages: [Stage] = []
        var rate = sampleRate
        for (i, f) in factors.enumerated() {
            stages.append(i == factors.count - 1
                          ? .channel(rate: rate, factor: f, bandwidth: bandwidth)
                          : .antiAlias(rate: rate, factor: f, bandwidth: bandwidth))
            rate /= Double(f)
        }
        if stages.isEmpty { stages.append(.channel(rate: rate, factor: 1, bandwidth: bandwidth)) }

        // The first stage mixes and filters block by block, so the full-rate signal is never copied whole.
        var mixer = BlockMixer(frequency: -offsetHz, sampleRate: sampleRate)
        var block = [DSPComplex](repeating: DSPComplex(real: 0, imag: 0), count: BlockMixer.blockSize)
        var samples = stages[0].run(count: n) { decimator, out in
            iq.withUnsafeBufferPointer { raw in
                raw.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n) { z in
                    var start = 0
                    while start < n {
                        let m = min(block.count, n - start)
                        block.withUnsafeMutableBufferPointer { b in
                            b.baseAddress!.update(from: z + start, count: m)
                            mixer.mix(b.baseAddress!, count: m)
                            decimator.process(UnsafeBufferPointer(rebasing: b[0..<m]), into: &out)
                        }
                        start += m
                    }
                }
            }
        }
        for stage in stages.dropFirst() {
            let input = samples
            samples = stage.run(count: input.count) { decimator, out in
                input.withUnsafeBufferPointer { decimator.process($0, into: &out) }
            }
        }
        return (samples, rate)
    }

    /// One decimating FIR with its delay compensated: taps = 2 × factor × m + 1, so the delay is m outputs.
    struct Stage {
        let factor: Int
        let taps: [Float]

        /// Passes the band, stops whatever would alias onto ±bandwidth/2 at the output rate.
        static func antiAlias(rate: Double, factor: Int, bandwidth: Double) -> Stage {
            let pass = bandwidth / 2
            let stop = rate / Double(factor) - pass
            return Stage(rate: rate, factor: factor, pass: pass, stop: stop)
        }

        /// Flat to ±bandwidth/2, stopping from ±0.75 × bandwidth.
        static func channel(rate: Double, factor: Int, bandwidth: Double) -> Stage {
            let pass = bandwidth / 2
            let stop = min(0.75 * bandwidth, rate / Double(factor) - pass, rate / 2)
            return Stage(rate: rate, factor: factor, pass: pass, stop: max(stop, pass * 1.01))
        }

        private init(rate: Double, factor: Int, pass: Double, stop: Double) {
            let transition = (stop - pass) / rate
            let needed = FIRDesign.tapCount(transition: transition, max: Channel.maxTaps)
            let m = max(1, (needed - 1 + 2 * factor - 1) / (2 * factor))
            let count = min(2 * factor * m + 1, Channel.maxTaps / (2 * factor) * 2 * factor + 1)
            self.factor = factor
            taps = FIRDesign.lowpass(taps: count, cutoff: (pass + stop) / 2 / rate)
        }

        /// Output for input samples 0, factor, 2·factor … (count ⌈n / factor⌉), fed by `feed`.
        func run(count n: Int, feed: (ComplexDecimator, inout [DSPComplex]) -> Void) -> [DSPComplex] {
            let decimator = ComplexDecimator(taps: taps, factor: factor)
            let delay = (taps.count - 1) / 2
            var out: [DSPComplex] = []
            out.reserveCapacity(n / factor + delay / factor + 2)
            feed(decimator, &out)
            let zeros = [DSPComplex](repeating: DSPComplex(real: 0, imag: 0), count: delay + factor)
            zeros.withUnsafeBufferPointer { decimator.process($0, into: &out) }
            let skip = delay / factor
            let wanted = (n + factor - 1) / factor
            return Array(out[skip..<min(out.count, skip + wanted)])
        }
    }
}

/// Mixes complex samples by e^{j2πft}, a block at a time: one block's phasors from a table (computed in
/// Double), turned for each block by DSPCore's NCO stepping at the block rate, and applied with vDSP.
struct BlockMixer {
    static let blockSize = 4096
    private var tableRe: [Float]
    private var tableIm: [Float]
    private var stepRe = [Float](repeating: 0, count: BlockMixer.blockSize)
    private var stepIm = [Float](repeating: 0, count: BlockMixer.blockSize)
    private var nco: NCO

    init(frequency: Double, sampleRate: Double) {
        let w = 2 * Double.pi * frequency / sampleRate
        tableRe = (0..<Self.blockSize).map { Float(cos(w * Double($0))) }
        tableIm = (0..<Self.blockSize).map { Float(sin(w * Double($0))) }
        nco = NCO(frequency: frequency, sampleRate: sampleRate / Double(Self.blockSize))
    }

    /// Mixes the next `count` (≤ `blockSize`) samples in place; successive calls continue the phase only
    /// when each but the last is a whole block.
    mutating func mix(_ z: UnsafeMutablePointer<DSPComplex>, count m: Int) {
        precondition(m <= Self.blockSize)
        var turn = DSPComplex(real: 1, imag: 0)
        withUnsafeMutablePointer(to: &turn) { nco.mix(UnsafeMutableBufferPointer(start: $0, count: 1)) }
        var tr = turn.real, ti = turn.imag
        let n = vDSP_Length(m)
        tableRe.withUnsafeMutableBufferPointer { ar in
            tableIm.withUnsafeMutableBufferPointer { ai in
                stepRe.withUnsafeMutableBufferPointer { br in
                    stepIm.withUnsafeMutableBufferPointer { bi in
                        var table = DSPSplitComplex(realp: ar.baseAddress!, imagp: ai.baseAddress!)
                        var step = DSPSplitComplex(realp: br.baseAddress!, imagp: bi.baseAddress!)
                        withUnsafeMutablePointer(to: &tr) { rp in
                            withUnsafeMutablePointer(to: &ti) { ip in
                                var scalar = DSPSplitComplex(realp: rp, imagp: ip)
                                vDSP_zvzsml(&table, 1, &scalar, &step, 1, n)
                            }
                        }
                        z.withMemoryRebound(to: Float.self, capacity: 2 * m) { f in
                            var data = DSPSplitComplex(realp: f, imagp: f + 1)
                            vDSP_zvmul(&data, 2, &step, 1, &data, 2, n, 1)
                        }
                    }
                }
            }
        }
    }
}
