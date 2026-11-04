import Scheduling
import SwiftUI

/// Adds or edits one schedule. Saving shows the refusal inline (the same texts as the MCP tools); overlaps with
/// other schedules show as the fields change.
struct ScheduleEditor: View {
    let vm: SchedulesModel
    let original: Schedule?
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ScheduleDraft
    @State private var error: String?

    init(vm: SchedulesModel, original: Schedule?) {
        self.vm = vm
        self.original = original
        _draft = State(initialValue: original.map(ScheduleDraft.init) ?? ScheduleDraft(zone: vm.scheduler.localZone, now: vm.scheduler.now()))
    }

    private var zone: TimeZone { TimeZone(identifier: draft.timeZone) ?? vm.scheduler.localZone }

    /// A `Date` whose hour and minute (in the draft's zone) are `time`, for the pickers.
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = zone
        return c
    }

    private var startBinding: Binding<Date> {
        Binding(get: { calendar.date(bySettingHour: draft.start.hour, minute: draft.start.minute, second: 0, of: vm.scheduler.now()) ?? vm.scheduler.now() },
                set: { let c = calendar.dateComponents([.hour, .minute], from: $0)
                       draft.start = TimeOfDay(hour: c.hour ?? 0, minute: c.minute ?? 0) })
    }

    private var onceBinding: Binding<Date> {
        Binding(get: { calendar.date(from: DateComponents(year: draft.onceDate.year, month: draft.onceDate.month, day: draft.onceDate.day, hour: 12)) ?? vm.scheduler.now() },
                set: { let c = calendar.dateComponents([.year, .month, .day], from: $0)
                       draft.onceDate = ScheduleDate(year: c.year ?? 2026, month: c.month ?? 1, day: c.day ?? 1) })
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Picker("Kind", selection: $draft.kind) {
                    Text("Broadcast").tag(ScheduleKind.broadcast)
                    Text("Watch").tag(ScheduleKind.watch)
                }
                .pickerStyle(.segmented)
                .onChange(of: draft.kind) { _, kind in draft.mode = kind == .watch ? .auto : .am }
                TextField("Name", text: $draft.name)
                if draft.kind == .broadcast {
                    TextField("Frequencies (kHz)", text: $draft.frequencies, prompt: Text("9435, 9455"))
                } else {
                    TextField("Low (kHz)", text: $draft.lowKHz)
                    TextField("High (kHz)", text: $draft.highKHz)
                }
                Picker("Mode", selection: $draft.mode) {
                    ForEach(ScheduleMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                DatePicker("Start", selection: startBinding, displayedComponents: .hourAndMinute)
                    .environment(\.timeZone, zone)
                TextField("Duration (minutes)", value: $draft.durationMinutes, format: .number)
                TextField("Time zone", text: $draft.timeZone)
                    .help("The zone the start time is in: UTC or an IANA name like America/Chicago")
                Picker("Repeats", selection: $draft.repeats) {
                    ForEach(ScheduleDraft.Repeat.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                switch draft.repeats {
                case .weekly:
                    HStack {
                        ForEach(Weekday.allCases, id: \.self) { day in
                            Toggle(ScheduleWhen.name(day), isOn: Binding(
                                get: { draft.weekdays.contains(day) },
                                set: { if $0 { draft.weekdays.insert(day) } else { draft.weekdays.remove(day) } }))
                                .toggleStyle(.button)
                        }
                    }
                case .monthly:
                    Picker("Which", selection: $draft.ordinal) {
                        ForEach([1, 2, 3, 4, 5, -1], id: \.self) { Text($0 == -1 ? "Last" : "\($0)").tag($0) }
                    }
                    Picker("Day", selection: $draft.monthlyWeekday) {
                        ForEach(Weekday.allCases, id: \.self) { Text(ScheduleWhen.name($0)).tag($0) }
                    }
                case .once:
                    DatePicker("Date", selection: onceBinding, displayedComponents: .date).environment(\.timeZone, zone)
                }
                Toggle("On", isOn: $draft.enabled)
                Stepper("Squelch margin: \(Int(draft.marginDb)) dB", value: $draft.marginDb, in: 3...30, step: 1)
                if let addedBy = original?.addedBy { LabeledContent("Added by") { AgentBadge(name: addedBy, long: true) } }
            }
            .formStyle(.grouped)
            VStack(alignment: .leading, spacing: 4) {
                if let overlap = vm.overlapText(for: draft, replacing: original) { Text(overlap).foregroundStyle(.orange) }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    error = vm.save(draft, replacing: original)
                    if error == nil { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 520)
    }
}
