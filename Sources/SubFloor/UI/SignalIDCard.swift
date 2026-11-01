import AppKit
import SignalID
import SubFloorCore
import SwiftUI

/// Signal ID's card for the signal at `atHz` (display Hz), shown in a popover at a right click: what it is (the
/// name, or the family when nothing is sure enough to name), how sure, whether a decoder confirmed it, the measured
/// parameters, the other candidates and the evidence; and **Tune**, **Bookmark** and **Copy**.
///
/// `identity` nil is either "Identifying…" (`pending`) or no data to identify from (the radio stopped, or retuned
/// meanwhile). `measuring`: `identity` is the first pass's answer and a longer read is running.
struct SignalIDCard: View {
    @Environment(AppModel.self) private var model
    let identity: SignalIdentity?
    let atHz: Double
    var pending = false
    var measuring = false
    var close: () -> Void = {}

    @State private var bookmarked = false
    @State private var copied = false

    private static let width: CGFloat = 340
    /// Evidence lines shown, notes included.
    private static let evidenceLines = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let identity {
                if identity.measurement.occupiedBandwidthHz > 0 { details(identity) }
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
        identity.best == nil && identity.measurement.occupiedBandwidthHz == 0 ? identity.label : SignalIDText.name(identity)
    }

    @ViewBuilder private var header: some View {
        if let identity {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title(identity)).font(.system(size: 17, weight: .semibold)).lineLimit(2)
                    Spacer(minLength: 4)
                    if let best = identity.best {
                        Text("\(Int((100 * best.confidence).rounded()))%")
                            .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    }
                }
                Text(subtitle(identity)).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                if let best = identity.best { ConfidenceBar(value: best.confidence).frame(height: 5) }
                HStack(spacing: 8) {
                    if identity.confirmedByDecode {
                        Label("Confirmed by decode", systemImage: "checkmark.seal.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.green)
                    }
                    if measuring {
                        ProgressView().controlSize(.mini)
                        Text("Measuring longer…").font(.system(size: 11)).foregroundStyle(.secondary)
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
        guard identity.measurement.occupiedBandwidthHz > 0 else { return frequency }
        guard identity.best != nil, let family = identity.summary["Family"] else { return "\(frequency) · no mode named" }
        return "\(frequency) · \(family)"
    }

    // MARK: Body

    private func details(_ identity: SignalIdentity) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
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
            let evidence = Array(((identity.best?.evidence ?? []) + identity.measurement.notes)
                .reduce(into: [String]()) { if !$1.isEmpty, !$0.contains($1) { $0.append($1) } }
                .prefix(Self.evidenceLines))
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
            if let note = identity.note { caveat(note) }
        }
    }

    private func caveat(_ note: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: "info.circle").font(.system(size: 11))
            Text(note).fixedSize(horizontal: false, vertical: true)
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
                  ? "Bookmark the signal in the “Identified” group, with the ID in the notes" : "No signal to bookmark")
            Button {
                guard let identity else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(SignalIDText.copyText(identity, atHz: atHz), forType: .string)
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
