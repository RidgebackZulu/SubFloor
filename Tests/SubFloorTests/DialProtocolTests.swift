import DSPCore
import Foundation
import SubFloorCore
import Testing
@testable import SubFloor

struct DialProtocolTests {
    @Test func parsesTheDialsEvents() {
        #expect(DialProtocol.parse("HELLO SubFloorDial 1.0.0 step=100 knob=tune")
                == .hello(firmware: "1.0.0", stepHz: 100, knob: .tune))
        #expect(DialProtocol.parse("HELLO SubFloorDial 1.0.0 step=10 knob=bw")
                == .hello(firmware: "1.0.0", stepHz: 10, knob: .bandwidth))
        #expect(DialProtocol.parse("T 12 -3 1000") == .tune(seq: 12, steps: -3, stepHz: 1000))
        #expect(DialProtocol.parse("B 2") == .bandwidth(steps: 2))
        #expect(DialProtocol.parse("STEP 10") == .step(hz: 10))
        #expect(DialProtocol.parse("M LSB") == .mode(.lsb))
        #expect(DialProtocol.parse("M am") == .mode(.am))
        #expect(DialProtocol.parse("KNOB bw") == .knob(.bandwidth))
        #expect(DialProtocol.parse("PONG") == .pong)
    }

    @Test func rejectsWhatIsNotTheDial() {
        #expect(DialProtocol.parse("") == nil)
        #expect(DialProtocol.parse("HELLO SomethingElse 1") == nil)
        #expect(DialProtocol.parse("ORCDIAL_STATUS link=OFFLINE freq=146520000") == nil)
        #expect(DialProtocol.parse("T 1 2") == nil)
        #expect(DialProtocol.parse("T 1 2 0") == nil, "a zero step would divide by zero")
        #expect(DialProtocol.parse("M XYZ") == nil)
        #expect(DialProtocol.parse("STEP -5") == nil)
    }

    @Test func formatsWhatSubFloorSends() {
        #expect(DialProtocol.frequency(14_074_000) == "F 14074000")
        #expect(DialProtocol.frequency(7_074_400.4, seq: 9) == "F 7074400 9")
        #expect(DialProtocol.state(vfoHz: 7_074_000, mode: .lsb, bandwidthHz: 2_400, running: true)
                == "S f=7074000 m=LSB bw=2400 run=1")
        #expect(DialProtocol.mode(.usb) == "M USB")
        #expect(DialProtocol.bandwidth(8_000) == "BW 8000")
        #expect(DialProtocol.signal(-68.04) == "SIG -68.0")
        #expect(DialProtocol.signal(-.infinity) == "SIG -200.0")
        #expect(DialProtocol.hello(host: "War's Mac\nPro") == "HELLO SubFloor 1 host=War's Mac Pro")
    }

    @Test func splitsLinesAcrossChunks() {
        var s = LineSplitter()
        #expect(s.append(Data("HELLO Sub".utf8)).isEmpty)
        #expect(s.append(Data("FloorDial 1.0.0\r\nT 1 2 ".utf8)) == ["HELLO SubFloorDial 1.0.0"])
        #expect(s.append(Data("100\n\nPONG\n".utf8)) == ["T 1 2 100", "PONG"])
    }
}

/// The dial's knob on a hermetic model (never started).
@MainActor
struct AppModelDialTests {
    private func makeModel() -> AppModel {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SubFloorTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return AppModel(bookmarkStore: BookmarkStore(url: dir.appendingPathComponent("bookmarks.json")),
                        defaults: UserDefaults(suiteName: UUID().uuidString)!)
    }

    @Test func stepsFromTheStepsGrid() {
        let m = makeModel()
        m.setVFO(7_074_123)
        m.stepVFO(3, stepHz: 100)
        #expect(m.vfoHz == 7_074_400, "snapped to 7 074 100, then three 100 Hz steps")
        m.stepVFO(-1, stepHz: 1)
        #expect(m.vfoHz == 7_074_399)
        m.stepVFO(1, stepHz: 1_000)
        #expect(m.vfoHz == 7_075_000)
        m.stepVFO(5, stepHz: 0)
        #expect(m.vfoHz == 7_075_000, "a zero step is ignored")
    }

    @Test func bandwidthStepsAreTheModes() {
        let m = makeModel()
        m.setMode(.usb)
        let before = m.bandwidthHz
        m.stepBandwidth(2)
        #expect(m.bandwidthHz == before + 2 * DemodMode.usb.bandwidthStep)
        m.stepBandwidth(-10_000)
        #expect(m.bandwidthHz == DemodMode.usb.bandwidthRange.lowerBound, "clamped")
    }
}
