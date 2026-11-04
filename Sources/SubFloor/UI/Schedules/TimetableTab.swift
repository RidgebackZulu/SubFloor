import SwiftUI

/// The built-in shortwave list: search, On tonight, an Add button per broadcast, and the EiBi credit.
struct TimetableTab: View {
    @Bindable var vm: SchedulesModel

    var body: some View {
        let rows = vm.timetableRows
        return VStack(spacing: 0) {
            HStack {
                TextField("Station, language or country", text: $vm.search).textFieldStyle(.roundedBorder)
                Toggle("On tonight", isOn: $vm.onTonight).toggleStyle(.checkbox)
            }
            .padding(10)
            if let message = vm.message {
                Text(message).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12)
            }
            List(rows) { row in
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(row.station).font(.headline).lineLimit(1)
                            if row.uncertain {
                                Text("uncertain").font(.caption2.weight(.semibold)).padding(.horizontal, 5)
                                    .background(Capsule().fill(Color.orange.opacity(0.25)))
                                    .help("EiBi marks this broadcast irregular, tentative or a test")
                            }
                        }
                        Text("\(row.language) · \(row.country)").foregroundStyle(.secondary)
                    }
                    .frame(minWidth: 180, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.when).monospacedDigit()
                        Text(row.frequencies).foregroundStyle(.secondary).monospacedDigit()
                    }
                    Spacer(minLength: 8)
                    if row.added {
                        Text("Added").foregroundStyle(.secondary)
                    } else {
                        Button("Add") { vm.add(row) }
                    }
                }
                .padding(.vertical, 3)
            }
            Divider()
            Text(vm.creditLine).font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(10)
        }
    }
}
