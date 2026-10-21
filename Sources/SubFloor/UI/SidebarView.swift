import AppKit
import DSPCore
import SDRplayKit
import SubFloorCore
import SwiftUI

struct SidebarView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                RadioSection()
                DisplaySection()
                AudioSection()
                BookmarksSection()
            }
            .padding(14)
        }
        .background(.ultraThinMaterial)
    }
}

private struct RadioSection: View {
    @Environment(AppModel.self) private var model

    private func hw<T>(_ keyPath: WritableKeyPath<SDRplaySettings, T>) -> Binding<T> {
        Binding(get: { model.hardware[keyPath: keyPath] }, set: { v in model.updateHardware { $0[keyPath: keyPath] = v } })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("Radio")
            Picker("Source", selection: Binding(get: { model.preferredSource }, set: { model.useSource($0) })) {
                ForEach(SourceKind.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            LabeledContent("Sample rate") {
                Picker("", selection: hw(\.sampleRate)) {
                    ForEach(RSP1B.sampleRates, id: \.self) { Text(String(format: "%g MSPS", $0 / 1e6)).tag($0) }
                }
                .labelsHidden().frame(width: 110)
            }
            LabeledContent("Decimation") {
                Picker("", selection: hw(\.decimation)) {
                    ForEach(RSP1B.decimations, id: \.self) { Text("÷\($0)").tag($0) }
                }
                .labelsHidden().frame(width: 110)
            }
            LabeledContent("Output rate") {
                Text(FrequencyFormatter.rate(model.sampleRate)).monospacedDigit().foregroundStyle(.secondary)
            }
            LabeledContent("LNA state") {
                Stepper("\(model.hardware.lnaState) / \(model.lnaStateCount - 1)", value: hw(\.lnaState), in: 0...(model.lnaStateCount - 1))
                    .monospacedDigit()
            }
            SliderRow(title: "IF gain reduction",
                      value: Binding(get: { Double(model.hardware.ifGainReductionDb) }, set: { v in model.updateHardware { $0.ifGainReductionDb = Int(v.rounded()) } }),
                      range: 20...59, text: "\(model.hardware.ifGainReductionDb) dB")
                .disabled(model.hardware.agc != .off)
            LabeledContent("Hardware AGC") {
                Picker("", selection: hw(\.agc)) {
                    ForEach(HardwareAGC.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden().frame(width: 110)
            }
            Toggle("Bias-T", isOn: hw(\.biasT))
            Toggle("FM broadcast notch", isOn: hw(\.rfNotch))
            Toggle("DAB notch", isOn: hw(\.dabNotch))
        }
    }
}

private struct DisplaySection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("Display")
            LabeledContent("FFT size") {
                Picker("", selection: $model.spectrum.fftSize) {
                    ForEach([1024, 2048, 4096, 8192, 16384, 32768, 65536], id: \.self) { Text("\($0)").tag($0) }
                }
                .labelsHidden().frame(width: 110)
            }
            LabeledContent("Window") {
                Picker("", selection: $model.spectrum.window) {
                    ForEach(WindowKind.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden().frame(width: 130)
            }
            SliderRow(title: "Waterfall speed", value: $model.spectrum.framesPerSecond, range: 5...120,
                      text: "\(Int(model.spectrum.framesPerSecond)) lines/s")
            SliderRow(title: "Averaging",
                      value: Binding(get: { Double(1 - model.spectrum.averaging) }, set: { model.spectrum.averaging = Float(max(0.02, 1 - $0)) }),
                      range: 0...0.98, text: String(format: "%.0f%%", (1 - model.spectrum.averaging) * 100))
            LabeledContent("Colormap") {
                Picker("", selection: $model.colormap) {
                    ForEach(Colormap.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden().frame(width: 110)
            }
            HStack {
                Toggle("Peak hold", isOn: $model.showPeak)
                Spacer()
                Button("Reset") { model.resetPeak() }.controlSize(.small)
            }
            LabeledContent("Resolution") {
                Text(FrequencyFormatter.short(model.sampleRate / Double(model.spectrum.fftSize)) + " / bin")
                    .monospacedDigit().foregroundStyle(.secondary)
            }
        }
    }
}

private struct AudioSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("Audio")
            SliderRow(title: "Volume", value: Binding(get: { Double(model.volume) }, set: { model.volume = Float($0) }),
                      range: 0...1, text: "\(Int(model.volume * 100))%")
            Picker("AGC", selection: $model.agcSpeed) {
                ForEach(AGCSpeed.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            HStack {
                Toggle("Squelch", isOn: $model.squelchEnabled)
                Spacer()
                Text("\(Int(model.squelchDb)) dB").monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { Double(model.squelchDb) }, set: { model.squelchDb = Float($0) }), in: -140...0)
                .controlSize(.small)
                .disabled(!model.squelchEnabled)
            SignalMeter()
            if model.mode == .cw {
                SliderRow(title: "CW pitch", value: $model.cwPitchHz, range: 300...1200, text: "\(Int(model.cwPitchHz)) Hz")
            }
        }
    }
}

/// Reads the channel power itself, so its 10 Hz updates re-render only the meter, not the section
/// around it (whose segmented picker SwiftUI re-measures, slowly, whenever that section re-renders).
private struct SignalMeter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let db = model.signalDb
        let threshold: Float? = model.squelchEnabled ? model.squelchDb : nil
        GeometryReader { geo in
            let f = { (v: Float) in CGFloat(min(max((v + 140) / 140, 0), 1)) * geo.size.width }
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.08))
                Capsule().fill(LinearGradient(colors: [.green, .yellow, .red], startPoint: .leading, endPoint: .trailing))
                    .frame(width: f(db))
                if let threshold {
                    Rectangle().fill(.white).frame(width: 2).offset(x: f(threshold) - 1)
                }
            }
        }
        .frame(height: 6)
        .help(String(format: "Channel power %.0f dBFS", db))
    }
}

