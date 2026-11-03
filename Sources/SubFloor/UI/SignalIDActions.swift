import DSPCore
import Foundation
import SignalID
import SubFloorCore

/// The words of Signal ID's hover line and ID card: pure, so the tests read them without a view.
enum SignalIDText {
    /// The hover line: "Identifying…" while the first answer is pending, the identity's label (with " · measuring…"
    /// while the longer read runs), or nil when there is nothing to say. For no name the label is the family and its
    /// parameters, or the note ("Too weak to identify (SNR 2 dB)", "No signal").
    static func hoverLine(identity: SignalIdentity?, pending: Bool, measuring: Bool) -> String? {
        guard let identity else { return pending ? "Identifying…" : nil }
        return identity.label + (measuring ? " · measuring…" : "")
    }

    /// The card's parameter rows in reading order: what `SignalIdentity.summary` has, less the name and confidence
    /// the card shows in its head.
    static func parameters(_ identity: SignalIdentity) -> [(name: String, value: String)] {
        let summary = identity.summary
        return order.compactMap { name in summary[name].map { (name, $0) } }
    }

    private static let order = ["Family", "Bandwidth", "SNR", "Envelope", "Symbol rate", "Shift", "Tones",
                                "Tone spacing", "PSK order", "Carrier spacing", "Deviation", "Speed", "Burst period",
                                "Duty", "Subcarriers", "Period", "Audio", "Read"]

    /// Whether anything is there: a name, an extent, or energy over the noise ("Too weak"). Not the noise family,
    /// which is how the identifier says "No signal" and "Too soon after tuning".
    static func hasSignal(_ identity: SignalIdentity) -> Bool {
        identity.measurement.family != .noise
    }

    /// Whether there is anything to keep: a signal (`hasSignal`), and not an interference comb's line, which is no
    /// station.
    static func canBookmark(_ identity: SignalIdentity) -> Bool {
        hasSignal(identity) && identity.comb == nil
    }

    /// What the bookmark and the card are called: the match, else the family, else what there is to say.
    static func name(_ identity: SignalIdentity) -> String {
        if let best = identity.best { return best.name }
        if identity.measurement.occupiedBandwidthHz > 0, let family = identity.summary["Family"] { return family }
        return hasSignal(identity) ? "Unidentified signal" : (identity.note ?? "No signal")
    }

    /// The label and parameters for the clipboard, with the frequency of the signal `atHz`; the signals under the point
    /// (frequencies from `fallbackCenterHz` when the answer has no capture centre of its own) and any decoded text.
    static func copyText(_ identity: SignalIdentity, atHz: Double, fallbackCenterHz: Double? = nil) -> String {
        var lines = [identity.label]
        if hasSignal(identity) { lines.append("Frequency: \(FrequencyFormatter.grouped(atHz)) Hz") }
        lines += parameters(identity).map { "\($0.name): \($0.value)" }
        for member in members(identity, fallbackCenterHz: fallbackCenterHz ?? atHz - identity.measurement.offsetHz) {
            lines.append("\(FrequencyFormatter.grouped(member.hz)) Hz: \(member.name)")
        }
        if let heard = decodedLine(identity) { lines.append(heard) }
        return lines.joined(separator: "\n")
    }

    // MARK: Several signals

    /// One of several signals under the point: where it is (display Hz), what to call it, and its own answer (Tune
    /// plans its own tuning from it).
    struct Member: Equatable {
        var hz: Double
        var name: String
        var identity: SignalIdentity
    }

    /// The capture centre `identity`'s signals and group span are relative to: its own (`captureCenterHz`), which a
    /// recentred read keeps apart from the top-level offset's, else `fallbackCenterHz`.
    static func groupCenterHz(_ identity: SignalIdentity, fallbackCenterHz: Double) -> Double {
        identity.captureCenterHz ?? fallbackCenterHz
    }

    /// The signals under the point, lowest first, in display Hz: empty for one signal.
    static func members(_ identity: SignalIdentity, fallbackCenterHz: Double) -> [Member] {
        let centre = groupCenterHz(identity, fallbackCenterHz: fallbackCenterHz)
        return identity.signals
            .map { Member(hz: centre + $0.measurement.offsetHz, name: memberName($0), identity: $0) }
            .sorted { $0.hz < $1.hz }
    }

