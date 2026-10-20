import Testing
import Foundation
@testable import Modems

// Published reference vectors. Sources (all public; no WSJT-X or wsprd source was read):
// - "K1ABC FN42 37": the verbatim output of WSJT-X 2.7.0's `wsprcode` utility, published in
//   https://github.com/agamez/whisperice/blob/main/reference/test_vectors/k1abc_fn42_37.txt (MIT).
// - "LZ0DLS KN12 10": https://github.com/LZ1NY/LZ0DLS (README, the beacon's message listing).
// - "W8ZLW AA00 3": https://github.com/swharden/WsprSharp/blob/main/dev/WsprNetVB/readme.md (MIT).
// - "AJ4VD EL89 3": https://github.com/swharden/WsprSharp/blob/main/README.md (MIT), quickstart output.
// The G4JNT document's own K1ABC example (http://g4jnt.com/WSPR_Coding_Process.pdf) could not be
// fetched from the build container, so the K1ABC vector comes from the published wsprcode listing.

private let k1abcBytes: [UInt8] = [0xF7, 0x0C, 0x23, 0x8B, 0x0D, 0x19, 0x40]
private let k1abcSymbols: [UInt8] = [
    3, 3, 0, 0, 2, 0, 0, 0, 1, 0, 2, 0, 1, 3, 1, 2, 2, 2, 1, 0, 0, 3, 2, 3, 1, 3, 3, 2, 2, 0,
    2, 0, 0, 0, 3, 2, 0, 1, 2, 3, 2, 2, 0, 0, 2, 2, 3, 2, 1, 1, 0, 2, 3, 3, 2, 1, 0, 2, 2, 1,
    3, 2, 1, 2, 2, 2, 0, 3, 3, 0, 3, 0, 3, 0, 1, 2, 1, 0, 2, 1, 2, 0, 3, 2, 1, 3, 2, 0, 0, 3,
    3, 2, 3, 0, 3, 2, 2, 0, 3, 0, 2, 0, 2, 0, 1, 0, 2, 3, 0, 2, 1, 1, 1, 2, 3, 3, 0, 2, 3, 1,
    2, 1, 2, 2, 2, 1, 3, 3, 2, 0, 0, 0, 0, 1, 0, 3, 2, 0, 1, 3, 2, 2, 2, 2, 2, 0, 2, 3, 3, 2,
    3, 2, 3, 3, 2, 0, 0, 3, 1, 2, 2, 2,
]

private let lz0dlsSymbols: [UInt8] = [
    3, 3, 0, 0, 2, 0, 0, 0, 1, 0, 0, 0, 3, 1, 1, 0, 2, 0, 3, 2, 0, 1, 0, 3, 3, 3, 1, 2, 2, 2,
    0, 2, 2, 0, 3, 2, 2, 3, 2, 1, 2, 2, 2, 2, 2, 0, 1, 0, 3, 3, 0, 0, 3, 1, 0, 3, 0, 2, 2, 3,
    3, 2, 3, 0, 0, 0, 0, 1, 3, 2, 1, 2, 1, 2, 3, 2, 1, 2, 0, 1, 2, 0, 1, 2, 1, 3, 0, 0, 0, 1,
    3, 2, 3, 2, 3, 2, 2, 0, 3, 0, 0, 0, 0, 0, 3, 0, 2, 1, 0, 0, 1, 3, 3, 2, 1, 1, 0, 0, 1, 3,
    2, 3, 2, 2, 2, 1, 1, 1, 2, 0, 0, 2, 2, 3, 0, 3, 2, 0, 3, 1, 0, 2, 0, 2, 2, 0, 0, 1, 1, 0,
    3, 0, 1, 3, 2, 0, 0, 3, 3, 2, 0, 0,
]

