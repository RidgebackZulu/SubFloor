import DSPCore
import SubFloorCore
import SwiftUI

/// Which bookmarks the manager lists.
enum BookmarkFilter: Hashable {
    case all
    case fromAgents
    case ungrouped
    case group(String)

    func includes(_ b: Bookmark) -> Bool {
        switch self {
        case .all: true
        case .fromAgents: b.isFromAgent
        case .ungrouped: b.group == nil
        case .group(let g): b.group?.caseInsensitiveCompare(g) == .orderedSame
        }
    }
}

/// Sortable text for the manager's columns.
extension Bookmark {
    var modeLabel: String { mode.label }
    var groupLabel: String { group ?? "" }
    var notesLabel: String { notes ?? "" }
    var agentLabel: String { addedBy ?? "" }
}

/// The bookmark manager (Radio › Bookmarks…, ⌥⌘B): every bookmark in a sortable table, filtered by
/// group or by search, with the selected one's fields beside it. Double-click tunes; ⌫ deletes; a
/// group can be renamed by moving its bookmarks.
struct BookmarkManagerWindow: View {
    @Environment(AppModel.self) private var model
    @State private var filter: BookmarkFilter = .all
    @State private var search = ""
    @State private var sortOrder = [KeyPathComparator(\Bookmark.frequencyHz)]

    private var shown: [Bookmark] {
        BookmarkSearch.filter(model.bookmarks.filter(filter.includes), query: search).sorted(using: sortOrder)
    }

