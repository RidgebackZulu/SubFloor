import Recording
import SubFloorCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(DialController.self) private var dial
    @AppStorage("appearance") private var appearance = "dark"
    @State private var loText = ""

    var body: some View {
        Form {
            Picker("Appearance", selection: $appearance) {
                Text("Dark").tag("dark")
                Text("Light").tag("light")
                Text("System").tag("system")
            }
            .pickerStyle(.segmented)
            Section("HamItUp upconverter") {
                TextField("LO frequency", text: $loText)
                    .onSubmit { if let hz = FrequencyParser.parse(loText) { model.setUpconverterLO(hz) } }
                Text("Radio is tuned to display frequency + LO when HamItUp mode is on. Default 125 MHz.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            RecordingSection()
            Section("SubFloor Dial") {
                @Bindable var dial = dial
                Toggle("Connect over Bluetooth", isOn: $dial.useBluetooth)
                Toggle("Connect over USB", isOn: $dial.useUSB)
                HStack {
                    Button("Pair New Dial") { dial.pairNewDial() }
                    Button("Forget Dial") { dial.forgetDial() }.disabled(!dial.hasKnownBluetoothDial)
                }
                Text("On the dial: long-press the knob › Bluetooth › Pair new Mac, then Pair New Dial here.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Calibration") {
                Stepper(String(format: "Frequency correction %.1f ppm", model.hardware.ppm),
                        value: Binding(get: { model.hardware.ppm }, set: { v in model.updateHardware { $0.ppm = v } }),
                        in: -100...100, step: 0.1)
            }
        }
        .formStyle(.grouped)
        .frame(width: 500)
        .onAppear { loText = FrequencyFormatter.short(model.upconverter.loHz) }
    }
}

private struct RecordingSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let r = model.recording
        Section("Recording") {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Pre-roll")
                    Spacer()
                    Text("\(Int(r.preRollSeconds)) s").monospacedDigit().foregroundStyle(.secondary)
                }
                Slider(value: $model.recording.preRollSeconds, in: RecordingSettings.preRollRange, step: 1)
                Text(preRollNote).font(.caption).foregroundStyle(.secondary)
            }
            Picker("Audio file", selection: $model.recording.audioFormat) {
                ForEach(StreamKind.audio.fileFormats) { Text($0.label).tag($0) }
            }
            Picker("Audio samples", selection: $model.recording.audioSampleFormat) {
                ForEach(StreamKind.audio.sampleFormats(for: r.audioFormat)) { Text($0.label).tag($0) }
            }
            Picker("IQ file", selection: $model.recording.iqFormat) {
                ForEach(StreamKind.iq.fileFormats) { Text($0.label).tag($0) }
            }
            Picker("IQ samples", selection: $model.recording.iqSampleFormat) {
                ForEach(StreamKind.iq.sampleFormats(for: r.iqFormat)) { Text($0.label).tag($0) }
            }
            Picker("IQ pre-roll memory", selection: $model.recording.iqMemoryLimitBytes) {
                ForEach(RecordingSettings.memoryLimits, id: \.self) { Text(RecordingFormat.bytes($0)).tag($0) }
            }
            LabeledContent("Folder") {
                HStack {
                    Text(r.folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                    Button("Choose…") { model.chooseRecordingsFolder() }.controlSize(.small)
                    Button("Show") { model.revealRecordings() }.controlSize(.small)
                }
            }
            Text("Audio is the receiver's output before the volume knob, 48 kHz. IQ is the capture at the source rate; a retune starts a new IQ file. 16-bit IQ is lossless for the RSP1B's 14-bit ADC. Changing the pre-roll or a sample format starts the pre-roll over and ends a recording in progress.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var preRollNote: String {
        let r = model.recording
        guard let plan = model.iqRingPlan else { return "Recordings start up to \(Int(r.preRollSeconds)) s before the click." }
        var note = "Recordings start up to \(Int(r.preRollSeconds)) s before the click. IQ pre-roll uses \(RecordingFormat.bytes(plan.capacityBytes)) at \(FrequencyFormatter.rate(model.sampleRate))"
        if plan.effectivePreRollSeconds < r.preRollSeconds - 0.5 {
            note += ", limited to \(Int(plan.effectivePreRollSeconds)) s by the memory limit"
        }
        return note + "."
    }
}
