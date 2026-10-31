import DSPCore
import Foundation
import Testing
@testable import SubFloor

/// The engine's audio tap: the last minute of the receiver's ungated audio and how long the gate was open.
struct AudioTapTests {
    /// Pushes `seconds` of a 48 kHz ramp (sample i is i) in 4800-sample blocks, every other one with the gate open.
    private func pushRamp(_ tap: AudioTap, seconds: Double, from first: Int = 0) -> Int {
        let block = 4_800, blocks = Int(seconds * Receiver.audioRate) / block
        var buffer = [Float](repeating: 0, count: block)
        for b in 0..<blocks {
            for i in 0..<block { buffer[i] = Float(first + b * block + i) }
            buffer.withUnsafeBufferPointer { tap.push($0, gateOpen: b % 2 == 0) }
        }
        return first + blocks * block
    }

    @Test func keepsTheLastSecondsAndCountsOpenTime() {
        let tap = AudioTap()
        let start = tap.mark()
        let pushed = pushRamp(tap, seconds: 70)
        let samples = tap.samples(since: start)
        #expect(samples.count == 60 * 48_000)
        #expect(samples.last == Float(pushed - 1))
        #expect(samples.first == Float(pushed - 60 * 48_000))
        #expect(abs(tap.openSeconds(since: start) - 35) < 0.2)
    }

    @Test func aMarkSeesOnlyWhatCameAfterIt() {
        let tap = AudioTap(seconds: 10)
        let pushed = pushRamp(tap, seconds: 2)
        let mark = tap.mark()
        #expect(tap.samples(since: mark).isEmpty)
        #expect(tap.openSeconds(since: mark) == 0)
        _ = pushRamp(tap, seconds: 1, from: pushed)
        let after = tap.samples(since: mark)
        #expect(after.count == 48_000)
        #expect(after.first == Float(pushed))
    }

    @Test func clearDropsWhatAnEarlierMarkWouldSee() {
        let tap = AudioTap(seconds: 10)
        let mark = tap.mark()
        let pushed = pushRamp(tap, seconds: 1)
        tap.clear()
        #expect(tap.samples(since: mark).isEmpty)
        _ = pushRamp(tap, seconds: 0.5, from: pushed)
        let after = tap.samples(since: mark)
        #expect(after.count == 24_000)
        #expect(after.first == Float(pushed))
    }
}
