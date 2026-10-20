import DSPCore
import Foundation
import Observation
import SwiftUI

/// Main-thread state for the CW output view. Mutated only on the main queue.
@Observable
public final class CWDecoderModel: @unchecked Sendable {
    public private(set) var text = ""
    public private(set) var wpm: Double = 0
    public private(set) var level: Float = 0

    func append(_ newText: String, wpm: Double, level: Float) {
        if !newText.isEmpty {
            text += newText
            if text.count > 10_000 { text.removeFirst(text.count - 10_000) }
        }
        self.wpm = wpm
        self.level = level
    }

    public func clear() { text = "" }
}

public final class CWDecoderModem: Modem, @unchecked Sendable {
    public static let info = ModemInfo(id: "cw", name: "CW Decoder", input: .audio, preferredMode: .cw, preferredBandwidth: 500)

    public let model = CWDecoderModel()
    private let core = CWDecoderCore()
    private var pending = ""
    private var samplesSinceFlush = 0

    public init() {}

    public func reset() { core.reset() }

    public func process(audio: UnsafeBufferPointer<Float>, context: ModemContext) {
        if core.pitchHz != context.cwPitchHz { core.pitchHz = context.cwPitchHz }
        pending += core.process(audio)
        samplesSinceFlush += audio.count
        guard samplesSinceFlush >= Int(context.sampleRate / 10) else { return }
        let text = pending, wpm = core.wpm, level = core.level, model = model
        pending = ""
        samplesSinceFlush = 0
        DispatchQueue.main.async { model.append(text, wpm: wpm, level: level) }
    }

    @MainActor public func makeOutputView() -> AnyView { AnyView(CWDecoderView(model: model)) }
}

struct CWDecoderView: View {
    let model: CWDecoderModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                Label(model.wpm > 0 ? String(format: "%.0f WPM", model.wpm) : "— WPM", systemImage: "metronome")
                    .monospacedDigit()
                Gauge(value: Double(model.level)) { EmptyView() }
                    .gaugeStyle(.accessoryLinearCapacity)
                    .tint(.green)
                    .frame(width: 120)
                Spacer()
                Button("Clear") { model.clear() }.controlSize(.small)
            }
            .font(.callout)
            ScrollViewReader { proxy in
                ScrollView {
                    Text(model.text.isEmpty ? "Listening…" : model.text)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(model.text.isEmpty ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .id("end")
                }
                .onChange(of: model.text) { proxy.scrollTo("end", anchor: .bottom) }
            }
        }
        .padding(12)
    }
}
