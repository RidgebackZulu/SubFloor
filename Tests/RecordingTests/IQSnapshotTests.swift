import Foundation
import Synchronization
import Testing
@testable import Recording

@Suite struct IQSnapshotTests {
    private final class Reading: Sendable {
        let done = Atomic<Bool>(false)
        let snapshots = Atomic<Int>(0)
    }

    private func makeIQ(rate: Double = 1_000_000, format: SampleFormat = .int16, preRoll: Double = 30) -> StreamRecorder {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("IQSnapshotTests-\(UUID().uuidString)", isDirectory: true)
        let r = StreamRecorder(kind: .iq, rollsOnContextChange: true)
        r.configure(StreamRecorder.Setup(sampleRate: rate, channels: 2, fileFormat: .wav, sampleFormat: format,
                                         preRollSeconds: preRoll, memoryLimitBytes: 2 << 30, folder: dir))
        return r
    }

    /// Frames `range` of IQ, frame k being (`i(k)`, `q(k)`), pushed in 100k-frame blocks as the DSP thread would.
    private func push(_ r: StreamRecorder, frames range: Range<Int>, i: (Int) -> Float, q: (Int) -> Float) {
        var block: [Float] = []
        block.reserveCapacity(200_000)
        for start in stride(from: range.lowerBound, to: range.upperBound, by: 100_000) {
            block.removeAll(keepingCapacity: true)
            for k in start..<min(start + 100_000, range.upperBound) {
                block.append(i(k))
                block.append(q(k))
            }
            block.withUnsafeBufferPointer { r.push($0) }
        }
    }

