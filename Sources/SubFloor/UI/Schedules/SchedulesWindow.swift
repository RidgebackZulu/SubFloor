import Scheduling
import SwiftUI

/// What the editor sheet is editing: a new schedule or an existing one.
private enum EditTarget: Identifiable {
    case new
    case edit(Schedule)
    var id: String { if case .edit(let s) = self { s.id.uuidString } else { "new" } }
}

/// The Schedules window (Radio › Schedules…): every schedule with what happened to its last run, and the EiBi
/// timetable to add broadcasts from. The drawing is thin; `SchedulesModel` and the row types hold the logic.
struct SchedulesWindow: View {
    @State private var vm: SchedulesModel
    @State private var editing: EditTarget?
    @State private var deleting: Schedule?

    init(model: AppModel) {
        _vm = State(initialValue: SchedulesModel(scheduler: model.scheduler,
                                                 transcriptionEnabled: { [weak model] in model?.transcriptionSettings.enabled ?? true }))
    }

    var body: some View {
        // Refreshed every 30 s so next runs and the battery note stay current.
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            TabView {
                mySchedules.tabItem { Label("My schedules", systemImage: "calendar") }
                TimetableTab(vm: vm).tabItem { Label("Timetable", systemImage: "list.bullet.rectangle") }
            }
        }
        .frame(minWidth: 820, minHeight: 480)
        .navigationTitle("Schedules")
        .sheet(item: $editing) { target in
            switch target {
            case .new: ScheduleEditor(vm: vm, original: nil)
            case .edit(let s): ScheduleEditor(vm: vm, original: s)
            }
        }
        .confirmationDialog("Delete “\(deleting?.name ?? "")”?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) { if let s = deleting { vm.delete(s.id) } }
        }
    }

    private var mySchedules: some View {
        let rows = vm.rows
        return VStack(spacing: 0) {
            HStack {
                Text(rows.count == 1 ? "1 schedule" : "\(rows.count) schedules").foregroundStyle(.secondary)
                Spacer()
                Button("Add…") { editing = .new }
            }
            .padding(10)
            if let message = vm.message {
                Text(message).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12)
            }
            if rows.isEmpty {
                ContentUnavailableView("No schedules", systemImage: "calendar",
                                       description: Text("Add one here, or from the Timetable tab."))
            } else {
                List(rows) { row in
                    ScheduleRowView(row: row,
                                    enabled: Binding(get: { row.schedule.enabled }, set: { vm.setEnabled(row.id, $0) }),
                                    edit: { editing = .edit(row.schedule) }, delete: { deleting = row.schedule })
                }
            }
            Divider()
            notes
        }
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(SchedulesModel.keepAwakeNote, systemImage: vm.keepAwakeIsAmber ? "battery.50percent" : "moon.zzz")
                .foregroundStyle(vm.keepAwakeIsAmber ? Color.orange : Color.secondary)
            if let text = vm.transcriptionNoteText {
                Label(text, systemImage: "text.badge.xmark").foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }
}

private struct ScheduleRowView: View {
    let row: ScheduleRow
    @Binding var enabled: Bool
    let edit: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.title).font(.headline).lineLimit(1)
                    if row.addedBy != "you" { AgentBadge(name: row.addedBy) }
                }
                Text(row.tuning).foregroundStyle(.secondary)
                Text(row.when).monospacedDigit()
                if let note = row.note { Text(note).font(.caption).foregroundStyle(.secondary) }
                if let overlap = row.overlapText { Text(overlap).font(.caption).foregroundStyle(.orange) }
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 2) {
                Text("Next: \(row.nextRun)").monospacedDigit()
                Text(row.lastOutcome).foregroundStyle(.secondary)
                Text("Added by \(row.addedBy)").font(.caption).foregroundStyle(.secondary)
            }
            .font(.callout)
            Toggle("On", isOn: $enabled).labelsHidden().toggleStyle(.switch)
            Button { edit() } label: { Image(systemName: "pencil") }.buttonStyle(.borderless).help("Edit")
            Button { delete() } label: { Image(systemName: "trash") }.buttonStyle(.borderless).help("Delete")
        }
        .padding(.vertical, 4)
        .opacity(enabled ? 1 : 0.6)
        .contextMenu {
            Button("Edit…", action: edit)
            Button("Delete", role: .destructive, action: delete)
        }
    }
}
