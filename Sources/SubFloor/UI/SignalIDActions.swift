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

    /// Whether anything is there to keep: a name, an extent, or energy over the noise ("Too weak"). Not the noise
    /// family, which is how the identifier says "No signal" and "Too soon after tuning".
    static func canBookmark(_ identity: SignalIdentity) -> Bool {
        identity.measurement.family != .noise
    }

    /// What the bookmark and the card are called: the match, else the family, else what there is to say.
    static func name(_ identity: SignalIdentity) -> String {
        if let best = identity.best { return best.name }
        if identity.measurement.occupiedBandwidthHz > 0, let family = identity.summary["Family"] { return family }
        return canBookmark(identity) ? "Unidentified signal" : (identity.note ?? "No signal")
    }

    /// The label and parameters for the clipboard, with the frequency of the signal `atHz`.
    static func copyText(_ identity: SignalIdentity, atHz: Double) -> String {
        var lines = [identity.label]
        if canBookmark(identity) { lines.append("Frequency: \(FrequencyFormatter.grouped(atHz)) Hz") }
        lines += parameters(identity).map { "\($0.name): \($0.value)" }
        return lines.joined(separator: "\n")
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
        case "RTTY", "NAVTEX / SITOR-B", "PSK31 / PSK63", "FT8 / FT4", "WSPR", "Olivia", "MFSK16",
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