private struct BookmarksSection: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""

    var body: some View {
        @Bindable var model = model
        let filtered = BookmarkSearch.filter(model.bookmarks, query: search)
        let groups = Dictionary(grouping: filtered) { $0.group ?? "Ungrouped" }
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionHeader("Bookmarks")
                Spacer()
                Toggle(isOn: $model.showBookmarks) {
                    Image(systemName: model.showBookmarks ? "eye" : "eye.slash")
                }
                .toggleStyle(.button)
                .buttonStyle(.borderless)
                .help("Show bookmarks on the spectrum (⌘B)")
                Menu {
                    Button("Add Current Frequency") { model.addBookmark() }
                    Divider()
                    Button("Import…") { model.importBookmarks() }
                    Button("Export…") { model.exportBookmarks() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 24)
            }
            TextField("Search", text: $search).textFieldStyle(.roundedBorder)
            ForEach(groups.keys.sorted(), id: \.self) { group in
                Text(group).font(.caption2.weight(.medium)).foregroundStyle(.tertiary).padding(.top, 4)
                ForEach(groups[group]!) { BookmarkRow(bookmark: $0) }
            }
        }
    }
}

private struct BookmarkRow: View {
    @Environment(AppModel.self) private var model
    let bookmark: Bookmark
    @State private var hovering = false

    var body: some View {
        Button { model.select(bookmark) } label: {
            HStack(spacing: 8) {
                Circle().fill(Color(hex: bookmark.colorHex) ?? Theme.accent).frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 1) {
                    Text(bookmark.name).lineLimit(1)
                    Text("\(FrequencyFormatter.short(bookmark.frequencyHz)) · \(bookmark.mode.label)")
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
                Spacer()
                if bookmark.upconverter {
                    Image(systemName: "arrow.up.arrow.down").font(.caption2).foregroundStyle(.orange).help("Uses HamItUp")
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.white.opacity(0.06) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Delete", role: .destructive) { model.deleteBookmark(bookmark.id) }
        }
    }
}
