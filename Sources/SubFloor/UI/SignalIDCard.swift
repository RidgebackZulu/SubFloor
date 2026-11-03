import AppKit
import SignalID
import SubFloorCore
import SwiftUI

/// Signal ID's card for the signal at `atHz` (display Hz), shown in a popover at a right click: what it is (the
/// name, or the family when nothing is sure enough to name), how sure, whether a decoder confirmed it, the measured
/// parameters, the other candidates and the evidence, any text a trial decode heard; and **Tune**, **Bookmark** and
/// **Copy**. Several signals under the point are listed first, each with its frequency, name and its own **Tune**; the
/// rest of the card is the one nearest the point.
///
/// `identity` nil is either "Identifying…" (`pending`) or no data to identify from (the radio stopped, or retuned
/// meanwhile). `measuring`: `identity` is the first pass's answer and a longer read (or, `decoding`, a trial decode)
/// is running.
struct SignalIDCard: View {
    @Environment(AppModel.self) private var model
    let identity: SignalIdentity?
    let atHz: Double
    var pending = false
    var measuring = false
    var decoding = false
    var close: () -> Void = {}

    @State private var bookmarked = false
    @State private var copied = false

    private static let width: CGFloat = 340
    /// Evidence lines shown, notes included.
    private static let evidenceLines = 8
    /// Signals listed before the list scrolls.
    private static let memberRows = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let identity {
                let members = SignalIDText.members(identity, fallbackCenterHz: fallbackCenterHz(identity))
                if !members.isEmpty { signals(members) }
                if identity.measurement.occupiedBandwidthHz > 0 { details(identity, nearest: !members.isEmpty) }
                else if let note = identity.note, identity.best == nil, note != title(identity) { caveat(note) }
            }
            Divider()
            buttons
        }
        .padding(14)
        .frame(width: Self.width, alignment: .leading)
    }

    // MARK: Head

    private func title(_ identity: SignalIdentity) -> String {
        // Several signals, and a comb's line, are what the label says they are: the group, the interference.
        if !identity.signals.isEmpty || identity.comb != nil { return identity.label }
        return identity.best == nil && identity.measurement.occupiedBandwidthHz == 0 ? identity.label : SignalIDText.name(identity)
    }

    /// The centre a group's offsets are from when it doesn't carry its own: the card's signal less its offset.
    private func fallbackCenterHz(_ identity: SignalIdentity) -> Double { atHz - identity.measurement.offsetHz }

    /// The head's confidence is the answer's own: for several signals each row carries its own instead.
    private func headBest(_ identity: SignalIdentity) -> ModeMatch? { identity.signals.isEmpty ? identity.best : nil }

    @ViewBuilder private var header: some View {
        if let identity {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title(identity)).font(.system(size: 17, weight: .semibold)).lineLimit(2)
                    Spacer(minLength: 4)
                    if let best = headBest(identity) {
                        Text("\(Int((100 * best.confidence).rounded()))%")
                            .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    }
                }
                Text(subtitle(identity)).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                if let best = headBest(identity) { ConfidenceBar(value: best.confidence).frame(height: 5) }
                HStack(spacing: 8) {
                    if identity.confirmedByDecode {
                        Label("Confirmed by decode", systemImage: "checkmark.seal.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.green)
                    }
                    if measuring {
                        ProgressView().controlSize(.mini)
                        Text(decoding ? "Trying a decode…" : "Measuring longer…").font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } else if pending {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Identifying…").font(.system(size: 17, weight: .semibold))
                    Text(frequency).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("Nothing to read").font(.system(size: 17, weight: .semibold))
                Text("The radio is stopped, or was retuned while this was being read.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text(frequency).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
            }
        }
    }

    private var frequency: String { FrequencyFormatter.grouped(atHz) + " Hz" }

    /// The frequency, and the family when the title is the name (no mode named when it is the family).
    private func subtitle(_ identity: SignalIdentity) -> String {
        if !identity.signals.isEmpty { return "\(identity.signals.count) signals under the pointer" }
        guard identity.measurement.occupiedBandwidthHz > 0, identity.comb == nil else { return frequency }
        guard identity.best != nil, let family = identity.summary["Family"] else { return "\(frequency) · no mode named" }
        return "\(frequency) · \(family)"
    }

    // MARK: Body

    /// Each signal under the point: its frequency, its name (a likely one marked not measured) and a Tune that plans
    /// its own tuning.
    private func signals(_ members: [SignalIDText.Member]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            let rows = VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(members.enumerated()), id: \.offset) { _, member in
                    HStack(spacing: 8) {
                        Text(FrequencyFormatter.grouped(member.hz)).font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Text(member.name).font(.system(size: 12)).lineLimit(1)
                            .foregroundStyle(member.identity.best == nil ? .secondary : .primary)
                        Spacer(minLength: 4)
                        Button("Tune") {
                            model.tuneToMember(member)
                            close()
                        }
                        .controlSize(.small)
                        .help("Tune to this signal with the matched mode's demodulator")
                    }
                }
            }
            if members.count > Self.memberRows {
                ScrollView { rows }.frame(height: CGFloat(Self.memberRows) * 22)
            } else {
                rows
            }
        }
    }

    private func details(_ identity: SignalIdentity, nearest: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            if nearest {
                Text("Nearest the pointer · \(frequency)").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 3) {
                ForEach(SignalIDText.parameters(identity), id: \.name) { row in
                    GridRow {
                        Text(row.name).foregroundStyle(.secondary)
                        Text(row.value).font(.system(size: 12, design: .monospaced))
                            .gridColumnAlignment(.leading)
                    }
                }
            }
            .font(.system(size: 12))
            if !identity.alternatives.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(identity.best == nil ? "Could be" : "Could also be").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    ForEach(identity.alternatives, id: \.name) { alt in
                        HStack(spacing: 8) {
                            Text(alt.name).font(.system(size: 12)).lineLimit(1)
                            Spacer(minLength: 4)
                            ConfidenceBar(value: alt.confidence).frame(width: 56, height: 4)
                            Text("\(Int((100 * alt.confidence).rounded()))%")
                                .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                                .frame(width: 34, alignment: .trailing)
                        }
                    }
                }
            }
            let evidence = Array(SignalIDText.evidence(identity).prefix(Self.evidenceLines))
            if !evidence.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Why").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    ForEach(evidence, id: \.self) { line in
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            Text("•")
                            Text(line).fixedSize(horizontal: false, vertical: true)
                        }
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
            if let heard = identity.decodedText { decoded(heard) }
            if let note = identity.note { caveat(note) }
        }
    }

    /// A trial decode's text, shown as words heard on the air (untrusted radio text), verbatim.
    private func decoded(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Heard on the air (decoded)").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            Text(verbatim: text).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The answer's note, each of its parts on a line of its own (a ring that reached back only 30 s, a look-back).
    private func caveat(_ note: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(SignalIDText.noteLines(note).enumerated()), id: \.offset) { _, line in
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Image(systemName: "info.circle").font(.system(size: 11))
                    Text(verbatim: line).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .font(.system(size: 11)).foregroundStyle(.orange)
    }

    // MARK: Buttons

    private var buttons: some View {
        HStack(spacing: 8) {
            Button("Tune") {
                if let identity { model.tuneToIdentified(identity, atHz: atHz) } else { model.setVFO(atHz) }
                close()
            }
            // Not the default action: Return in the popover would retune and change the demod and passband.
            .help("Tune to the signal with the matched mode's demodulator")
            Button {
                guard let identity, model.bookmarkIdentified(identity, atHz: atHz) != nil else { return }
                bookmarked = true
            } label: {
                Label(bookmarked ? "Bookmarked" : "Bookmark", systemImage: bookmarked ? "checkmark" : "flag")
            }
            .disabled(identity.map { !SignalIDText.canBookmark($0) } ?? true || bookmarked)
            .help(identity.map { SignalIDText.canBookmark($0) } == true
                  ? "Bookmark the signal in the “Identified” group, with the ID in the notes"
                  : identity?.comb != nil ? "Interference, not a station: nothing to bookmark" : "No signal to bookmark")
            Button {
                guard let identity else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(SignalIDText.copyText(identity, atHz: atHz,
                                                                     fallbackCenterHz: fallbackCenterHz(identity)),
                                               forType: .string)
                copied = true
            } label: {
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .disabled(identity == nil)
            .help("Copy the ID and its parameters")
            Spacer(minLength: 0)
        }
        .controlSize(.regular)
    }
}

/// A 0…1 bar on a faint track.
private struct ConfidenceBar: View {
    let value: Float

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule().fill(Theme.accent).frame(width: geo.size.width * CGFloat(min(max(value, 0), 1)))
            }
        }
    }
}
