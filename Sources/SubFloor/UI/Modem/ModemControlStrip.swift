import Modems
import SwiftUI

/// The modem panel's top strip: the mode, then the signal count, the decode band (the receiver's
/// passband) and, while FT8/WSPR decode, their slot progress.
struct ModemControlStrip: View {
    @Environment(AppModel.self) private var model
    let status: ModemPanelStatus
    @Binding var expanded: Bool

    var body: some View {
        HStack(spacing: 12) {
            Button { withAnimation(.snappy) { expanded.toggle() } } label: {
                Image(systemName: "chevron.right").rotationEffect(.degrees(expanded ? 90 : 0))
            }
            .buttonStyle(.plain)
            .help(expanded ? "Hide the modem panel" : "Show the modem panel")
            SectionHeader("Modem")

            Picker("Mode", selection: Binding(get: { model.modemSettings.mode }, set: { model.setModemMode($0) })) {
                ForEach(ModemPanelFormat.modeChoices, id: \.self) { mode in
                    Text(ModemPanelFormat.label(of: mode)).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 260)

            Spacer(minLength: 8)

            if status.isOn {
                if !status.slotModes.isEmpty {
                    SlotProgressView(modes: status.slotModes)
                }
                if let outcome = status.slotOutcomeText {
                    Text(outcome)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help("The last slot of each mode: how many messages it decoded, or skipped because some of its audio was missing")
                }
                ModemSignalCount()
                Text(status.bandText)
                    .foregroundStyle(status.boxActive ? Theme.modemBox : Color.secondary)
                    .lineLimit(1)
                    .help("The audio band decoded: the receiver's passband, above the dial")
            }
        }
        .font(.callout.monospacedDigit())
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

/// "3 signals". Its own view so that only it re-renders when the decode log changes (10 Hz), not
/// the strip and its segmented pickers.
private struct ModemSignalCount: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Text(model.modemSignalCountText)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

/// A thin bar and the seconds to go, per running slot mode, ticking with the UTC clock.
private struct SlotProgressView: View {
    @Environment(AppModel.self) private var model
    let modes: [ModeID]

    /// One mode's bar, gap, text and the gap to the next.
    private static let barWidth: CGFloat = 54
    private static let itemWidth: CGFloat = 54 + 5 + 72 + 10

    var body: some View {
        // Whole seconds on a fixed schedule (a `.now` start, made in `body`, restarted the timeline
        // with every re-render of the strip), drawn in a fixed-size Canvas: a tick only redraws, it
        // never re-lays out the strip and re-measures its segmented pickers. As views ticking twice
        // a second, the bars and texts cost about a tenth of a core on the Mac.
        TimelineView(.periodic(from: Date(timeIntervalSinceReferenceDate: 0), by: 1)) { context in
            let now = context.date.addingTimeInterval(model.engine.modemWorker.clockOffset)
            let progress = modes.compactMap { ModemPanelFormat.slotProgress($0, at: now) }
            Canvas { ctx, size in
                var x: CGFloat = 0
                for p in progress {
                    let track = CGRect(x: x, y: size.height / 2 - 2, width: Self.barWidth, height: 4)
                    ctx.fill(Path(roundedRect: track, cornerRadius: 2), with: .color(.white.opacity(0.08)))
                    let done = CGRect(x: x, y: track.minY, width: max(2, Self.barWidth * CGFloat(p.fraction)), height: 4)
                    ctx.fill(Path(roundedRect: done, cornerRadius: 2), with: .color(Theme.modemBox.opacity(0.8)))
                    ctx.draw(Text(p.text).font(.caption.monospacedDigit()).foregroundStyle(.secondary),
                             at: CGPoint(x: x + Self.barWidth + 5, y: size.height / 2), anchor: .leading)
                    x += Self.itemWidth
                }
            }
            .frame(width: CGFloat(modes.count) * Self.itemWidth - 10, height: 16)
        }
        .help("Seconds until the next UTC slot")
    }
}
