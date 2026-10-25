import DSPCore
import Recording
import SubFloorCore
import SwiftUI

struct TopBarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 14) {
            DeviceChip()
            Button { model.toggleRun() } label: {
                Image(systemName: model.isRunning ? "stop.fill" : "play.fill").frame(width: 18)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .help("Run / Stop (Space)")

            FrequencyReadout(hz: model.vfoHz, onCommit: { model.tune(to: $0) }, onDigitStep: model.stepDigit)

            VStack(alignment: .leading, spacing: 2) {
                Text("CENTER").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                Text(FrequencyFormatter.short(model.centerHz)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Picker("Mode", selection: Binding(get: { model.mode }, set: { model.setMode($0) })) {
                ForEach(DemodMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 250)

            BandwidthControl()

            // Green when on, dimmed when off: a tinted toggle button reads much the same either way.
            let hamItUp = model.upconverter.enabled
            Button { model.setUpconverter(!hamItUp) } label: {
                Label("HamItUp", systemImage: "arrow.up.arrow.down")
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .foregroundStyle(hamItUp ? Color.black : Color.secondary)
                    .background { RoundedRectangle(cornerRadius: 5).fill(hamItUp ? Color.green : Color.white.opacity(0.06)) }
                    .overlay { RoundedRectangle(cornerRadius: 5).stroke(hamItUp ? Color.green : Color.white.opacity(0.15)) }
                    .opacity(hamItUp ? 1 : 0.6)
            }
            .buttonStyle(.plain)
            .help(hamItUp
                  ? "HamItUp on: radio tuned \(FrequencyFormatter.short(model.upconverter.loHz)) above the display frequency (⌘U)"
                  : "HamItUp off: direct sampling (⌘U turns it on)")

            RecordCluster()

            Button { model.addBookmark() } label: { Image(systemName: "star") }
                .help("Bookmark this frequency (⌘D)")
            Button { model.quickTuneVisible = true } label: { Image(systemName: "magnifyingglass") }
                .help("Quick tune (⌘L or /)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

private struct DeviceChip: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 6) {
            let connecting = !model.isRunning && model.rspConnection == .opening
            Circle()
                .fill(model.isRunning ? (model.sourceKind == .sdrplay ? Color.green : Color.orange) : connecting ? Color.yellow : Color.gray)
                .frame(width: 8, height: 8)
            Text(model.isRunning ? model.deviceName : connecting ? "Connecting…" : "Stopped").font(.callout.weight(.medium))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(.white.opacity(0.06)))
        .help(model.sourceKind == .sdrplay ? "SDRplay RSP1B" : "No RSP — demo or file source")
    }
}

private struct BandwidthControl: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 4) {
            Text("BW").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(FrequencyFormatter.short(model.bandwidthHz)).monospacedDigit().frame(minWidth: 64, alignment: .trailing)
            Stepper("", value: Binding(get: { model.bandwidthHz }, set: { model.setBandwidth($0) }),
                    in: model.mode.bandwidthRange, step: model.mode.bandwidthStep)
                .labelsHidden()
        }
        .help("Filter bandwidth — or drag the passband edges on the spectrum")
    }
}

/// Audio · IQ · Both. Red with the elapsed time while recording; idle, a faint red fill shows how
/// much of the pre-roll is primed, since a recording starts that far before the click.
private struct RecordCluster: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 3) {
            RecordButton(kind: .audio)
            RecordButton(kind: .iq)
            let all = model.isRecordingAll
            Button { model.toggleRecordingBoth() } label: { RecordButtonLabel(title: "Both", on: all, fill: 0) }
                .buttonStyle(.plain)
                .help(all ? "Stop both recordings (⌘⇧R)" : "Record audio and IQ (⌘⇧R)")
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.04)))
        .opacity(model.isRunning ? 1 : 0.5)
        .disabled(!model.isRunning)
        .accessibilityLabel("Recording")
    }
}

private struct RecordButton: View {
    @Environment(AppModel.self) private var model
    let kind: StreamKind

    var body: some View {
        let status = model.recordingStatus[kind] ?? RecordingStatus()
        let preRoll = Int((kind == .iq ? model.iqRingPlan?.effectivePreRollSeconds : model.recording.preRollSeconds) ?? 0)
        let key = kind == .audio ? "⌘⇧A" : "⌘⇧I"
        Button { model.toggleRecording(kind) } label: {
            RecordButtonLabel(title: status.isRecording ? RecordingFormat.elapsed(status.duration) : kind.label,
                              on: status.isRecording, fill: status.preRollFill)
        }
            .buttonStyle(.plain)
            .help(status.isRecording
                  ? "Stop recording \(kind.label.lowercased()) (\(key)) — \(RecordingFormat.bytes(status.bytesWritten)) so far"
                  : "Record \(kind.label.lowercased()) (\(key)) — the file starts \(preRoll) s before the click")
    }
}

private struct RecordButtonLabel: View {
    let title: String
    let on: Bool
    /// 0…1 of the idle button to tint: the pre-roll primed so far.
    let fill: Double

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(on ? Color.white : Color.red.opacity(0.9)).frame(width: 7, height: 7)
            Text(title).monospacedDigit().lineLimit(1)
        }
        .font(.callout.weight(.medium))
        .frame(minWidth: 46)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .foregroundStyle(on ? Color.white : Color.secondary)
        .background {
            GeometryReader { geo in
                RoundedRectangle(cornerRadius: 5).fill(on ? Color.red : Color.white.opacity(0.06))
                if !on, fill > 0 {
                    Rectangle().fill(Color.red.opacity(0.22)).frame(width: geo.size.width * min(max(fill, 0), 1))
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay { RoundedRectangle(cornerRadius: 5).stroke(on ? Color.red : Color.white.opacity(0.15)) }
        .contentShape(Rectangle())
    }
}