    private func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            Thread.sleep(forTimeInterval: 0.002)
        }
        return true
    }

    @Test func snapshotReturnsTheNewestFrames() throws {
        let r = makeIQ()
        defer { r.shutdown() }
        let total = 4_000_000
        func ramp(_ k: Int) -> Float { Float(k) / Float(total) }
        push(r, frames: 0..<total, i: ramp, q: { -ramp($0) })
        let s = try #require(r.snapshot(lastSeconds: 3))
        #expect(s.frames == 3_000_000)
        #expect(s.sampleRate == 1_000_000)
        let lsb: Float = 1.0 / 32_767
        #expect(abs(s.samples[0] - ramp(1_000_000)) <= lsb)
        #expect(abs(s.samples[1] + ramp(1_000_000)) <= lsb)
        #expect(abs(s.samples[s.samples.count - 2] - ramp(total - 1)) <= lsb)
        #expect(abs(s.samples[s.samples.count - 1] + ramp(total - 1)) <= lsb)
        #expect(abs(s.endTime.timeIntervalSinceNow) < 5)
    }

    @Test func snapshotStopsAtTheRetune() throws {
        let r = makeIQ()
        defer { r.shutdown() }
        r.setContext(RecordingContext(frequencyHz: 14_100_000, label: "IQ", hardware: "test"))
        push(r, frames: 0..<2_000_000, i: { _ in 0.25 }, q: { _ in 0.25 })
        r.setContext(RecordingContext(frequencyHz: 7_100_000, label: "IQ", hardware: "test"))
        #expect(r.snapshot(lastSeconds: 3) == nil)   // nothing heard since the retune
        push(r, frames: 0..<500_000, i: { _ in -0.5 }, q: { _ in -0.5 })
        let s = try #require(r.snapshot(lastSeconds: 3))
        #expect(s.frames == 500_000)
        #expect(s.samples.allSatisfy { abs($0 + 0.5) <= 1e-4 })
        // `clearHistory` is a barrier too.
        r.clearHistory()
        push(r, frames: 0..<1_000, i: { _ in 0 }, q: { _ in 0 })
        #expect(r.snapshot(lastSeconds: 3)?.frames == 1_000)
    }

    @Test(arguments: [(SampleFormat.int16, Float(1e-4)), (.int24, 1e-6), (.float32, 1e-6)])
    func snapshotConvertsEachFormat(format: SampleFormat, tolerance: Float) throws {
        let r = makeIQ(rate: 10_000, format: format)
        defer { r.shutdown() }
        push(r, frames: 0..<5_000, i: { _ in 0.5 }, q: { _ in -0.5 })
        let s = try #require(r.snapshot(lastSeconds: 1))
        #expect(s.frames == 5_000)
        #expect(stride(from: 0, to: s.samples.count, by: 2).allSatisfy {
            abs(s.samples[$0] - 0.5) <= tolerance && abs(s.samples[$0 + 1] + 0.5) <= tolerance
        })
    }

    @Test func ringCopiesTheNewestAcrossTheWrapWithoutMovingTheReader() {
        let ring = HistoryRing()
        ring.reset(capacity: 12, bytesPerFrame: 2)
        Array<UInt8>(0..<18).withUnsafeBytes { ring.push($0) }   // holds 6..<18, wrapped at 12
        var position = ring.rewind(bytes: 4)
        var out = [UInt8](repeating: 0, count: 9)
        #expect(out.withUnsafeMutableBytes { ring.copyNewest(into: $0) } == 8)   // whole frames only
        #expect(Array(out[0..<8]) == Array(10..<18))
        out = [UInt8](repeating: 0, count: 100)
        #expect(out.withUnsafeMutableBytes { ring.copyNewest(into: $0) } == 12)   // no older than the oldest
        #expect(Array(out[0..<12]) == Array(6..<18))
        ring.clear()
        Array<UInt8>(18..<22).withUnsafeBytes { ring.push($0) }
        #expect(out.withUnsafeMutableBytes { ring.copyNewest(into: $0) } == 4)   // no older than the barrier
        #expect(Array(out[0..<4]) == Array(18..<22))
        var read = [UInt8](repeating: 0, count: 100)
        #expect(read.withUnsafeMutableBytes { ring.read(from: &position, into: $0) }.read == 8)   // the reader is where it was
        #expect(Array(read[0..<8]) == Array(14..<22))
    }

    @Test func snapshotIsNilWhenEmpty() {
        let unconfigured = StreamRecorder(kind: .iq, rollsOnContextChange: true)
        defer { unconfigured.shutdown() }
        #expect(unconfigured.snapshot(lastSeconds: 3) == nil)
        let r = makeIQ()
        defer { r.shutdown() }
        #expect(r.snapshot(lastSeconds: 3) == nil)
        #expect(r.snapshot(lastSeconds: 0) == nil)
    }

    @Test func snapshotDoesNotDisturbARecording() throws {
        let r = makeIQ(rate: 10_000, format: .float32, preRoll: 5)
        defer { r.shutdown() }
        r.setContext(RecordingContext(frequencyHz: 14_100_000, label: "IQ", hardware: "test"))
        let index: (Int) -> Float = { Float($0) }
        push(r, frames: 0..<20_000, i: index, q: index)   // 2 s of pre-roll
        r.start()
        #expect(waitUntil { r.status.url != nil })

        // A second thread snapshots throughout, as Signal ID would.
        let reading = Reading()
        let reader = Thread { [r] in
            while !reading.done.load(ordering: .acquiring) {
                if r.snapshot(lastSeconds: 3) != nil { reading.snapshots.add(1, ordering: .relaxed) }
            }
        }
        reader.start()
        var newest = 19_999
        for start in stride(from: 20_000, to: 60_000, by: 1_000) {
            push(r, frames: start..<(start + 1_000), i: index, q: index)
            newest = start + 999
            let s = try #require(r.snapshot(lastSeconds: 1))
            #expect(s.frames == 10_000)
            #expect(s.samples.last == Float(newest))
            #expect(s.samples.first == Float(newest - 9_999))
        }
        reading.done.store(true, ordering: .releasing)
        r.stop(wait: true)
        #expect(reading.snapshots.load(ordering: .relaxed) > 0)

        let status = r.status
        #expect(status.error == nil && status.overrunBytes == 0)
        #expect(status.framesWritten == 60_000)
        let url = try #require(status.url)
        let data = try Data(contentsOf: url)
        let n = (data.count - 44) / 4
        let file = data[44...].withUnsafeBytes { raw in (0..<n).map { raw.loadUnaligned(fromByteOffset: $0 * 4, as: Float.self) } }
        #expect(file.count == 2 * 60_000)
        #expect(stride(from: 0, to: file.count, by: 2).allSatisfy { file[$0] == Float($0 / 2) && file[$0 + 1] == Float($0 / 2) })
    }
}