    /// A connected group of one slot mode's whole span, in display Hz (nil: not one).
    static func groupSpanHz(_ identity: SignalIdentity, fallbackCenterHz: Double) -> ClosedRange<Double>? {
        let centre = groupCenterHz(identity, fallbackCenterHz: fallbackCenterHz)
        return identity.groupSpanHz.map { (centre + $0.lowerBound)...(centre + $0.upperBound) }
    }

    /// What a signal named only from its measured neighbours is called: likely that mode, never the plain name. Nil
    /// for one measured itself.
    static func inheritedLabel(_ identity: SignalIdentity) -> String? {
        guard identity.best == nil, identity.nameInherited, let likely = identity.alternatives.first else { return nil }
        return "likely \(likely.name) · not measured"
    }

    /// A member's line on the card: its name and how sure, `likely FT8 · not measured` for one that took its
    /// neighbour's, else its family and numbers (or what there is to say).
    static func memberName(_ identity: SignalIdentity) -> String {
        if let best = identity.best { return "\(best.name) · \(Int((100 * best.confidence).rounded()))%" }
        return inheritedLabel(identity) ?? identity.label
    }

    // MARK: Evidence

    /// The card's line for transmissions on a slot mode's UTC slots.
    static func slotLine(periodSeconds: Double) -> String {
        let period = periodSeconds == periodSeconds.rounded() ? String(format: "%.0f", periodSeconds)
            : String(format: "%g", periodSeconds)
        return "transmissions start on \(period) s UTC boundaries"
    }

    /// The card's line for an FSK whose two tones were seen taking turns.
    static let takingTurnsLine = "the two tones take turns"

    /// The slot evidence the measurement holds, as the identifier counts it (`SignalIdentifier.minSlotFit` over
    /// `minSlotEvents` events at least): the best-fitting period's line, nil without one (or without a true time).
    static func slotEvidence(_ m: SignalMeasurement) -> String? {
        let good = m.slotFits.filter {
            $0.fit >= SignalIdentifier.minSlotFit && $0.events >= SignalIdentifier.minSlotEvents
        }
        guard let best = good.max(by: { ($0.fit, $0.events, $0.periodSeconds) < ($1.fit, $1.events, $1.periodSeconds) })
        else { return nil }
        return slotLine(periodSeconds: best.periodSeconds)
    }

    /// The measurer's note for tones seen taking turns (`SignalMeasurer`'s own reading of an FSK's tones).
    private static func isTakingTurnsNote(_ note: String) -> Bool { note.hasSuffix(" take turns") }

    /// Whether a 2-FSK's two tones were seen taking turns (its tones read directly), not only its numbers.
    static func takesTurns(_ m: SignalMeasurement) -> Bool {
        m.family == .fsk && (m.toneCount ?? 2) == 2 && m.notes.contains(where: isTakingTurnsNote)
    }

    /// Why it is what it is, for the card and agents: the slot evidence and the tones taking turns first, then the
    /// match's own evidence, then (with `notes`) the measurement's notes, each once. Decoded text is never among
    /// them: it is radio text (`decodedLine`).
    static func evidence(_ identity: SignalIdentity, notes: Bool = true) -> [String] {
        let m = identity.measurement
        let own = identity.best?.evidence ?? []
        var lines: [String] = []
        if let slot = slotEvidence(m), !own.contains(where: { $0.hasPrefix(slot) }) { lines.append(slot) }
        let turns = takesTurns(m)
        if turns { lines.append(takingTurnsLine) }
        if let comb = identity.comb {
            lines.append("one of \(comb.lineCount) lines \(FrequencyFormatter.short(comb.spacingHz)) apart across the capture: interference, not a station")
        }
        lines += own
        if notes { lines += m.notes.filter { !(turns && isTakingTurnsNote($0)) } }
        return lines.reduce(into: [String]()) { if !$1.isEmpty, !$0.contains($1) { $0.append($1) } }
    }

    /// A note's parts, one a line: the answer's notes are joined with "; ".
    static func noteLines(_ note: String) -> [String] {
        note.components(separatedBy: "; ").filter { !$0.isEmpty }
    }