private let w8zlwSymbols: [UInt8] = [
    3, 1, 2, 2, 0, 0, 0, 0, 1, 0, 0, 0, 3, 3, 3, 2, 2, 2, 1, 0, 0, 1, 0, 3, 3, 3, 1, 0, 2, 2,
    2, 0, 0, 0, 3, 2, 2, 1, 2, 3, 2, 2, 2, 0, 0, 0, 3, 2, 3, 3, 2, 2, 3, 1, 0, 1, 2, 0, 2, 3,
    1, 0, 1, 2, 2, 0, 2, 1, 3, 2, 1, 0, 1, 0, 1, 2, 1, 0, 0, 1, 0, 2, 3, 2, 1, 1, 2, 0, 0, 3,
    3, 2, 1, 2, 3, 0, 2, 0, 3, 2, 2, 2, 2, 0, 1, 2, 2, 3, 0, 2, 3, 1, 3, 0, 3, 1, 2, 0, 1, 3,
    0, 1, 0, 0, 0, 1, 3, 3, 2, 0, 0, 0, 0, 1, 0, 1, 0, 0, 3, 3, 2, 2, 0, 0, 2, 2, 2, 1, 1, 2,
    3, 0, 1, 1, 2, 0, 2, 3, 3, 0, 2, 0,
]

private let aj4vdSymbols: [UInt8] = [
    1, 3, 2, 0, 2, 2, 2, 2, 3, 0, 2, 0, 3, 1, 3, 2, 0, 0, 1, 2, 2, 3, 0, 1, 1, 3, 3, 0, 0, 0,
    2, 0, 2, 0, 1, 0, 0, 3, 0, 3, 0, 2, 0, 0, 0, 2, 1, 2, 1, 3, 2, 2, 3, 3, 2, 1, 2, 0, 2, 3,
    1, 0, 1, 2, 2, 0, 2, 1, 1, 0, 1, 0, 1, 0, 1, 0, 1, 2, 2, 1, 0, 2, 1, 2, 1, 3, 0, 0, 0, 3,
    1, 2, 3, 0, 1, 0, 2, 2, 1, 0, 2, 0, 2, 2, 1, 2, 0, 3, 2, 2, 3, 1, 1, 2, 3, 3, 2, 0, 1, 3,
    2, 1, 0, 2, 2, 3, 1, 3, 0, 0, 2, 0, 2, 1, 0, 3, 2, 0, 1, 3, 0, 2, 2, 0, 2, 0, 2, 3, 1, 2,
    3, 0, 1, 3, 0, 2, 2, 3, 3, 0, 0, 0,
]

/// The sync vector as printed in the published listings above (all four agree bit for bit).
private let publishedSync: [UInt8] = [
    1, 1, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 1, 1, 1, 0, 0, 0, 1, 0, 0, 1, 0, 1, 1, 1, 1, 0, 0, 0,
    0, 0, 0, 0, 1, 0, 0, 1, 0, 1, 0, 0, 0, 0, 0, 0, 1, 0, 1, 1, 0, 0, 1, 1, 0, 1, 0, 0, 0, 1,
    1, 0, 1, 0, 0, 0, 0, 1, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 0, 1, 0, 0, 1, 0, 1, 1, 0, 0, 0, 1,
    1, 0, 1, 0, 1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 1, 0, 0, 1, 1, 1, 0, 1, 1, 0, 0, 1, 1,
    0, 1, 0, 0, 0, 1, 1, 1, 0, 0, 0, 0, 0, 1, 0, 1, 0, 0, 1, 1, 0, 0, 0, 0, 0, 0, 0, 1, 1, 0,
    1, 0, 1, 1, 0, 0, 0, 1, 1, 0, 0, 0,
]

