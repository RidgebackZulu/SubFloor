import DSPCore
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

            FrequencyReadout(hz: model.vfoHz, onCommit: { model.tune(to: $0) }, onStep: { model.setVFO($0) })

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
            .frame(width: 300)

            BandwidthControl()

            Toggle(isOn: Binding(get: { model.upconverter.enabled }, set: { model.setUpconverter($0) })) {
                Label("HamItUp", systemImage: "arrow.up.arrow.down")
            }
            .toggleStyle(.button)
            .tint(.orange)
            .help("Upconverter mode: radio tuned \(FrequencyFormatter.short(model.upconverter.loHz)) above the display frequency")

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
            Circle()
                .fill(model.isRunning ? (model.sourceKind == .sdrplay ? Color.green : Color.orange) : Color.gray)
                .frame(width: 8, height: 8)
            Text(model.isRunning ? model.deviceName : "Stopped").font(.callout.weight(.medium))
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
