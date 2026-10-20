import AppKit
import DSPCore
import MetalKit
import SwiftUI

@main
struct SubFloorApp: App {
    @State private var engine = EngineSmokeTest()

    init() { NSApplication.shared.setActivationPolicy(.regular) }

    var body: some Scene {
        WindowGroup("SubFloor") {
            SmokeSpectrum(frames: engine.engine.frames)
                .frame(minWidth: 900, minHeight: 500)
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

struct SmokeSpectrum: NSViewRepresentable {
    let frames: SpectrumFrameStore
    final class Coordinator { var renderer: SpectrumRenderer? }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> SpectrumMTKView {
        let view = SpectrumMTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.colorPixelFormat = .bgra8Unorm
        view.preferredFramesPerSecond = 120
        context.coordinator.renderer = SpectrumRenderer(device: view.device!, frames: frames)
        view.delegate = context.coordinator.renderer
        return view
    }
    func updateNSView(_ view: SpectrumMTKView, context: Context) {}
}
