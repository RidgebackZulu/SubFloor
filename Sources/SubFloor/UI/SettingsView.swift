import SubFloorCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
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
            Section("Calibration") {
                Stepper(String(format: "Frequency correction %.1f ppm", model.hardware.ppm),
                        value: Binding(get: { model.hardware.ppm }, set: { v in model.updateHardware { $0.ppm = v } }),
                        in: -100...100, step: 0.1)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .onAppear { loText = FrequencyFormatter.short(model.upconverter.loHz) }
    }
}
