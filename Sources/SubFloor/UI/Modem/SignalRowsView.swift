import Modems
import SwiftUI

/// The decoded signals: "Live" (the cursor's row pinned first in amber, then every tracked signal
/// in `DecodeLog`'s frozen frequency order) and "Slot decodes" (FT8/WSPR messages, newest slot
/// first), each under a collapsible header.
///
/// Clicking a row locks the cursor on its signal (the cursor's row unlocks it); a row's disclosure
/// shows its full history. While the pointer is over the list new rows are held (`setRowHold`), and
/// a floating "N new ↓" pill shows them.
struct SignalRowsView: View {
    @Environment(AppModel.self) private var model
    /// Whether FT8/WSPR are decoding (the section also shows while it has rows).
    let showsSlotSection: Bool
    @State private var liveExpanded = true
    @State private var slotExpanded = true
    @State private var expandedRows: Set<Int> = []

    var body: some View {
        let log = model.decodeLog
        let live = log.liveRows
        let slots = log.slotRows
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                SectionToggle(title: "Live", count: live.count, expanded: $liveExpanded)
                if liveExpanded {
                    if live.isEmpty {
                        EmptyRow(text: "No signals in the box yet")
                    }
                    ForEach(live) { row in
                        LiveRow(row: row, expanded: expansion(of: row.id))
                    }
                }
                if showsSlotSection || !slots.isEmpty {
                    SectionToggle(title: "Slot decodes", count: slots.count, expanded: $slotExpanded)
                        .padding(.top, 6)
                    if slotExpanded {
                        if slots.isEmpty {
                            EmptyRow(text: "Decodes appear at the end of each slot")
                        }
                        ForEach(slots) { row in
                            SlotRow(row: row)
                        }
                    }
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

/// A section header with its row count and a disclosure chevron.
private struct SectionToggle: View {
    let title: String
    let count: Int
    @Binding var expanded: Bool

    var body: some View {
        Button { withAnimation(.snappy) { expanded.toggle() } } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                SectionHeader(title)
                Text("\(count)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 3)
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

/// One FT8/WSPR message: "HHMMSS  SNR  freq  message".
private struct SlotRow: View {
    @Environment(AppModel.self) private var model
    let row: DecodeRow
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
        .background(RoundedRectangle(cornerRadius: 5).fill(hovering ? Color.white.opacity(0.06) : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture { model.selectRow(row.id) }
        .onHover { hovering = $0 }
        .help("Click to lock the cursor on this signal")
    }
}