/// Small deterministic generator for bit flips and trial seeds.
private struct TestRNG {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Results of parallel jobs, filled under a lock.
private final class ResultBox<T>: @unchecked Sendable {
    var items: [T?]
    let lock = NSLock()
    init(_ n: Int) { items = Array(repeating: nil, count: n) }
}

/// Runs `count` independent jobs on all cores and returns their results in order.
private func parallel<T>(_ count: Int, _ job: @Sendable (Int) -> T) -> [T] {
    let box = ResultBox<T>(count)
    DispatchQueue.concurrentPerform(iterations: count) { i in
        let r = job(i)
        box.lock.lock(); box.items[i] = r; box.lock.unlock()
    }
    return box.items.map { $0! }
}

/// Code bits as hard-decision soft metrics: +1 for a 1, −1 for a 0.
private func hardSoft(_ bits: [UInt8]) -> [Float] { bits.map { $0 == 1 ? 1 : -1 } }

/// BPSK soft symbols ±1 plus Gaussian noise at `ebN0Db`, with Eb/N0 counted at the code rate
/// R = 1/2 (Es/N0 = Eb/N0 − 3 dB, σ² = 1 / (2·R·Eb/N0)).
private func noisySoft(_ bits: [UInt8], ebN0Db: Double, seed: UInt64) -> [Float] {
    let sigma = Float((1 / (2 * 0.5 * pow(10, ebN0Db / 10))).squareRoot())
    let noise = ModemTestSignals.noise(seconds: Double(bits.count), sigma: sigma, seed: seed, sampleRate: 1)
    return zip(hardSoft(bits), noise).map { $0 + $1 }
}

private let messages: [(String, String, Int)] = [("K1ABC", "FN42", 37), ("G4JNT", "IO90", 30), ("W1AW", "FN31", 23)]

@Suite struct WSPRCodecTests {
    // MARK: - Source coding

    @Test func packUnpackRoundTrip() throws {
        for (call, grid, power) in messages {
            let bytes = try #require(WSPRCodec.pack(call: call, grid: grid, powerDbm: power))
            #expect(bytes.count == 7)
            #expect(bytes[6] & 0x3F == 0)
            let back = try #require(WSPRCodec.unpack(bytes))
            #expect(back.call == call && back.grid == grid && back.powerDbm == power)
        }
        // Edge shapes: a two-character prefix, a digit-first prefix, one-letter suffix, the corner grids.
        for (call, grid, power) in [("GD4JNT", "AA00", 0), ("2E0ABC", "RR99", 60), ("K1A", "JJ55", 7),
                                    ("4X1AB", "KM72", 13)] {
            let bytes = try #require(WSPRCodec.pack(call: call, grid: grid, powerDbm: power))
            let back = try #require(WSPRCodec.unpack(bytes))
            #expect(back.call == call && back.grid == grid && back.powerDbm == power)
        }
        // Lower case is accepted and normalised.
        let lower = try #require(WSPRCodec.pack(call: "k1abc", grid: "fn42", powerDbm: 37))
        #expect(lower == k1abcBytes)
    }

    @Test func packRejectsInvalidMessages() {
        #expect(WSPRCodec.pack(call: "K1ABC/P", grid: "FN42", powerDbm: 37) == nil)  // compound (Type 2)
        #expect(WSPRCodec.pack(call: "KABC", grid: "FN42", powerDbm: 37) == nil)     // no digit
        #expect(WSPRCodec.pack(call: "K12", grid: "FN42", powerDbm: 37) == nil)      // no suffix letter
        #expect(WSPRCodec.pack(call: "K1A2", grid: "FN42", powerDbm: 37) == nil)     // digit in suffix
        #expect(WSPRCodec.pack(call: "", grid: "FN42", powerDbm: 37) == nil)
        #expect(WSPRCodec.pack(call: "K1ABC", grid: "SN42", powerDbm: 37) == nil)    // field beyond R
        #expect(WSPRCodec.pack(call: "K1ABC", grid: "FN42AB", powerDbm: 37) == nil)  // 6-char grid (Type 3)
        #expect(WSPRCodec.pack(call: "K1ABC", grid: "FN4", powerDbm: 37) == nil)
        #expect(WSPRCodec.pack(call: "K1ABC", grid: "FN42", powerDbm: 36) == nil)    // not 0/3/7 ending
        #expect(WSPRCodec.pack(call: "K1ABC", grid: "FN42", powerDbm: 63) == nil)
        #expect(WSPRCodec.pack(call: "K1ABC", grid: "FN42", powerDbm: -3) == nil)
    }