    /// The decoded text, shown as what it is: words heard on the air, not SubFloor's. Nil without any.
    static func decodedLine(_ identity: SignalIdentity) -> String? {
        identity.decodedText.map { "Heard on the air (decoded): \($0)" }
    }

    /// A bookmark's notes: the label, the parameters, where the signal is and when it was identified (UTC).
    static func bookmarkNotes(_ identity: SignalIdentity, atHz: Double, now: Date) -> String {
        var lines = [identity.label]
        lines += parameters(identity).map { "\($0.name): \($0.value)" }
        lines.append("Signal at \(FrequencyFormatter.grouped(atHz)) Hz")
        if identity.confirmedByDecode { lines.append("Identification confirmed by decode") }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm 'UTC'"
        lines.append("Identified \(formatter.string(from: now))")
        return lines.joined(separator: "\n")
    }
}

/// How the card tunes: the demod a match is heard with, the passband it gets, and where the VFO goes for it.
enum SignalIDTuning {
    /// HF below this many Hz is heard in a sideband, above it in FM.
    static let hfLimitHz = 30e6
    /// A passband is 1.2 × the signal's width when that is wider than the mode's own.
    static let widthMargin = 1.2
    /// An SSB voice signal's suppressed carrier lies about this far outside its lower (USB) or upper (LSB) edge.
    static let carrierOffsetHz = 300.0

    /// What Tune does for an identity: the demod (nil: the mode stays), the passband and the VFO, all display Hz.
    struct Plan: Equatable {
        var demod: DemodMode?
        var bandwidthHz: Double?
        var vfoHz: Double
    }

    /// Tune's plan for `identity`, the signal at `atHz`. With no signal to hear: the frequency only.
    static func plan(for identity: SignalIdentity, atHz: Double) -> Plan {
        guard let demod = demod(for: identity, atHz: atHz) else { return Plan(demod: nil, bandwidthHz: nil, vfoHz: atHz) }
        let bandwidth = bandwidth(for: demod, identity: identity)
        return Plan(demod: demod, bandwidthHz: bandwidth,
                    vfoHz: vfo(for: demod, identity: identity, signalHz: atHz, bandwidth: bandwidth))
    }

    /// The demod for `identity` at `atHz`: its match's, else its family's; nil when there is no signal to hear (the
    /// mode stays as it is). A signal too wide for the demod's passband goes to a wider one that has the room
    /// (NFM → WFM, a sideband → AM).
    static func demod(for identity: SignalIdentity, atHz: Double) -> DemodMode? {
        let m = identity.measurement
        let heard: DemodMode?
        if let best = identity.best {
            heard = demod(forTableRow: best.name, family: m.family, atHz: atHz)
        } else if m.occupiedBandwidthHz > 0 {
            switch m.family {
            case .usb: heard = .usb
            case .lsb: heard = .lsb
            case .am: heard = .am
            case .fm: heard = .nfm
            case .wfm: heard = .wfm
            case .ook, .carrier: heard = .cw
            case .fsk, .mfsk, .psk, .ofdm, .unknown: heard = atHz < hfLimitHz ? .usb : .nfm
            case .noise: heard = nil
            }
        } else {
            heard = nil
        }
        guard let heard else { return nil }
        let wanted = widthMargin * m.occupiedBandwidthHz
        switch heard {
        case .usb where wanted > heard.bandwidthRange.upperBound, .lsb where wanted > heard.bandwidthRange.upperBound:
            return .am
        case .nfm where wanted > heard.bandwidthRange.upperBound: return .wfm
        default: return heard
        }
    }

