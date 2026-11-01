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
///
/// With `sharp` false the last stage is only an anti-alias stage too: ±bandwidth/2 is kept clean, but what
/// lies beyond it up to the output's Nyquist frequency is left in. Far cheaper at high input rates, for a
/// view that only reads its middle band (Signal ID's analysis window).
public struct Channel {
    /// The lowest output rate.
    public static let minimumRate = 8000.0
    static let maxTaps = 4095

    /// Interleaved IQ in, complex baseband out (`rate` is the output sample rate).
    public static func extract(_ iq: [Float], sampleRate: Double, offsetHz: Double, bandwidthHz: Double,
                               sharp: Bool = true) -> (samples: [DSPComplex], rate: Double) {
        let n = iq.count / 2
        guard n > 0, sampleRate > 0 else { return ([], sampleRate) }
        let (stages, rate) = plan(sampleRate: sampleRate, bandwidthHz: bandwidthHz, sharp: sharp)

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

    /// Equivalent noise bandwidth of the (sharp) channel `extract` cuts: white noise of density N0 comes out
    /// at N0 × this. It is the last stage's (the earlier ones are flat across the band).
    public static func noiseBandwidthHz(sampleRate: Double, bandwidthHz: Double) -> Double {
        let (stages, rate) = plan(sampleRate: sampleRate, bandwidthHz: bandwidthHz)
        let taps = stages.last!.taps.map(Double.init)
        let sum = taps.reduce(0, +)
        let squares = taps.reduce(0) { $0 + $1 * $1 }
        return rate * Double(stages.last!.factor) * squares / (sum * sum)
    }

    /// The (sharp) channel's noise correlation `lag` output samples apart: white noise in comes out with
    /// E[n[k] · n*[k − lag]] = this × E|n|² (real, the filter being symmetric about 0 Hz). It is the last
    /// stage's, one output sample being `factor` of its input samples.
    public static func noiseCorrelation(sampleRate: Double, bandwidthHz: Double, lag outputs: Int = 1) -> Double {
        let (stages, _) = plan(sampleRate: sampleRate, bandwidthHz: bandwidthHz)
        let taps = stages.last!.taps.map(Double.init)
        let lag = stages.last!.factor * outputs
        let squares = taps.reduce(0) { $0 + $1 * $1 }
        guard squares > 0, lag < taps.count else { return 0 }
        var sum = 0.0
        for k in 0..<(taps.count - lag) { sum += taps[k] * taps[k + lag] }
        return sum / squares
    }

    /// The output rate a channel `bandwidthHz` wide cut from `sampleRate` has (the input's, when it doesn't
    /// decimate). Plans no filters.
    public static func outputRate(sampleRate: Double, bandwidthHz: Double) -> Double {
        let bandwidth = min(max(bandwidthHz, 1), sampleRate)
        return DecimationPlan.stages(inputRate: sampleRate, minimumRate: max(4 * bandwidth, minimumRate))
            .reduce(sampleRate) { $0 / Double($1) }
    }

    /// The stages and the output rate.
    static func plan(sampleRate: Double, bandwidthHz: Double,
                     sharp: Bool = true) -> (stages: [Stage], rate: Double) {
        let bandwidth = min(max(bandwidthHz, 1), sampleRate)
        let factors = DecimationPlan.stages(inputRate: sampleRate, minimumRate: max(4 * bandwidth, minimumRate))
        var stages: [Stage] = []
        var rate = sampleRate
        for (i, f) in factors.enumerated() {
            stages.append(i == factors.count - 1 && sharp
                          ? .channel(rate: rate, factor: f, bandwidth: bandwidth)
                          : .antiAlias(rate: rate, factor: f, bandwidth: bandwidth))
            rate /= Double(f)
        }
        if stages.isEmpty {
            stages.append(sharp ? .channel(rate: rate, factor: 1, bandwidth: bandwidth)
                                : .antiAlias(rate: rate, factor: 1, bandwidth: bandwidth))
        }
        return (stages, rate)
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

/// `Channel.extract` fed a piece at a time, for a capture too long to hold at its input rate (Signal ID's longer
/// read off the IQ ring): the same output, whatever the pieces' sizes, holding only the output so far, one mixer
/// block and each stage's filter state. The output is interleaved IQ at `rate`.
public final class ChannelExtractor {
    /// The output sample rate.
    public let rate: Double
    private let stages: [Channel.Stage]
    private let decimators: [ComplexDecimator]
    private var mixer: BlockMixer
    /// Input not yet a whole mixer block: the mixer's phase carries over whole blocks only.
    private var block: [DSPComplex]
    private var blockFill = 0
    /// Per stage: inputs taken, leading outputs still to drop (its delay), outputs passed on, new outputs.
    private var taken: [Int]
    private var toSkip: [Int]
    private var passed: [Int]
    private var scratch: [[DSPComplex]]
    private var samples: [Float] = []

    /// `expectedInputFrames`: how much will be fed, so the output is sized once instead of growing by doubling
    /// (a 16 s read's would end at twice what it needs).
    public init(sampleRate: Double, offsetHz: Double, bandwidthHz: Double, sharp: Bool = true,
                expectedInputFrames: Int = 0) {
        let (stages, rate) = Channel.plan(sampleRate: sampleRate, bandwidthHz: bandwidthHz, sharp: sharp)
        self.stages = stages
        self.rate = rate
        decimators = stages.map { ComplexDecimator(taps: $0.taps, factor: $0.factor) }
        mixer = BlockMixer(frequency: -offsetHz, sampleRate: sampleRate)
        block = [DSPComplex](repeating: DSPComplex(real: 0, imag: 0), count: BlockMixer.blockSize)
        taken = Array(repeating: 0, count: stages.count)
        toSkip = stages.map { ($0.taps.count - 1) / 2 / $0.factor }
        passed = Array(repeating: 0, count: stages.count)
        scratch = Array(repeating: [], count: stages.count)
        reserve(inputFrames: expectedInputFrames)
    }

    /// Sizes the output for `inputFrames` fed in all (see `init`).
    public func reserve(inputFrames: Int) {
        guard inputFrames > 0 else { return }
        let factor = stages.reduce(1) { $0 * $1.factor }
        reservedFloats = 2 * (inputFrames / factor + stages.count + 1)
        samples.reserveCapacity(reservedFloats)
    }

    /// The output size reserved, in floats (`capacity` may show more: the allocator can hand back a larger free
    /// block).
    public private(set) var reservedFloats = 0
    /// The output outgrew what was reserved (and so was reallocated, growing by doubling).
    public private(set) var outgrewReservation = false

    /// The next piece of interleaved IQ.
    public func feed(_ iq: UnsafeBufferPointer<Float>) {
        let n = iq.count / 2
        guard n > 0, let base = iq.baseAddress else { return }
        base.withMemoryRebound(to: DSPComplex.self, capacity: n) { z in
            var start = 0
            while start < n {
                let m = min(BlockMixer.blockSize - blockFill, n - start)
                block.withUnsafeMutableBufferPointer { b in (b.baseAddress! + blockFill).update(from: z + start, count: m) }
                blockFill += m
                start += m
                if blockFill == BlockMixer.blockSize { mixBlock() }
            }
        }
    }

    /// The output: every piece fed, the filters' tails flushed. The extractor is spent afterwards.
    public func finish() -> (samples: [Float], rate: Double) {
        if blockFill > 0 { mixBlock() }
        for s in stages.indices {
            // As `Stage.run`: zeros through the filter for its delay, the output cut to one per `factor` inputs.
            let zeros = [DSPComplex](repeating: DSPComplex(real: 0, imag: 0),
                                     count: (stages[s].taps.count - 1) / 2 + stages[s].factor)
            scratch[s].removeAll(keepingCapacity: true)
            zeros.withUnsafeBufferPointer { decimators[s].process($0, into: &scratch[s]) }
            deliver(s, limit: (taken[s] + stages[s].factor - 1) / stages[s].factor)
        }
        defer { samples = [] }
        return (samples, rate)
    }

    private func mixBlock() {
        block.withUnsafeMutableBufferPointer { b in
            mixer.mix(b.baseAddress!, count: blockFill)
            run(0, UnsafeBufferPointer(rebasing: b[0..<blockFill]))
        }
        blockFill = 0
    }

    private func run(_ s: Int, _ x: UnsafeBufferPointer<DSPComplex>) {
        taken[s] += x.count
        scratch[s].removeAll(keepingCapacity: true)
        decimators[s].process(x, into: &scratch[s])
        deliver(s)
    }

    /// Stage `s`'s new outputs, less its delay, to the next stage (or the output): at most `limit` in all.
    private func deliver(_ s: Int, limit: Int = .max) {
        var out = scratch[s][...]
        let drop = min(toSkip[s], out.count)
        toSkip[s] -= drop
        out = out.dropFirst(drop).prefix(max(0, limit - passed[s]))
        passed[s] += out.count
        guard !out.isEmpty else { return }
        out.withUnsafeBufferPointer { p in
            if s + 1 < stages.count {
                run(s + 1, p)
            } else {
                p.baseAddress!.withMemoryRebound(to: Float.self, capacity: 2 * p.count) {
                    samples.append(contentsOf: UnsafeBufferPointer(start: $0, count: 2 * p.count))
                    if samples.count > reservedFloats { outgrewReservation = true }
                }
            }
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
