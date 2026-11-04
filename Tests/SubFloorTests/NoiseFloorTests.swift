import DSPCore
import Foundation
import SDRplayKit
import SubFloorCore
import Testing
@testable import SubFloor

/// Quiet-spot picking on synthetic snapshots, and the floor measurement on the fake RSP (Task 7's seam): AM 0.05 at
/// 10 MHz over noise 0.001. Without an audio device the engine cannot start and those tests are skipped.
@MainActor
@Suite(.serialized)
struct NoiseFloorTests {
    private func flat(peaks: [Int: Float] = [:]) -> SpectrumSnapshot {
        // 1000 bins of 1 kHz around 10 MHz, -100 dBFS with a little ripple.
        var a = (0..<1000).map { Float(-100) + Float($0 % 3) * 0.5 }
        for (i, v) in peaks { a[i] = v }
        return SpectrumSnapshot(centerHz: 10_000_000, spanHz: 1_000_000, average: a)
    }

    @Test func quietSpotsAvoidPeaks() {
        let s = flat(peaks: [510: -60, 490: -60])   // bins 510/490 are about ±10 kHz of the bin at 500
        let hz = s.hz(ofBin: 500)
        let spots = QuietSpots.pick(s, around: hz, bandwidthHz: 5_000, count: 6)
        #expect(!spots.isEmpty)
        for spot in spots {
            #expect(abs(spot - s.hz(ofBin: 510)) >= 5_000)
            #expect(abs(spot - s.hz(ofBin: 490)) >= 5_000)
            #expect(abs(spot - hz) >= 5_000)
        }
        for (i, a) in spots.enumerated() { for b in spots[(i + 1)...] { #expect(abs(a - b) >= 5_000) } }
    }

    @Test func quietSpotsNearestFirst() {
        let s = flat()
        let hz = s.hz(ofBin: 500)
        let spots = QuietSpots.pick(s, around: hz, bandwidthHz: 5_000, count: 3)
        #expect(spots.count == 3)
        #expect(spots == spots.sorted { abs($0 - hz) < abs($1 - hz) })
        #expect(abs(spots[0] - hz) <= 5_000 + 1_000)
    }

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SubFloorNoiseFloor-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A model on the fake RSP, tuned to 10 MHz in AM, with a spectrum frame; nil without an audio device.
    private func runningModel() async -> AppModel? {
        let dir = tempDir()
        let rsp = SyntheticSource(signals: [.init(frequency: 10_000_000, amplitude: 0.05, kind: .am(toneHz: 1_000))])
        let m = AppModel(bookmarkStore: BookmarkStore(url: dir.appendingPathComponent("bookmarks.json")),
                         defaults: UserDefaults(suiteName: UUID().uuidString)!,
                         openRSP: { throw SDRplayError.noDevice }, rspOpenTimeout: .seconds(2),
                         decodeHistoryFolder: dir.appendingPathComponent("decodes"), fakeRSP: rsp)
        m.recording.folderPath = dir.appendingPathComponent("rec").path
        m.useSource(.sdrplay)
        if !m.isRunning { m.start() }
        guard m.isRunning else {
            print("engine did not start (tolerated, no audio device)")
            m.shutdown()
            return nil
        }
        for _ in 0..<100 where !(m.isRunning && m.sourceKind == .sdrplay) { try? await Task.sleep(for: .milliseconds(50)) }
        m.setMode(.am)
        m.setBandwidth(5_000)
        m.tune(to: 10_000_000)
        for _ in 0..<200 where m.spectrumSnapshot() == nil { try? await Task.sleep(for: .milliseconds(50)) }
        guard m.isRunning, m.sourceKind == .sdrplay, m.spectrumSnapshot() != nil else { m.shutdown(); return nil }
        return m
    }

    /// The same measure on a frequency with no signal near it: the median of the engine's reads after settling.
    private func reference(_ m: AppModel, at hz: Double) async -> Float {
        m.setVFO(hz)
        try? await Task.sleep(for: .milliseconds(500))
        var reads: [Float] = []
        for _ in 0..<5 {
            reads.append(m.engine.stats.withLock { $0.signalDb })
            try? await Task.sleep(for: .milliseconds(100))
        }
        return reads.sorted()[reads.count / 2]
    }

    @Test func floorMatchesAKnownNoiseLevel() async {
        guard let m = await runningModel() else { return }
        defer { m.shutdown() }
        let ref = await reference(m, at: 10_300_000)
        let floor = await m.measureNoiseFloor(near: 10_300_000, spotSeconds: 1)
        #expect(floor != nil)
        if let floor { #expect(abs(floor - ref) < 2) }
    }

    @Test func aStationOnAirDoesNotRaiseTheFloor() async {
        guard let m = await runningModel() else { return }
        defer { m.shutdown() }
        let ref = await reference(m, at: 10_300_000)
        m.setVFO(10_000_000)
        let floor = await m.measureNoiseFloor(near: 10_000_000, spotSeconds: 1)
        #expect(floor != nil)
        if let floor { #expect(abs(floor - ref) < 2) }
    }

    @Test func vfoReturnsToTheFrequency() async {
        guard let m = await runningModel() else { return }
        defer { m.shutdown() }
        m.setVFO(10_000_000)
        let before = m.vfoHz
        _ = await m.measureNoiseFloor(near: before, spotSeconds: 1)
        #expect(m.vfoHz == before)
    }
}