    /// The demod for the mode table's row `name`: digital HF modes are heard in USB, as an operator does; SSB voice
    /// by its measured sideband, else the convention (LSB below 10 MHz).
    static func demod(forTableRow name: String, family: SignalFamily, atHz: Double) -> DemodMode? {
        switch name {
        case "SSB voice (USB/LSB)":
            switch family {
            case .usb: .usb
            case .lsb: .lsb
            default: atHz < 10e6 ? .lsb : .usb
            }
        case "CW": .cw
        case "AM voice/broadcast", "Time signal (WWV/WWVH/CHU)", "AM airband", "ACARS": .am
        case "RTTY", "NAVTEX / SITOR-B", "PSK31 / PSK63", "FT8", "FT4", "WSPR", "Olivia", "MFSK16",
             "ALE (MIL-STD-188-141)", "STANAG 4285", "HF fax", "DRM", "HFDL": .usb
        case "NFM voice", "APRS / AX.25", "POCSAG", "DMR", "P25 Phase 1", "NXDN", "D-STAR", "YSF (C4FM)", "AIS",
             "NOAA APT": .nfm
        case "WFM broadcast", "DAB": .wfm
        default: nil
        }
    }

    /// The passband for `identity` heard in `demod`: the mode's own width, or 1.2 × the signal's if wider (at the
    /// mode's step, within its range).
    static func bandwidth(for demod: DemodMode, identity: SignalIdentity) -> Double {
        let wanted = max(demod.defaultBandwidth, widthMargin * identity.measurement.occupiedBandwidthHz)
        let stepped = (wanted / demod.bandwidthStep).rounded(.up) * demod.bandwidthStep
        return min(max(stepped, demod.bandwidthRange.lowerBound), demod.bandwidthRange.upperBound).rounded()
    }

    /// Whether `identity` is voice in a sideband (a named SSB voice, or a sideband family nothing else named).
    static func isSSBVoice(_ identity: SignalIdentity) -> Bool {
        identity.best.map { $0.name == "SSB voice (USB/LSB)" }
            ?? (identity.measurement.family == .usb || identity.measurement.family == .lsb)
    }

    /// The VFO for a signal at `signalHz`. SSB voice is tuned by its carrier: the suppressed carrier lies about
    /// 300 Hz outside the signal's near edge, which puts the voice at its natural pitch. Anything else (a digital
    /// mode in a sideband too) has its passband centred on the signal (a sideband's starts 100 Hz from the carrier).
    static func vfo(for demod: DemodMode, identity: SignalIdentity, signalHz: Double, bandwidth: Double) -> Double {
        let width = identity.measurement.occupiedBandwidthHz
        if isSSBVoice(identity), width > 0 {
            switch demod {
            case .usb: return signalHz - width / 2 - carrierOffsetHz
            case .lsb: return signalHz + width / 2 + carrierOffsetHz
            default: break
            }
        }
        return signalHz - demod.passbandOffset(bandwidth: bandwidth)
    }
}

extension AppModel {
    /// Tunes to the signal `identity` is of, at `atHz` (display Hz, with HamItUp as it is): the VFO and the demod of
    /// the match (or its family's), the passband placed over the signal. With no signal to hear, only the frequency.
    func tuneToIdentified(_ identity: SignalIdentity, atHz: Double) {
        let plan = SignalIDTuning.plan(for: identity, atHz: atHz)
        if let demod = plan.demod, let bandwidth = plan.bandwidthHz {
            setMode(demod)
            setBandwidth(bandwidth)
        }
        setVFO(plan.vfoHz)
    }

    /// Tunes to one of several signals under the point (`SignalIDText.members`): its own plan, at its own frequency.
    func tuneToMember(_ member: SignalIDText.Member) {
        tuneToIdentified(member.identity, atHz: member.hz)
    }

    /// Bookmarks `identity` (the signal at `atHz`) in the "Identified" group: named after the match, tuned as
    /// `tuneToIdentified` would (the same plan, so selecting it reproduces Tune), the label, parameters and date in
    /// the notes. Nil when nothing is there.
    @discardableResult
    func bookmarkIdentified(_ identity: SignalIdentity, atHz: Double, now: Date = Date()) -> Bookmark.ID? {
        guard SignalIDText.canBookmark(identity) else { return nil }
        let plan = SignalIDTuning.plan(for: identity, atHz: atHz)
        return addBookmark(Bookmark(name: SignalIDText.name(identity), frequencyHz: plan.vfoHz,
                                    mode: plan.demod ?? mode, bandwidthHz: plan.bandwidthHz ?? bandwidthHz,
                                    upconverter: upconverter.enabled, group: "Identified",
                                    notes: SignalIDText.bookmarkNotes(identity, atHz: atHz, now: now)))
    }
}