    @Test func packedBytesMatchPublishedExamples() {
        #expect(WSPRCodec.pack(call: "K1ABC", grid: "FN42", powerDbm: 37) == k1abcBytes)
        #expect(WSPRCodec.pack(call: "LZ0DLS", grid: "KN12", powerDbm: 10) == [0x94, 0x7B, 0x7B, 0x86, 0xEB, 0x92, 0x80])
        #expect(WSPRCodec.pack(call: "W8ZLW", grid: "AA00", powerDbm: 3) == [0xF9, 0x72, 0xF2, 0x8F, 0xBB, 0x90, 0xC0])
        #expect(WSPRCodec.pack(call: "AJ4VD", grid: "EL89", powerDbm: 3) == [71, 59, 134, 235, 146, 112, 192])
    }

    @Test func unpackRejectsInvalidPayloads() {
        #expect(WSPRCodec.unpack([0, 0, 0]) == nil)
        // Callsign field at or beyond 37·36·10·27³ (reserved).
        #expect(WSPRCodec.unpack([0xFF, 0xFF, 0xFF, 0xF0 | (k1abcBytes[3] & 0x0F)] + k1abcBytes[4...]) == nil)
        // Non-zero padding bits.
        #expect(WSPRCodec.unpack(Array(k1abcBytes[0..<6]) + [k1abcBytes[6] | 1]) == nil)
        // Power 38 dBm, not a Type 1 level: the power field's last two bits (weights 2 and 1) are the
        // top two bits of byte 6, so 0x40 → 0x80 turns 37 + 64 = 101 into 102.
        var bad = k1abcBytes
        bad[6] = 0x80
        #expect(WSPRCodec.unpack(bad) == nil)
    }

    // MARK: - Channel coding

    @Test func syncVectorMatchesPublished() {
        #expect(WSPRCodec.syncVector.count == 162)
        #expect(WSPRCodec.syncVector == publishedSync)
    }

    @Test func knownChannelSymbols() throws {
        let symbols = try #require(WSPRCodec.channelSymbols(call: "K1ABC", grid: "FN42", powerDbm: 37))
        #expect(symbols == k1abcSymbols)
        // Structure: every symbol is 0…3 and its low bit is the sync bit.
        #expect(symbols.allSatisfy { $0 < 4 })
        #expect(zip(symbols, WSPRCodec.syncVector).allSatisfy { $0 & 1 == $1 })
    }

    @Test func channelSymbolsMatchOtherPublishedExamples() {
        #expect(WSPRCodec.channelSymbols(call: "LZ0DLS", grid: "KN12", powerDbm: 10) == lz0dlsSymbols)
        #expect(WSPRCodec.channelSymbols(call: "W8ZLW", grid: "AA00", powerDbm: 3) == w8zlwSymbols)
        #expect(WSPRCodec.channelSymbols(call: "AJ4VD", grid: "EL89", powerDbm: 3) == aj4vdSymbols)
        #expect(WSPRCodec.channelSymbols(call: "K1ABC", grid: "FN42", powerDbm: 36) == nil)
    }

    @Test func convolveShape() {
        let bits = WSPRCodec.convolve(k1abcBytes)
        #expect(bits.count == 162)
        #expect(bits.allSatisfy { $0 <= 1 })
        // The all-zero message codes to all zeros (a linear code); a single leading 1 produces the two
        // polynomials' tap patterns, MSB (oldest stage) first: 0xF2D05351 and 0xE4613C47.
        #expect(WSPRCodec.convolve([UInt8](repeating: 0, count: 7)).allSatisfy { $0 == 0 })
        let impulse = WSPRCodec.convolve([0x80, 0, 0, 0, 0, 0, 0])
        var p1: UInt32 = 0, p2: UInt32 = 0
        for k in 0..<32 {
            p1 |= UInt32(impulse[2 * k]) << UInt32(k)
            p2 |= UInt32(impulse[2 * k + 1]) << UInt32(k)
        }
        #expect(p1 == 0xF2D0_5351 && p2 == 0xE461_3C47)
        #expect(impulse[64...].allSatisfy { $0 == 0 })
    }

