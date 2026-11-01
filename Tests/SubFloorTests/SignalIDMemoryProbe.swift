import Accelerate
import Darwin
import Foundation
import Recording
import SDRplayKit
import SignalID
import SubFloorCore
import Synchronization
import Testing
@testable import SubFloor

/// I1's memory, measured: one identification of a carrier at the RSP1B's 10 MS/s, through a real recorder's ring
/// (int16, as the app's IQ ring, 3.2 s pushed) and the real identifier, the process's physical footprint sampled
/// every millisecond while it runs. Prints the peak over the footprint before it began (the ring already filled) and
/// holds it under 100 MB. Only with `SUBFLOOR_SIGNALID_MEMORY=1`, and run alone (`--filter SignalIDMemoryProbe`):
/// the footprint is the whole process's, so tests beside it would count. The default run pins the same bound by
/// accounting (`SignalIDServiceTests.aTenMSsIdentificationStaysSmall`).
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["SUBFLOOR_SIGNALID_MEMORY"] == "1"))
struct SignalIDMemoryProbe {
    /// The process's physical footprint, in bytes.
    nonisolated static func footprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }

    @Test func tenMSsPeak() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SubFloorMemory-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let m = AppModel(bookmarkStore: BookmarkStore(url: dir.appendingPathComponent("bookmarks.json")),
                         defaults: UserDefaults(suiteName: UUID().uuidString)!,
                         openRSP: { throw SDRplayError.noDevice }, decodeHistoryFolder: dir)
        m.useSource(.synthetic)
        defer { m.shutdown() }
        guard m.isRunning else { return }

        let fs = 10_000_000.0, toneHz = 1_234_560.0, block = 1_000_000
        let r = StreamRecorder(kind: .iq, rollsOnContextChange: true)
        r.configure(StreamRecorder.Setup(sampleRate: fs, channels: 2, fileFormat: .wav, sampleFormat: .int16,
                                         preRollSeconds: 5, memoryLimitBytes: 2 << 30, folder: dir))
        var tone = [Float](repeating: 0, count: 2 * block)
        for k in 0..<block {
            let phase = 2 * Double.pi * toneHz * Double(k) / fs
            tone[2 * k] = Float(0.1 * cos(phase))
            tone[2 * k + 1] = Float(0.1 * sin(phase))
        }
        var noise = [Int16](repeating: 0, count: 2 * block), piece = [Float](repeating: 0, count: 2 * block)
        for _ in 0..<32 {
            noise.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, $0.count) }
            vDSP_vflt16(noise, 1, &piece, 1, vDSP_Length(2 * block))
            var scale = Float(0.1 / 32768)
            vDSP_vsmul(piece, 1, &scale, &piece, 1, vDSP_Length(2 * block))
            vDSP_vadd(piece, 1, tone, 1, &piece, 1, vDSP_Length(2 * block))
            piece.withUnsafeBufferPointer { r.push($0) }
        }
        tone = []
        noise = []
        piece = []
        m.signalID.attach(to: m, recorder: r)

        let before = Self.footprint()
        let peak = Mutex(before), done = Atomic<Bool>(false)
        let sampler = Thread {
            while !done.load(ordering: .relaxed) {
                let now = Self.footprint()
                peak.withLock { $0 = max($0, now) }
                usleep(1000)
            }
        }
        sampler.start()
        let clock = ContinuousClock(), start = clock.now
        let id = await m.signalID.identify(atHz: m.centerHz + toneHz)
        let elapsed = clock.now - start
        done.store(true, ordering: .relaxed)
        try await Task.sleep(for: .milliseconds(20))
        let extra = Double(peak.withLock { $0 } - before) / 1_048_576
        print(String(format: "SignalIDMemoryProbe: 10 MS/s, one identification: peak %.0f MB over %.0f MB before, in %@: %@",
                     extra, Double(before) / 1_048_576, "\(elapsed)", id?.label ?? "nil"))
        #expect(id?.measurement.family == .carrier, "\(id?.label ?? "nil")")
        #expect(extra <= 100, "peak \(extra) MB")
    }
}
