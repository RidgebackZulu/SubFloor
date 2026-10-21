import Modems
import SwiftUI

/// The decodes, in one always-visible list under one header: the cursor's row pinned first in
/// amber, then FT8/WSPR messages (newest slot first; the one at the cursor in amber), then the other
/// tracked CW/PSK31 signals in `DecodeLog`'s frozen frequency order. A mode change clears the log,
/// so in practice the list holds one mode's rows. In a slot mode the other tracked signals are left
/// out: their decodes are the slot rows.
///
/// Clicking a row locks the cursor on its signal, and the bench shows it (the cursor's row unlocks
/// it); a live row's disclosure shows its full history. While the pointer is over the list new rows
/// are held (`setRowHold`), and a floating "N new ↓" pill shows them.
struct SignalRowsView: View {
    @Environment(AppModel.self) private var model
    /// Whether FT8/WSPR are decoding.
    let showsSlotDecodes: Bool
    @State private var expandedRows: Set<Int> = []

    var body: some View {
        let log = model.decodeLog
        let live = log.liveRows
        let cursorRows = live.filter(\.isCursor)
        let otherLive = showsSlotDecodes ? [] : live.filter { !$0.isCursor }
        let slots = log.slotRows
        let cursorHz = model.modemCursorAudioHz
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    SectionHeader("Decodes")
                    Text("\(slots.count + live.count)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                    Spacer()
                }
                .padding(.vertical, 3)
                if cursorRows.isEmpty && slots.isEmpty && otherLive.isEmpty {
                    EmptyRow(text: showsSlotDecodes ? "Decodes appear at the end of each slot" : "No signals in the passband yet")
                }
                ForEach(cursorRows) { row in
                    LiveRow(row: row, expanded: expansion(of: row.id))
                }
                ForEach(slots) { row in
                    SlotRow(row: row, isAtCursor: ModemPanelFormat.slotRowIsAtCursor(row, cursorAudioHz: cursorHz))
                }
                ForEach(otherLive) { row in
                    LiveRow(row: row, expanded: expansion(of: row.id))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .onHover { model.setRowHold($0) }
        .onDisappear { model.setRowHold(false) }
        .overlay(alignment: .bottom) {
            if let pill = ModemPanelFormat.newRowsPill(log.heldNewCount) {
                Button { model.releaseHeldRows() } label: {
                    Text(pill)
                        .font(.callout.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .foregroundStyle(.black)
                        .background(Capsule().fill(Theme.accent))
                }
                .buttonStyle(.plain)
                .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
                .padding(.bottom, 8)
                .transition(.opacity)
            }
        }
        .animation(.snappy(duration: 0.15), value: log.heldNewCount)
    }

    private func expansion(of id: Int) -> Binding<Bool> {
        Binding(get: { expandedRows.contains(id) },
                set: { on in
                    if on { expandedRows.insert(id) } else { expandedRows.remove(id) }
                })
    }
}

private struct EmptyRow: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.tertiary)
            .padding(.vertical, 4)
            .padding(.leading, 18)
    }
}

/// A tracked signal: frequency, mode, its recent text, SNR. The cursor's row is amber with
/// wrapping 18 pt text; the others keep one 16 pt line that scrolls left (the head truncates).
/// Clicking the line selects the row; its history, once disclosed, is selectable text.
private struct LiveRow: View {
    @Environment(AppModel.self) private var model
    let row: DecodeRow
    @Binding var expanded: Bool
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: row.isCursor ? .top : .firstTextBaseline, spacing: 10) {
                Button { expanded.toggle() } label: {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .frame(width: 10)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(expanded ? "Hide this signal's history" : "Show this signal's full history")
                VStack(alignment: .trailing, spacing: 1) {
                    Text(ModemPanelFormat.frequency(row.frequencyHz))
                        .font(.system(size: 13, weight: .medium).monospacedDigit())
                        .foregroundStyle(row.isCursor ? Theme.modemCursor : Theme.accent)
                    Text(ModemPanelFormat.modeLabel(row))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .frame(width: 84, alignment: .trailing)
                if row.isCursor {
                    Text(row.recentText.isEmpty ? "…" : row.recentText)
                        .font(.system(size: 18, design: .monospaced))
                        .foregroundStyle(.primary)
                        .lineLimit(4)
                        .truncationMode(.head)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(ModemPanelFormat.singleLine(row.recentText))
                        .font(.system(size: 16, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.head)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Text(ModemPanelFormat.snr(row.snrDb))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 52, alignment: .trailing)
            }
            .contentShape(Rectangle())
            .onTapGesture { model.selectRow(row.id) }
            .help(row.isCursor ? "Click to unlock the cursor" : "Click to lock the cursor on this signal")
            if expanded {
                ScrollView {
                    Text(row.history.isEmpty ? "Nothing decoded yet" : row.history)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(row.history.isEmpty ? .secondary : .primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 5).fill(.black.opacity(0.25)))
                .padding(.leading, 20)
            }
        }
        .padding(.vertical, row.isCursor ? 6 : 3)
        .padding(.horizontal, 8)
        .background(background)
        .overlay(alignment: .leading) {
            if row.isCursor {
                Rectangle().fill(Theme.modemCursor).frame(width: 3)
            }
        }
        .opacity(row.isQuiet && !row.isCursor ? 0.45 : 1)
        .onHover { hovering = $0 }
    }

    @ViewBuilder private var background: some View {
        if row.isCursor {
            LinearGradient(colors: [Theme.modemCursor.opacity(0.22), Theme.modemCursor.opacity(0.03)],
                           startPoint: .leading, endPoint: .trailing)
        } else {
            RoundedRectangle(cornerRadius: 5).fill(hovering ? Color.white.opacity(0.06) : Color.clear)
        }
    }
}

/// One FT8/WSPR message: "HHMMSS  SNR  freq  message"; amber when the cursor is on its signal.
private struct SlotRow: View {
    @Environment(AppModel.self) private var model
    let row: DecodeRow
    let isAtCursor: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Text(row.mode?.label ?? "")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .leading)
            Text(ModemPanelFormat.slotRow(row))
                .font(.system(size: 16, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 5).fill(
            isAtCursor ? Theme.modemCursor.opacity(0.18) : (hovering ? Color.white.opacity(0.06) : Color.clear)))
        .overlay(alignment: .leading) {
            if isAtCursor {
                Rectangle().fill(Theme.modemCursor).frame(width: 3)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.selectRow(row.id) }
        .onHover { hovering = $0 }
        .help("Click to analyse this signal on the bench")
    }
}