    @Test func interleaveInverse() {
        var rng = TestRNG(state: 5)
        for _ in 0..<20 {
            let x = (0..<162).map { _ in UInt8(rng.next() & 1) }
            #expect(WSPRCodec.deinterleave(WSPRCodec.interleave(x)) == x)
            #expect(WSPRCodec.interleave(WSPRCodec.deinterleave(x)) == x)
        }
        // Bit-reversal addressing (G4JNT): counting 8-bit addresses up, source bit 1 goes to
        // bitrev(1) = 128 and bit 2 to bitrev(2) = 64; address 3 reverses to 192 ≥ 162 and is skipped,
        // so bit 3 goes to bitrev(4) = 32. Addresses 3, 7, 11 and 13 (→ 176) are all skipped, so bit
        // 10 lands at bitrev(14) = 112.
        func moved(_ i: Int) -> Int? {
            var x = [UInt8](repeating: 0, count: 162)
            x[i] = 1
            return WSPRCodec.interleave(x).firstIndex(of: 1)
        }
        #expect(moved(0) == 0)
        #expect(moved(1) == 128)
        #expect(moved(2) == 64)
        #expect(moved(3) == 32)
        #expect(moved(10) == 112)
        #expect(Set((0..<162).compactMap(moved)).count == 162)
    }

    // MARK: - Fano

    @Test func fanoDecodesClean() {
        for (call, grid, power) in messages + [("LZ0DLS", "KN12", 10), ("W8ZLW", "AA00", 3)] {
            let bytes = WSPRCodec.pack(call: call, grid: grid, powerDbm: power)!
            #expect(WSPRFano.decode(softSymbols: hardSoft(WSPRCodec.convolve(bytes))) == bytes)
        }
    }

    @Test func fanoCorrectsErrors() {
        let bytes = WSPRCodec.pack(call: "K1ABC", grid: "FN42", powerDbm: 37)!
        let code = WSPRCodec.convolve(bytes)
        let results = parallel(20) { trial -> Bool in
            var rng = TestRNG(state: UInt64(100 + trial))
            var bits = code
            var flipped = Set<Int>()
            while flipped.count < 10 { flipped.insert(Int(rng.next() % 162)) }
            for i in flipped { bits[i] ^= 1 }
            return WSPRFano.decode(softSymbols: hardSoft(bits)) == bytes
        }
        #expect(results.allSatisfy { $0 }, "\(results.filter { $0 }.count)/20 decoded")
    }

    @Test func fanoIsScaleInvariant() {
        let bytes = WSPRCodec.pack(call: "G4JNT", grid: "IO90", powerDbm: 30)!
        let soft = noisySoft(WSPRCodec.convolve(bytes), ebN0Db: 6, seed: 9)
        #expect(WSPRFano.decode(softSymbols: soft) == bytes)
        #expect(WSPRFano.decode(softSymbols: soft.map { $0 * 1e-3 }) == bytes)
        #expect(WSPRFano.decode(softSymbols: soft.map { $0 * 1e3 }) == bytes)
    }

    @Test func fanoRejectsBadInput() {
        #expect(WSPRFano.decode(softSymbols: [Float](repeating: 1, count: 161)) == nil)
        #expect(WSPRFano.decode(softSymbols: [Float](repeating: 0, count: 162)) == nil)
        var nan = hardSoft(WSPRCodec.convolve(k1abcBytes))
        nan[7] = .nan
        #expect(WSPRFano.decode(softSymbols: nan) == nil)
    }

    /// Soft decoding of Gaussian BPSK symbols at Eb/N0 = 3 dB (rate-1/2 convention), near the
    /// cutoff rate of sequential decoding: most frames must still decode.
    @Test func fanoSoftDecodingAtModerateNoise() {
        let bytes = WSPRCodec.pack(call: "W1AW", grid: "FN31", powerDbm: 23)!
        let code = WSPRCodec.convolve(bytes)
        let trials = 100
        // 1 = decoded, 0 = no decode, -1 = a wrong message.
        let outcome = parallel(trials) { trial -> Int in
            guard let out = WSPRFano.decode(softSymbols: noisySoft(code, ebN0Db: 3, seed: UInt64(1_000 + trial)))
            else { return 0 }
            return out == bytes ? 1 : -1
        }
        let decoded = outcome.filter { $0 == 1 }.count, wrong = outcome.filter { $0 == -1 }.count
        print("WSPR Fano at Eb/N0 3 dB: \(decoded)/\(trials) decoded, \(wrong) wrong")
        #expect(Double(decoded) / Double(trials) >= 0.8)
        #expect(wrong == 0)
    }

