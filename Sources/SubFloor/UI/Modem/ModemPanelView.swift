import Modems
import SwiftUI

/// The multi-signal modem panel, under the spectrum: the control strip, its messages, the cursor
/// bench (collapsible), then the signal rows. With the mode Off only the strip shows.
struct ModemPanelView: View {
    @Environment(AppModel.self) private var model
    @State private var expanded = true
    @State private var benchExpanded = true

    var body: some View {
        let status = model.modemPanelStatus
        VStack(spacing: 0) {
            Divider()
            ModemControlStrip(status: status, expanded: $expanded)
            if expanded {
                if status.isOn {
                    ForEach(status.messages, id: \.self) { MessageRow(message: $0) }
                    Divider()
                    CursorBenchView(expanded: $benchExpanded)
                    Divider()
                    SignalRowsView(showsSlotSection: !status.slotModes.isEmpty)
                        .frame(height: 200)
                } else {
                    Text(ModemPanelFormat.offHint)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                }
            }
        }
        .background(.bar)
    }
}

/// One message under the strip; the box-outside-span one carries a Re-center button.
private struct MessageRow: View {
    @Environment(AppModel.self) private var model
    let message: ModemPanelMessage

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: message.isWarning ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .foregroundStyle(message.isWarning ? Color.orange : Theme.accent)
            Text(message.text).lineLimit(1)
            if message.offersRecenter {
                Text("—").foregroundStyle(.secondary)
                Button("Re-center") { model.recenterModemBox() }
                    .controlSize(.small)
            }
            Spacer()
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background((message.isWarning ? Color.orange : Theme.accent).opacity(0.08))
    }
}
