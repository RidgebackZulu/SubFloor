import DSPCore
import SubFloorCore
import SwiftUI

/// One bookmark's fields, editing `draft`: name, frequency (taken when entered, see
/// `commitFrequency`), mode, bandwidth, group, HamItUp and notes, and who added it if an agent did.
struct BookmarkFields: View {
    @Environment(AppModel.self) private var model
    @Binding var draft: Bookmark
    @Binding var frequencyText: String
    let commitFrequency: () -> Void

    var body: some View {
        TextField("Name", text: $draft.name)
        TextField("Frequency", text: $frequencyText)
            .onSubmit { commitFrequency() }
            .help("e.g. 14.074, 7074k, 144.39m")
        Picker("Mode", selection: $draft.mode) {
            ForEach(DemodMode.allCases) { Text($0.label).tag($0) }
        }
        TextField("Bandwidth (Hz)", value: $draft.bandwidthHz, format: .number.precision(.fractionLength(0)))
            .help("The passband width tuned with the bookmark")
        LabeledContent("Group") {
            GroupComboBox(text: Binding(get: { draft.group ?? "" }, set: { draft.group = $0.isEmpty ? nil : $0 }),
                          groups: model.bookmarkGroups)
                .help("Pick a group, or type a new one")
        }
        Toggle("Via HamItUp", isOn: $draft.upconverter)
        TextField("Notes", text: Binding(get: { draft.notes ?? "" }, set: { draft.notes = $0.isEmpty ? nil : $0 }),
                  axis: .vertical)
            .lineLimit(3...8)
        if let agent = draft.addedBy {
            LabeledContent("Added by") { AgentBadge(name: agent, long: true) }
        }
    }
}

/// "MCP": marks a bookmark an AI agent saved through the MCP server.
struct AgentBadge: View {
    let name: String
    var long = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "sparkles").font(.system(size: 8, weight: .bold))
            Text(long ? "\(name) via MCP" : "MCP").font(.system(size: long ? 11 : 9, weight: .semibold))
                .lineLimit(1)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .foregroundStyle(Color(red: 0.42, green: 0.86, blue: 0.56))
        .background(Capsule().fill(Color(red: 0.12, green: 0.6, blue: 0.33).opacity(0.18)))
        .help("Saved by \(name) through SubFloor's MCP server")
    }
}

/// Edits one bookmark in place: each change is saved as it is made (the frequency when entered).
struct BookmarkEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var draft: Bookmark
    @State private var frequencyText: String
    let close: () -> Void

    init(bookmark: Bookmark, close: @escaping () -> Void) {
        _draft = State(initialValue: bookmark)
        _frequencyText = State(initialValue: FrequencyFormatter.grouped(bookmark.frequencyHz))
        self.close = close
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Form {
                BookmarkFields(draft: $draft, frequencyText: $frequencyText, commitFrequency: commitFrequency)
            }
            HStack {
                Button("Delete", role: .destructive) {
                    model.deleteBookmark(draft.id)
                    close()
                }
                Button("All Bookmarks…") {
                    commitFrequency()
                    model.bookmarkManagerSelection = [draft.id]
                    openWindow(id: "bookmarks")
                    close()
                }
                .help("Open the bookmark manager (⌥⌘B)")
                Spacer()
                Button("Use Current Tuning") {
                    draft = model.withCurrentTuning(draft)
                    frequencyText = FrequencyFormatter.grouped(draft.frequencyHz)
                }
                .help("Save the current frequency, mode, passband width and HamItUp state in this bookmark")
                Button("Tune") {
                    commitFrequency()
                    model.select(draft)
                    close()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 420)
        .onChange(of: draft) { _, edited in model.updateBookmark(edited) }
        .onDisappear { commitFrequency() }
    }

    /// Takes the typed frequency if it parses (else restores the field) and saves.
    private func commitFrequency() {
        if let hz = FrequencyParser.parse(frequencyText) { draft.frequencyHz = hz }
        frequencyText = FrequencyFormatter.grouped(draft.frequencyHz)
        model.updateBookmark(draft)
    }
}