    /// Pure noise must almost never yield a message: at least 99% of 200 random inputs either fail
    /// to decode or fail Type 1 validation in `unpack`.
    @Test func fanoRejectsNoise() {
        let trials = 200
        let accepted = parallel(trials) { trial -> Bool in
            let soft = ModemTestSignals.noise(seconds: 162, sigma: 1, seed: UInt64(5_000 + trial), sampleRate: 1)
            guard let bytes = WSPRFano.decode(softSymbols: soft) else { return false }
            return WSPRCodec.unpack(bytes) != nil
        }
        let count = accepted.filter { $0 }.count
        print("WSPR Fano on pure noise: \(count)/\(trials) accepted")
        #expect(count <= trials / 100)
    }

    // MARK: - Encoder

    @Test func encoderToneSequence() throws {
        let audioHz = 1_500.0, rate = 12_000.0
        let audio = try #require(WSPREncoder.audio(call: "K1ABC", grid: "FN42", powerDbm: 37, audioHz: audioHz))
        #expect(audio.count == 120 * 12_000)
        let start = 12_000, n = WSPREncoder.samplesPerSymbol
        #expect(n == 8_192)
        let end = start + 162 * n
        #expect(audio[..<start].allSatisfy { $0 == 0 })
        #expect(audio[end...].allSatisfy { $0 == 0 })
        let spacing = 12_000.0 / 8_192
        // Measure each symbol's frequency: correlate the middle half against the expected tone and
        // read the frequency off the phase advance between its two quarters.
        var worst = 0.0
        for k in 0..<162 {
            let expected = audioHz + (Double(k1abcSymbols[k]) - 1.5) * spacing
            let q = n / 4
            func corr(_ from: Int) -> (Double, Double) {
                var re = 0.0, im = 0.0
                for i in from..<(from + q) {
                    let ph = 2 * Double.pi * expected * Double(i) / rate
                    re += Double(audio[i]) * cos(ph); im -= Double(audio[i]) * sin(ph)
                }
                return (re, im)
            }
            let a = corr(start + k * n + q), b = corr(start + k * n + 2 * q)
            let dphi = atan2(b.1 * a.0 - b.0 * a.1, b.0 * a.0 + b.1 * a.1)
            let measured = expected + dphi / (2 * Double.pi * Double(q) / rate)
            // Nearest tone of the four must be the published symbol.
            let tone = Int(((measured - audioHz) / spacing + 1.5).rounded())
            #expect(tone == Int(k1abcSymbols[k]), "symbol \(k)")
            worst = max(worst, abs(measured - expected))
        }
        #expect(worst < 0.01, "worst frequency error \(worst) Hz")
    }

    @Test func encoderIsPhaseContinuousAndConstantEnvelope() throws {
        let amplitude: Float = 0.5
        let audio = try #require(WSPREncoder.audio(call: "W1AW", grid: "FN31", powerDbm: 23, audioHz: 1_450,
                                                   amplitude: amplitude))
        let start = 12_000, end = start + 162 * WSPREncoder.samplesPerSymbol
        // The largest possible step of a sine at the top tone, with a little slack.
        let maxStep = amplitude * Float(2 * Double.pi * 1_455 / 12_000) * 1.01
        var worstStep: Float = 0, peak: Float = 0
        for i in (start + 1)..<end {
            worstStep = max(worstStep, abs(audio[i] - audio[i - 1]))
            peak = max(peak, abs(audio[i]))
        }
        #expect(worstStep <= maxStep)
        #expect(abs(peak - amplitude) < 1e-3)
        let power = audio[start..<end].reduce(0.0) { $0 + Double($1) * Double($1) } / Double(end - start)
        #expect(abs(power - Double(amplitude * amplitude) / 2) < 1e-4)
    }

    @Test func encoderRejectsInvalidMessage() {
        #expect(WSPREncoder.audio(call: "K1ABC/P", grid: "FN42", powerDbm: 37, audioHz: 1_500) == nil)
    }
}
