import AppKit
import DSPCore
import SwiftUI

@main
struct SubFloorApp: App {
    @State private var engine = EngineSmokeTest()

    init() { NSApplication.shared.setActivationPolicy(.regular) }

    var body: some Scene {
        WindowGroup("SubFloor") {
            Text("Engine smoke test — you should hear a 1 kHz USB tone (14.200 MHz demo signal).")
                .padding(40)
                .onAppear { engine.start() }
        }
    }
}

@MainActor @Observable
final class EngineSmokeTest {
    let engine = DSPEngine()
    let source = SyntheticSource(centerFrequency: 14_100_000)

    func start() {
        let rx = Receiver.Config(inputRate: source.sampleRate, offsetHz: 100_000, mode: .usb, bandwidthHz: 2_700)
        do {
            try engine.start(source: source, receiver: rx, spectrum: SpectrumSettings(), volume: 0.4)
        } catch {
            print("Engine start failed: \(error)")
        }
    }
}