    var body: some View {
        @Bindable var model = model
        HSplitView {
            filters.frame(minWidth: 160, idealWidth: 190, maxWidth: 260)
            table(selection: $model.bookmarkManagerSelection).frame(minWidth: 520)
            detail.frame(minWidth: 280, idealWidth: 320, maxWidth: 440)
        }
        .toolbar {
            ToolbarItemGroup {
                Button { select([model.addBookmark()]) } label: { Label("Add Current Tuning", systemImage: "star") }
                    .help("Bookmark the frequency, mode, passband and HamItUp state SubFloor is tuned to")
                Menu {
                    Button("Import…") { model.importBookmarks() }
                    Button("Export…") { model.exportBookmarks() }
                } label: { Label("Import or Export", systemImage: "square.and.arrow.up.on.square") }
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Name, group, notes, frequency")
        .navigationTitle("Bookmarks")
        .navigationSubtitle(subtitle)
        .onDeleteCommand { model.deleteBookmarks(model.bookmarkManagerSelection) }
    }

    private var subtitle: String {
        let n = shown.count, total = model.bookmarks.count
        return n == total ? "\(total) bookmarks" : "\(n) of \(total)"
    }

    private func select(_ ids: Set<Bookmark.ID>) { model.bookmarkManagerSelection = ids }

    // MARK: Filters

    private var filters: some View {
        let all = model.bookmarks
        return List(selection: Binding(get: { filter }, set: { filter = $0 ?? .all })) {
            Section {
                filterRow(.all, "All Bookmarks", "bookmark", all.count)
                let agents = all.filter(\.isFromAgent).count
                if agents > 0 { filterRow(.fromAgents, "Added by Agents", "sparkles", agents) }
                let loose = all.filter { $0.group == nil }.count
                if loose > 0 { filterRow(.ungrouped, "Ungrouped", "tray", loose) }
            }
            Section("Groups") {
                ForEach(model.bookmarkGroups, id: \.self) { g in
                    filterRow(.group(g), g, "folder", all.filter { BookmarkFilter.group(g).includes($0) }.count)
                        .dropDestination(for: String.self) { ids, _ in
                            model.moveBookmarks(Set(ids.compactMap(UUID.init(uuidString:))), toGroup: g)
                            return true
                        }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func filterRow(_ f: BookmarkFilter, _ title: String, _ icon: String, _ count: Int) -> some View {
        Label { HStack { Text(title).lineLimit(1); Spacer(); Text("\(count)").foregroundStyle(.secondary).monospacedDigit() } }
            icon: { Image(systemName: icon) }
            .tag(f)
    }

    // MARK: Table

    private func table(selection: Binding<Set<Bookmark.ID>>) -> some View {
        Table(shown, selection: selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { b in
                HStack(spacing: 6) {
                    Circle().fill(Color(hex: b.colorHex) ?? Theme.accent).frame(width: 7, height: 7)
                    Text(b.name).lineLimit(1)
                    if let agent = b.addedBy { AgentBadge(name: agent) }
                }
                .draggable(b.id.uuidString)
            }
            .width(min: 140, ideal: 200)
            TableColumn("Frequency", value: \.frequencyHz) { b in
                HStack(spacing: 4) {
                    Text(FrequencyFormatter.grouped(b.frequencyHz)).monospacedDigit()
                    if b.upconverter {
                        Image(systemName: "arrow.up.arrow.down").font(.caption2).foregroundStyle(.orange).help("Uses HamItUp")
                    }
                }
            }
            .width(min: 110, ideal: 130)
            TableColumn("Mode", value: \.modeLabel).width(min: 44, ideal: 50)
            TableColumn("Bandwidth", value: \.bandwidthHz) { b in
                Text(FrequencyFormatter.audio(b.bandwidthHz)).monospacedDigit()
            }
            .width(min: 64, ideal: 76)
            TableColumn("Group", value: \.groupLabel).width(min: 80, ideal: 110)
            TableColumn("Notes", value: \.notesLabel) { b in
                Text(b.notes ?? "").lineLimit(1).foregroundStyle(.secondary).help(b.notes ?? "")
            }
            .width(min: 100, ideal: 220)
        }
        .contextMenu(forSelectionType: Bookmark.ID.self) { ids in
            if ids.count == 1, let b = model.bookmarks.first(where: { ids.contains($0.id) }) {
                Button("Tune") { model.select(b) }
            }
            if !ids.isEmpty {
                Menu("Move to Group") {
                    ForEach(model.bookmarkGroups, id: \.self) { g in
                        Button(g) { model.moveBookmarks(ids, toGroup: g) }
                    }
                    Divider()
                    Button("No Group") { model.moveBookmarks(ids, toGroup: nil) }
                }
                Divider()
                Button(ids.count == 1 ? "Delete" : "Delete \(ids.count) Bookmarks", role: .destructive) {
                    model.deleteBookmarks(ids)
                }
            }
        } primaryAction: { ids in
            if ids.count == 1, let b = model.bookmarks.first(where: { ids.contains($0.id) }) { model.select(b) }
        }
    }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        let picked = model.bookmarks.filter { model.bookmarkManagerSelection.contains($0.id) }
        if picked.count == 1, let b = picked.first {
            BookmarkDetail(bookmark: b).id(b.id)
        } else if picked.count > 1 {
            BulkDetail(ids: Set(picked.map(\.id)))
        } else {
            VStack(spacing: 8) {
                Image(systemName: "bookmark").font(.largeTitle).foregroundStyle(.tertiary)
                Text("Select a bookmark to edit it").foregroundStyle(.secondary)
                Text("Double-click one to tune to it").font(.caption).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// The selected bookmark's fields; each change is saved as it is made (the frequency when entered).
private struct BookmarkDetail: View {
    @Environment(AppModel.self) private var model
    @State private var draft: Bookmark
    @State private var frequencyText: String

    init(bookmark: Bookmark) {
        _draft = State(initialValue: bookmark)
        _frequencyText = State(initialValue: FrequencyFormatter.grouped(bookmark.frequencyHz))
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                BookmarkFields(draft: $draft, frequencyText: $frequencyText, commitFrequency: commitFrequency)
                if let created = draft.created {
                    LabeledContent("Saved") { Text(created.formatted(date: .abbreviated, time: .shortened)) }
                }
            }
            .formStyle(.grouped)
            HStack {
                Button("Use Current Tuning") {
                    draft = model.withCurrentTuning(draft)
                    frequencyText = FrequencyFormatter.grouped(draft.frequencyHz)
                }
                .help("Save the current frequency, mode, passband width and HamItUp state in this bookmark")
                Spacer()
                Button("Tune") {
                    commitFrequency()
                    model.select(draft)
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .onChange(of: draft) { _, edited in model.updateBookmark(edited) }
        .onDisappear { commitFrequency() }
    }

    private func commitFrequency() {
        if let hz = FrequencyParser.parse(frequencyText) { draft.frequencyHz = hz }
        frequencyText = FrequencyFormatter.grouped(draft.frequencyHz)
        model.updateBookmark(draft)
    }
}

/// Several bookmarks selected: move them to a group together, or delete them.
private struct BulkDetail: View {
    @Environment(AppModel.self) private var model
    let ids: Set<Bookmark.ID>
    @State private var group = ""

    var body: some View {
        Form {
            Section("\(ids.count) bookmarks selected") {
                LabeledContent("Move to group") {
                    GroupComboBox(text: $group, groups: model.bookmarkGroups, placeholder: "Pick or type a group")
                }
                HStack {
                    Spacer()
                    Button("Move") { model.moveBookmarks(ids, toGroup: group) }
                        .disabled(group.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            Section {
                Button("Delete \(ids.count) Bookmarks", role: .destructive) { model.deleteBookmarks(ids) }
            }
        }
        .formStyle(.grouped)
    }
}
