import Accelerate
import DSPCore
import Foundation

/// One named mode a signal may be, with how sure, and why.
public struct ModeMatch: Codable, Sendable, Equatable {
    public var name: String
    /// 0…1.
    public var confidence: Float
    public var evidence: [String]

    public init(name: String, confidence: Float, evidence: [String]) {
        self.name = name
        self.confidence = confidence
        self.evidence = evidence
    }
}

/// What Signal ID makes of one signal: the measurement, the named mode if it is sure enough, the other candidates,
/// and what to tell the owner.
public struct SignalIdentity: Codable, Sendable, Equatable {
    public var measurement: SignalMeasurement
    /// The named mode: nil below 0.7, or when another candidate is within 0.1 of it.
    public var best: ModeMatch?
    /// Up to 3 other candidates at 0.3 or more, the likeliest first.
    public var alternatives: [ModeMatch]
    /// The spec's slow-signal rules apply and no longer read has been made yet.
    public var needsLongerRead: Bool
    /// A running decoder decoded this signal (set by the app; the ID never decodes).
    public var confirmedByDecode: Bool
    /// "No signal", "Too weak to identify (SNR n dB)", "Too soon after tuning — try again", what the longer read
    /// held, "wider than the view".
    public var note: String?
    /// The signal is a line of an interference comb across the capture (`InterferenceComb`): never named.
    public var comb: CombInfo?

    public init(measurement: SignalMeasurement, best: ModeMatch? = nil, alternatives: [ModeMatch] = [],
                needsLongerRead: Bool = false, confirmedByDecode: Bool = false, note: String? = nil,
                comb: CombInfo? = nil) {
        self.measurement = measurement
        self.best = best
        self.alternatives = alternatives
        self.needsLongerRead = needsLongerRead
        self.confirmedByDecode = confirmedByDecode
        self.note = note
        self.comb = comb
    }

    /// The one-line text: `RTTY · 45.45 Bd · 170 Hz shift · 91%` when named, `2-FSK · 50 Bd · 850 Hz shift` when
    /// not, `Interference comb · 19.3 kHz spacing` on a comb's line, or the note when there is nothing to measure.
    public var label: String {
        if let comb { return "Interference comb · \(Self.hz(comb.spacingHz)) spacing" }
        if best == nil, measurement.family == .noise || measurement.occupiedBandwidthHz == 0, let note { return note }
        var parts = [best?.name ?? Self.familyName(measurement)] + Self.parameters(measurement)
        if let best { parts.append("\(Int((100 * best.confidence).rounded()))%") }
        return parts.joined(separator: " · ")
    }

    /// The parameters for the ID card, by name.
    public var summary: [String: String] {
        let m = measurement
        var out: [String: String] = ["Family": Self.familyName(m)]
        if let best {
            out["Name"] = best.name
            out["Confidence"] = "\(Int((100 * best.confidence).rounded()))%"
        }
        if m.occupiedBandwidthHz > 0 {
            out["Bandwidth"] = Self.hz(m.occupiedBandwidthHz)
            out["SNR"] = String(format: "%.0f dB", m.snrDb)
            out["Envelope"] = m.envelope.rawValue
        }
        if let v = m.symbolRate { out["Symbol rate"] = "\(Self.number(v)) Bd" }
        if let v = m.fskShiftHz { out["Shift"] = Self.hz(v) }
        if let v = m.toneCount { out["Tones"] = "\(v)" }
        if let v = m.toneSpacingHz { out["Tone spacing"] = Self.hz(v) }
        if let v = m.pskOrder { out["PSK order"] = "\(v)" }
        if let v = m.ofdmSpacingHz { out["Carrier spacing"] = Self.hz(v) }
        if let v = m.fmDeviationHz { out["Deviation"] = "±" + Self.hz(v) }
        if let v = m.cwWPM { out["Speed"] = String(format: "%.0f WPM", v) }
        if let v = m.burstPeriodSeconds { out["Burst period"] = String(format: "%.0f ms", 1000 * v) }
        if let v = m.burstDuty { out["Duty"] = String(format: "%.0f%%", 100 * v) }
        if !m.subcarriersHz.isEmpty { out["Subcarriers"] = m.subcarriersHz.map(Self.hz).joined(separator: ", ") }
        if let v = m.modulationPeriodSeconds { out["Period"] = String(format: "%.3f s", v) }
        if let v = m.audioEnvelope { out["Audio"] = v.rawValue }
        if m.seconds > 0 { out["Read"] = String(format: "%.1f s", m.seconds) }
        return out
    }

    /// The family as the line shows it: `2-FSK`, `BPSK`, `USB` …
    public static func familyName(_ m: SignalMeasurement) -> String {
        switch m.family {
        case .noise: "Noise"
        case .carrier: "Carrier"
        case .am: "AM"
        case .usb: "USB"
        case .lsb: "LSB"
        case .fm: "FM"
        case .wfm: "WFM"
        case .ook: "OOK"
        case .fsk: "\(m.toneCount ?? 2)-FSK"
        case .mfsk: "MFSK"
        case .psk: [2: "BPSK", 4: "QPSK", 8: "8PSK"][m.pskOrder ?? 0] ?? "PSK"
        case .ofdm: "OFDM"
        case .unknown: "Unknown"
        }
    }

    /// The family's parameters for the line.
    static func parameters(_ m: SignalMeasurement) -> [String] {
        var out: [String] = []
        let rate = m.symbolRate.map { "\(number($0)) Bd" }
        switch m.family {
        case .fsk:
            if let baud = m.symbolRate { out.append("\(number(wholeWhenClose(baud))) Bd") }
            if m.toneCount ?? 2 == 2, let shift = m.fskShiftHz ?? m.toneSpacingHz {
                out.append("\(hz(shift)) shift")
            } else if let spacing = m.toneSpacingHz {
                out.append("\(hz(spacing)) spacing")
            }
        case .mfsk:
            if let n = m.toneCount { out.append("\(n) tones") }
            if let rate { out.append(rate) }
        case .psk:
            if let rate { out.append(rate) }
        case .ook:
            if let wpm = m.cwWPM { out.append(String(format: "%.0f WPM", wpm)) }
        case .fm, .wfm:
            if let deviation = m.fmDeviationHz { out.append("±\(hz(deviation))") }
            let subcarriers = m.subcarriersHz.filter { abs($0 - 19_000) > 200 }
            if !subcarriers.isEmpty { out.append("subcarrier \(subcarriers.map { hz($0) }.joined(separator: "/"))") }
        case .ofdm:
            if let spacing = m.ofdmSpacingHz { out.append("\(hz(spacing)) spacing") }
            out.append(hz(m.occupiedBandwidthHz))
        case .am, .usb, .lsb, .unknown:
            if m.occupiedBandwidthHz > 0 { out.append(hz(m.occupiedBandwidthHz)) }
        case .carrier, .noise:
            break
        }
        return out
    }

    /// A measured reading's speed lies within about 0.03% of what is sent.
    static let wholeTolerance = 0.0008

    /// A measured speed within its error of a whole number shows as that number: 74.98 as 75, and 45.45 and 56.25 stay.
    static func wholeWhenClose(_ baud: Double) -> Double {
        abs(baud - baud.rounded()) <= wholeTolerance * baud ? baud.rounded() : baud
    }

    /// Up to two decimals, trailing zeros dropped: 45.45, 50, 1.46, 4800.
    static func number(_ value: Double) -> String {
        if abs(value) >= 1000 { return String(format: "%.0f", value) }
        var text = String(format: "%.2f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    /// `170 Hz`, `6.25 Hz`, `2.8 kHz`, `1.54 MHz`.
    static func hz(_ value: Double) -> String {
        let a = abs(value)
        if a >= 1_000_000 { return String(format: "%.2f MHz", value / 1e6) }
        if a >= 1000 { return String(format: "%.1f kHz", value / 1e3) }
        if a >= 100 { return String(format: "%.0f Hz", value) }
        return "\(number(value)) Hz"
    }
}

/// Names a measured signal from the mode table (`ModeTable`), and runs the whole identification on a capture.
///
/// **Confidence.** Each row's parameter score (`ModeTable.score`: matching parameters and features add, mismatches
/// subtract, the family counting twice) is scaled by the measurement's own family confidence (min(1, 0.5 + it)),
/// then frequency hints add up to +0.15 inside a row's bands (a dial's reaching 2 kHz further, for a receiver tuned off) and,
/// for modes that live only there, take up to 0.15 outside. A slot row gains 0.15 more when the signal's transmissions fit
/// its own UTC slots over two events or more (`SignalMeasurement.slotFits`). Neither a hint nor slots can lift a match
/// whose parameters alone score under 0.55 to 0.7. A named row's caveat (what its numbers can't tell it from) joins its
/// evidence. A row is named at 0.7 or
/// more when no other is within 0.1 of it (neighbours that can't be told apart, DMR and P25 at an in-between
/// deviation, are listed instead); a signal wider than the view is never named (family only, ruling R5).
///
/// **The longer read** (the spec's slow-signal rules; `needsLongerRead`) when the first pass finds:
/// - a signal under 50 Hz wide, or keying slower than 10 WPM;
/// - a carrier on a read too short to resolve 1.46 Hz structure (under 8 s): it could be WSPR, so its family
///   confidence is held under 0.7 until the longer read (ruling R13);
/// - weak keying (CW under 15 dB): its −20 dB width, and so its SNR, read narrow on 3 s (ruling R12);
/// - a candidate that needs timing (WSPR, FT8 and FT4 slots, fax lines, time-signal ticks) at 0.4 or more, or at 0.2
///   inside its own frequencies, or an unidentified signal there.
public enum SignalIdentifier {
    public static let nameThreshold: Float = 0.7
    static let alternativeThreshold: Float = 0.3
    static let maxAlternatives = 3
    static let ambiguityMargin: Float = 0.1
    /// Parameters scoring under this can't be lifted to a name by a hint, or by a slot fit.
    static let hintFloor = 0.55
    /// A slot row's match gains `slotBonus` when the signal's transmissions fit its slots this well, over this many
    /// events at least (`SlotEvidence`; one edge fits FT4's grid by chance two times in three).
    static let minSlotFit: Float = 0.75
    static let minSlotEvents = 2
    static let slotBonus = 0.15
    static let firstSeconds = 3.0
    static let longSeconds = 16.0
    /// Under this much IQ is "Too soon after tuning — try again".
    public static let minimumSeconds = 1.0
    /// A read this long has had its longer read.
    static let longRead = 10.0
    static let narrowHz = 50.0
    static let slowWPM = 10.0
    static let weakKeyingDb = 15.0
    static let timingCandidate = 0.4
    static let hintedTimingCandidate = 0.2
    static let shortCarrierConfidence: Float = 0.6
    /// An unidentified signal of a slot mode's width in its sub-band is offered as it at this.
    static let slotOffer = 0.4
    /// The window the "Too weak" SNR is taken over when no extent is found (an SSB channel).
    static let defaultWindowHz = 2500.0
    static let searchBins = 4
    /// The neighbourhood looked at around the point (`neighbourhoodMap`), and the share of a capture that counts:
    /// its very edges are filter skirts.
    static let localWindowHz = 48_000.0
    static let usableCaptureShare = 0.9
    /// How far past a point in those edges the map still looks.
    static let pointMarginHz = 2000.0
    /// The map's resolutions. A frame 125 ms long sees FT8's tones (160 ms each) one at a time; a trace 50 Hz wide spans
    /// several of its 8 Hz bins, and a 3 s read makes 47 rows: enough to average noise down to about ±0.7 dB in a bin.
    static let mapBinHz = 8.0
    static let mapHopSeconds = 0.0625
    /// How far beyond what `TraceFinder` saw a measurement may look, for a narrow signal's skirts.
    static let seedRoomHz = 60.0
    static let seedRoomShare = 0.3
    /// How far a clear trace's skirts reach, in `tooWeak`'s average.
    static let clearSkirtHz = 40.0
    /// Energy over the noise across the default window that counts as too weak to identify (`tooWeak`).
    static let weakSNRDb = -3.5...6.0
    /// The noise beside `tooWeak`'s window comes from this many windows either side.
    static let weakNoiseWindows = 3
    /// The spectrum looked at for a very wide signal when the app has none: bins of about 500 Hz.
    static func wideSpectrum(_ iq: [Float], sampleRate: Double) -> [Float] {
        let size = spectrumSize(sampleRate: sampleRate, binHz: 500)
        return PowerSpectrum.average(iq, size: size, hop: size / 4)
    }

    /// Names `m`, measured at `rfHz` (display Hz), from the mode table. `readableDecode`: a trial decode gave readable
    /// text, which a row that requires it takes in place of its frequencies.
    public static func identify(_ m: SignalMeasurement, rfHz: Double, readableDecode: Bool = false) -> SignalIdentity {
        var m = m
        var longer = false
        let longEnough = m.seconds >= longRead
        if m.family == .noise {
            return SignalIdentity(measurement: m, note: noSignalNote)
        }
        // R13: a carrier on a short read could be WSPR's tones; it waits for the longer read.
        if m.family == .carrier && m.seconds < SignalMeasurer.minRefineSeconds {
            m.familyConfidence = min(m.familyConfidence, shortCarrierConfidence)
            m.notes.append("A carrier on a short read could be WSPR (4 tones 1.46 Hz apart): reading longer")
            longer = true
        }
        if !longEnough && m.occupiedBandwidthHz > 0 && m.occupiedBandwidthHz < narrowHz { longer = true }
        if !longEnough, m.family == .ook, (m.cwWPM ?? .infinity) < slowWPM || m.snrDb < weakKeyingDb { longer = true }

        let wider = m.notes.first { $0.contains("wider than the view") }
        let factor = min(1, 0.5 + Double(m.familyConfidence))
        // Ranked before clamping, so a hint still tells two full matches apart (AM airband from AM voice).
        var ranked: [(match: ModeMatch, raw: Double)] = []
        for row in ModeTable.rows {
            guard let (score, rowEvidence) = ModeTable.score(row, m, rfHz: rfHz) else {
                if row.needsTiming && m.family == .unknown && row.hinted(rfHz) && !longEnough { longer = true }
                continue
            }
            var evidence = rowEvidence
            // A family the row only partly accepts has no confidence of its own to scale by.
            let parameters = max(0, score) * (row.families.contains(m.family) ? factor : 1)
            var confidence = parameters
            let applicable = row.hints.filter { $0.families == nil || $0.families!.contains(m.family) }
            if let hint = applicable.first(where: { $0.contains(rfHz) }) {
                confidence += hint.inside
                evidence.append(String(format: "in the %@ (+%.2f)", hint.name, hint.inside))
            } else if let hint = applicable.max(by: { $0.outside < $1.outside }), hint.outside > 0 {
                confidence -= hint.outside
                evidence.append(String(format: "outside the %@ (−%.2f)", hint.name, hint.outside))
            }
            // Transmissions on the row's own UTC slots, two events of them at least: more for a match whose tones already
            // fit, never a name alone (the `hintFloor` clamp below).
            if row.slotted, let slot = m.slotFits.first(where: { $0.periodSeconds == row.slotPeriodSeconds }),
               slot.fit >= minSlotFit, slot.events >= minSlotEvents {
                confidence += slotBonus
                evidence.append(String(format: "transmissions start on %@ s UTC boundaries (+%.2f)",
                                       SignalIdentity.number(slot.periodSeconds), slotBonus))
            }
            if parameters < hintFloor { confidence = min(confidence, Double(nameThreshold) - 0.01) }
            if wider != nil { confidence = min(confidence, Double(nameThreshold) - 0.01) }
            if row.requiresHintOrDecode, !readableDecode, !row.hinted(rfHz), confidence >= Double(nameThreshold) {
                confidence = Double(nameThreshold) - 0.01
                evidence.append("its numbers alone don't name it: outside its frequencies, and no readable decode")
            }
            confidence = max(0, confidence)
            if row.needsTiming && !longEnough
                && (confidence >= timingCandidate || (parameters >= hintedTimingCandidate && row.hinted(rfHz))) {
                longer = true
            }
            ranked.append((ModeMatch(name: row.name, confidence: Float(min(1, confidence)), evidence: evidence),
                           confidence))
        }
        // A row told apart only by a period in its signal (a time signal's ticks, fax lines), at its own
        // frequencies, whose period the measurement doesn't show: what else fits can't be told from it (a time
        // signal is AM like a broadcast until its ticks show; 3 s can't show them, and 16 s at 10 dB may miss them).
        // Nothing is named: it is offered, scored with its period left open, and on a short read the longer read
        // is asked for.
        var held = false
        for row in ModeTable.rows where row.hasPeriod && row.hinted(rfHz) && !row.showsPeriod(m) {
            guard let (open, openEvidence) = ModeTable.score(row, m, rfHz: rfHz, periodOpen: true), open > 0 else { continue }
            held = true
            let hint = row.hints.first { $0.contains(rfHz) }?.inside ?? 0
            let offer = min(max(0, open) * factor + hint, Double(nameThreshold) - 0.01)
            ranked.removeAll { $0.match.name == row.name }
            ranked.append((ModeMatch(name: row.name, confidence: Float(offer),
                                     evidence: openEvidence + ["its period not seen: can't be told from what else fits"]),
                          offer))
            if m.seconds < ModulationPeriod.minSeconds { longer = true }
        }
        if held {
            let cap = Double(nameThreshold) - 0.01
            ranked = ranked.map { entry in
                var match = entry.match
                match.confidence = min(match.confidence, Float(cap))
                return (match, min(entry.raw, cap))
            }
        }
        // An unidentified signal in a slot mode's own frequencies, about as wide as one of its transmissions (FT8,
        // FT4): their symbols take a whole slot to show, so the row is offered (never named) and the longer read
        // asked for.
        if m.family == .unknown {
            for row in ModeTable.rows where row.slotted && row.hinted(rfHz) && !ranked.contains(where: { $0.match.name == row.name })
                && row.slotWidthsHz.contains(where: { (0.5 * $0)...(1.5 * $0) ~= m.occupiedBandwidthHz }) {
                ranked.append((ModeMatch(name: row.name, confidence: Float(slotOffer), evidence: [
                    String(format: "an unidentified %.0f Hz signal in the %@ sub-band", m.occupiedBandwidthHz, row.name),
                    "its symbols need a whole slot to show: reading longer",
                ]), slotOffer))
                if m.seconds < row.slotSeconds { longer = true }
            }
        }
        ranked.sort { $0.raw > $1.raw }

        var best: ModeMatch?
        if let top = ranked.first, top.match.confidence >= nameThreshold {
            let next = ranked.dropFirst().first?.raw ?? 0
            if top.raw - next >= Double(ambiguityMargin) { best = top.match }
        }
        let alternatives = ranked.map(\.match).filter { $0.name != best?.name && $0.confidence >= alternativeThreshold }
            .prefix(maxAlternatives)
        // A named FSK whose shift doesn't show how it is keyed (WSPR, MFSK16, FT8, FT4, Olivia): its width from its
        // parameters and its standard's keying, where the edges sit under the noise (R16).
        if let best, let shaping = ModeTable.row(best.name)?.shaping { ParameterWidth.apply(to: &m, shaping: shaping) }
        // What its numbers can't tell it from.
        if var named = best, let caveat = ModeTable.row(named.name)?.caveat {
            named.evidence.append(caveat)
            best = named
        }
        return SignalIdentity(measurement: m, best: best, alternatives: Array(alternatives), needsLongerRead: longer,
                              note: wider)
    }

    /// The whole identification at `atHz` (display Hz) in a capture centred on `captureCenterHz`:
    /// - where to measure: `bandwidthHz` (an agent's), honoured as it is; otherwise what the read shows around the point
    ///   (`neighbourhood`, `TraceFinder`, `SignalGrouper`): the area the point lies in, or a trace within `pointRadiusHz` of
    ///   it, whose extent the measurement stays inside (`SignalMeasurer.Ceiling`). Nothing further out is looked for;
    /// - when those are tones that take turns, their own reading (`DirectFSK`) is the answer, if it shows a speed. If it
    ///   doesn't, the measurement goes first (what takes turns without keeping time may be fax), and only what that can't
    ///   name is called an FSK, with what the tones do show, when they changed too few times to show more;
    /// - a narrow trace (`mayBeNarrowMFSK`: FT8, FT4) may be an MFSK whose tones the map can't part: read symbol by symbol
    ///   (`symbolReading`, `SymbolTones`), that is the answer, unless the measurement found a carrier line. The quick first
    ///   answer (no `longer`) reads it only when the measurement says PSK, which a hopping trace can pass for, and asks
    ///   for the longer read when nothing names it; the longer read reads it over its longest transmission, and a reading
    ///   the first pass made stands if that one doesn't read (or reads PSK). A narrow trace measured PSK whose tones didn't
    ///   read, in a slot mode's frequencies, isn't named PSK (`heldForTones`): the quick answer asks for the longer read;
    /// - `endTime` (when the last sample of `iq`, and of the longer read, which ends where `iq` does, was on the air; nil
    ///   for a file or the demo source) puts the trace's on-times against the slot modes' UTC slots (`SlotEvidence`), into
    ///   `slotFits`: a good fit of two events or more raises a slot row whose tones already fit (`identify(_:rfHz:)`);
    /// - a very wide signal the neighbourhood can't see the edges of, only on positive evidence (`WideOccupancy`) in
    ///   `spectrumDb` (an averaged spectrum of the capture, FFT-shifted; worked out from the IQ when nil);
    /// - nothing there gives "Too weak to identify (SNR n dB)" or "No signal" (`tooWeak`);
    /// - the newest 3 s measured (`SignalMeasurer`) and named (`identify(_:rfHz:)`); under 1 s of IQ is "Too soon
    ///   after tuning — try again";
    /// - when the slow-signal rules apply and `longer` is given, it is called (up to 16 s of IQ, ending where
    ///   `iq` ends) and the signal measured and named again from the same extent: a slot mode (FT8, FT4) over its
    ///   longest transmission in the read (a narrow trace's from its own on-times, each moment against its own noise). A
    ///   shorter read than asked for is used, and said in `note`. The longer read's answer replaces the first's, a name the
    ///   first gave included;
    /// - `captureSpectrumDb` (an averaged spectrum of the whole capture at `captureRate`, FFT-shifted, centred on
    ///   `captureSpectrumCenterHz`: `captureCenterHz` when nil, as when `iq` is the capture itself) shows any interference
    ///   comb (`InterferenceComb`). Its lines are neither noise nor areas around the point (`TraceFinder.find`), nor
    ///   energy at an empty point (`tooWeak`), and the trace at the point, on one of them and steady as the comb is (`InterferenceComb.isCombLine`), is the comb's
    ///   (`comb`) when nothing names it and what it measures is no modulation (`combFamilies`): a keyed or modulated
    ///   signal on the grid, or one a mode's numbers name, keeps its own answer. A trace that may be a narrow MFSK
    ///   (`mayBeNarrowMFSK`: a row of FT8s can sit on a grid, and their hops are too quick for the map) is labelled only
    ///   once its tones have been tried (`symbolReading`): not on a quick answer that leaves them to the longer read, nor
    ///   with an agent's width.
    ///
    /// A cancelled task stops between stages (the neighbourhood, the measurement, each step of the longer read) and gets
    /// `cancelledNote` with what was measured so far: an answer nobody is waiting for.
    public static func identify(iq: [Float], sampleRate: Double, captureCenterHz: Double, atHz: Double,
                                bandwidthHz: Double?, spectrumDb: [Float]?,
                                longer: (() -> (iq: [Float], seconds: Double)?)?,
                                pointRadiusHz: Double = 60, endTime: Date? = nil, captureSpectrumDb: [Float]? = nil,
                                captureRate: Double? = nil, captureSpectrumCenterHz: Double? = nil) -> SignalIdentity {
        let available = sampleRate > 0 ? Double(iq.count / 2) / sampleRate : 0
        guard available >= minimumSeconds else {
            return SignalIdentity(measurement: SignalMeasurement(family: .noise, seconds: available),
                                  note: tooSoonNote)
        }
        let seconds = min(firstSeconds, available)
        // The newest 3 s: the read itself when it is no longer (the app's is 3 s), never a second copy of it.
        let firstFloats = 2 * Int((seconds * sampleRate).rounded())
        let first = iq.count <= firstFloats ? iq : Array(iq.suffix(firstFloats))
        let pointHz = atHz - captureCenterHz
        // The capture's comb, its lines from `iq`'s own centre, and whether the point's trace is one of them.
        let comb = captureSpectrumDb.flatMap { InterferenceComb.detect(spectrumDb: $0, sampleRate: captureRate ?? sampleRate) }
        let combLines = comb.map { found in
            found.lineOffsetsHz.map { $0 + (captureSpectrumCenterHz ?? captureCenterHz) - captureCenterHz }
        } ?? []
        // Whether the point's trace is a comb line, and one that may be a narrow MFSK whose tones haven't been read.
        var onCombLine = false, tonesUnread = false
        func answer(_ identity: SignalIdentity) -> SignalIdentity {
            guard onCombLine, !tonesUnread, let comb, identity.best == nil,
                  combFamilies.contains(identity.measurement.family) else {
                return identity
            }
            var labelled = identity
            labelled.comb = comb.info
            return labelled
        }

        // The seed: an agent's bandwidth, or what the neighbourhood shows at the point.
        let seed: (offsetHz: Double, widthHz: Double)
        // How wide the signal itself shows, where the seed's width holds more than that.
        var coreHz: Double?
        var ceiling = SignalMeasurer.Ceiling.none
        // Tones that take turns, whose own reading didn't show a speed: what else measures them comes first.
        var tones: DirectFSK.Tones?, fskRead: DirectFSK.Tones.Read?
        // The narrow trace the point is on, which may be an MFSK too close-spaced for the map (`SymbolTones`), and the
        // map it was found on.
        var narrow: (trace: SignalTrace, map: TimeFrequencyMap)?
        if let bandwidthHz {
            seed = (pointHz, bandwidthHz)
            ceiling = .given
            // A whole FSK inside the width, whose tones show their speed, answers for it, no wider than the width.
            let hood = neighbourhood(first, sampleRate: sampleRate, pointHz: pointHz)
            let view = TraceFinder.find(hood.map, combLinesHz: combLines)
            if Task.isCancelled { return cancelled(SignalMeasurement(offsetHz: pointHz, seconds: seconds)) }
            onCombLine = isOnCombLine(view, map: hood.map, pointHz: pointHz, radiusHz: pointRadiusHz, combLinesHz: combLines)
            // An agent's width reads no tones.
            tonesUnread = pointTrace(view, pointHz: pointHz, radiusHz: pointRadiusHz).map(mayBeNarrowMFSK) ?? false
            let signals = candidates(hood, view: view, pointHz: pointHz, radiusHz: pointRadiusHz)
            let within = (pointHz - bandwidthHz / 2)...(pointHz + bandwidthHz / 2)
            if let whole = signalAtPoint(signals, view: view, pointHz: pointHz, radiusHz: pointRadiusHz),
               let tones = whole.tones, tones.allSatisfy(within.contains),
               let read = DirectFSK.Tones(whole, signals: signals, noiseDb: view.noiseDb)?
                .reading(SignalMeasurer.interleaved(hood.samples), rate: hood.rate, zeroHz: hood.centreHz),
               read.reading.baud != nil {
                var m = read.measurement(seconds: seconds)
                if m.occupiedBandwidthHz > bandwidthHz {
                    m.snrDb += 10 * log10(m.occupiedBandwidthHz / bandwidthHz)
                    m.occupiedBandwidthHz = bandwidthHz
                    m.bandwidth6dBHz = min(m.bandwidth6dBHz, bandwidthHz)
                }
                return answer(identify(m, rfHz: captureCenterHz + m.offsetHz))
            }
            if Task.isCancelled { return cancelled(SignalMeasurement(offsetHz: pointHz, seconds: seconds)) }
        } else {
            let hood = neighbourhood(first, sampleRate: sampleRate, pointHz: pointHz)
            let map = hood.map
            if Task.isCancelled { return cancelled(SignalMeasurement(offsetHz: pointHz, seconds: seconds)) }
            let view = TraceFinder.find(map, combLinesHz: combLines)
            if Task.isCancelled { return cancelled(SignalMeasurement(offsetHz: pointHz, seconds: seconds)) }
            onCombLine = isOnCombLine(view, map: map, pointHz: pointHz, radiusHz: pointRadiusHz, combLinesHz: combLines)
            let signals = candidates(hood, view: view, pointHz: pointHz, radiusHz: pointRadiusHz)
            if Task.isCancelled { return cancelled(SignalMeasurement(offsetHz: pointHz, seconds: seconds)) }
            var here = signalAtPoint(signals, view: view, pointHz: pointHz, radiusHz: pointRadiusHz)
            // Tones that read as tones. Too few changes to show a speed, they are still what they are; plenty and none, they
            // may be a fast signal's lobes, or an FM's lines, and the numbers aren't to be trusted.
            func read(_ fsk: SignalCandidate) -> DirectFSK.Tones.Read? {
                let read = DirectFSK.Tones(fsk, signals: signals, noiseDb: view.noiseDb)?
                    .reading(SignalMeasurer.interleaved(hood.samples), rate: hood.rate, zeroHz: hood.centreHz)
                return read.flatMap { $0.reading.baud != nil || $0.reading.changes < DirectFSK.minChanges ? $0 : nil }
            }
            if let fsk = here, fsk.tones != nil {
                tones = DirectFSK.Tones(fsk, signals: signals, noiseDb: view.noiseDb)
                fskRead = read(fsk)
                if let toneRead = fskRead, toneRead.reading.baud != nil {
                    return answer(identify(toneRead.measurement(seconds: seconds), rfHz: captureCenterHz + toneRead.offsetHz))
                }
                // What doesn't read as tones is measured as what the view shows at the point, not as a span of them.
                if fskRead == nil { here = nil }
            } else if let station = here, read(signals.first { $0.tones != nil && $0.lowerHz...$0.upperHz ~= station.lowerHz }
                                               ?? station) == nil {
                // A station is one beside tones: without them, it is only a hump in what the view shows.
                here = nil
            }
            if here == nil, !view.areas.contains(where: { $0.lowerHz...$0.upperHz ~= pointHz }),
               let line = pointTrace(view, pointHz: pointHz, radiusHz: pointRadiusHz), mayBeNarrowMFSK(line) {
                narrow = (line, map)
            }
            if let found = located(view, signal: here, signals: signals, map: map, pointHz: pointHz, radiusHz: pointRadiusHz) {
                seed = (found.offsetHz, found.widthHz)
                coreHz = found.coreHz
                ceiling = found.ceiling
            } else if let wide = WideOccupancy.find(spectrumDb ?? wideSpectrum(first, sampleRate: sampleRate), iq: first,
                                                    sampleRate: sampleRate, pointHz: pointHz) {
                seed = wide
            } else {
                return tooWeak(map, view: view, pointHz: pointHz, seconds: seconds, combLinesHz: combLines)
            }
            if Task.isCancelled { return cancelled(SignalMeasurement(offsetHz: pointHz, seconds: seconds)) }
        }

        var m = SignalMeasurer.measure(first, sampleRate: sampleRate, offsetHz: seed.offsetHz,
                                       bandwidthHz: seed.widthHz, seconds: seconds, ceiling: ceiling)
        if Task.isCancelled { return cancelled(m) }
        // A narrow trace whose symbols sit on tones spaced by their rate is that MFSK, whatever else its few seconds
        // looked like (FT8's hops can pass for a PSK's). The quick first answer (no longer read to follow) reads its tones
        // only then, to keep its speed: otherwise the longer read does.
        var firstReading: SignalMeasurement?
        if let narrow {
            let slots = SlotEvidence.all(onTimes: narrow.trace.onTimes, readEnd: endTime, readSeconds: seconds)
            if longer != nil || m.family == .psk,
               let read = symbolReading(first, sampleRate: sampleRate, trace: narrow.trace, pointHz: pointHz,
                                        map: narrow.map, on: SlotEvidence.transmissions(narrow.trace.onTimes), seconds: seconds,
                                        measured: m) {
                m = read
                firstReading = read
            }
            m.slotFits = slots
            if Task.isCancelled { return cancelled(m) }
            tonesUnread = longer == nil && firstReading == nil && m.family != .psk
        }
        var identity = identify(m, rfHz: captureCenterHz + m.offsetHz)
        // A narrow trace measured PSK whose tones didn't read, in a slot mode's frequencies, may be that mode's tones on a
        // read too short or too far off them to show: no PSK name yet, and a longer read.
        if narrow != nil, m.family == .psk, firstReading == nil, inSlotFrequencies(captureCenterHz + m.offsetHz) {
            identity = heldForTones(identity)
            identity.needsLongerRead = true
        }
        // A longer read may show the speed; until then, what the tones do show.
        if fskRead != nil, identity.best == nil, m.family == .unknown { identity.needsLongerRead = true }
        // A narrow trace nothing names may be an MFSK whose tones the quick answer didn't read.
        if narrow != nil, longer == nil, identity.best == nil, m.family == .unknown { identity.needsLongerRead = true }
        guard identity.needsLongerRead, !Task.isCancelled, let read = longer?(), read.iq.count >= 2 else {
            if Task.isCancelled { return cancelled(m) }
            if let fskRead, identity.best == nil, m.family == .unknown {
                var tones = identify(fskRead.measurement(seconds: seconds), rfHz: captureCenterHz + fskRead.offsetHz)
                tones.needsLongerRead = identity.needsLongerRead
                return answer(tones)
            }
            return answer(identity)
        }

        // The longer read, from the same seed.
        var long = read.iq
        var readSeconds = min(read.seconds, Double(long.count / 2) / sampleRate)
        let snapshotSeconds = readSeconds
        var notes: [String] = []
        if readSeconds < longSeconds - 0.1 {
            notes.append(String(format: "Read %.1f s of the %.0f s asked for", readSeconds, longSeconds))
        }
        let slotted = ([identity.best].compactMap { $0 } + identity.alternatives).contains {
            ModeTable.row($0.name)?.slotted == true
        } || (m.family == .unknown && ModeTable.rows.contains { $0.slotted && $0.hinted(captureCenterHz + m.offsetHz) })
        // A narrow trace's own on-times over the longer read, each moment against its own noise (a receiver's gain
        // steps don't cut its transmissions): its slots, and its longest transmission.
        var timing: (map: TimeFrequencyMap, onTimes: [ClosedRange<Double>])?
        var slots: [SlotFit] = []
        var during = 0...readSeconds
        if let narrow {
            timing = narrowTiming(long, sampleRate: sampleRate, trace: narrow.trace)
            slots = timing.map { SlotEvidence.all(onTimes: $0.onTimes, readEnd: endTime, readSeconds: readSeconds) } ?? []
        }
        if let run = timing.flatMap({ longestTransmission($0.onTimes, readSeconds: readSeconds) }) {
            let lower = 2 * Int((run.lowerBound * sampleRate).rounded())
            let upper = min(long.count, 2 * Int((run.upperBound * sampleRate).rounded()))
            long = Array(long[lower..<upper])
            during = run
            readSeconds = Double(long.count / 2) / sampleRate
            notes.append(String(format: "Measured over its longest transmission, %.1f s", readSeconds))
        } else if slotted, timing == nil,
                  let span = Transmissions.longest(long, sampleRate: sampleRate, offsetHz: m.offsetHz,
                                                   bandwidthHz: coreHz ?? max(m.occupiedBandwidthHz, seed.widthHz)) {
            long = Array(long[(2 * span.lowerBound)..<(2 * span.upperBound)])
            readSeconds = Double(span.count) / sampleRate
            notes.append(String(format: "Measured over its longest transmission, %.1f s", readSeconds))
        }
        if Task.isCancelled { return cancelled(m) }
        var slow = SignalMeasurer.measure(long, sampleRate: sampleRate, offsetHz: seed.offsetHz,
                                          bandwidthHz: seed.widthHz, seconds: readSeconds, ceiling: ceiling)
        if Task.isCancelled { return cancelled(slow) }
        var longReading = false
        if let narrow, let timing {
            // The frames on the air within what was measured.
            let on = SlotEvidence.transmissions(timing.onTimes).compactMap { run -> ClosedRange<Double>? in
                let lower = max(run.lowerBound, during.lowerBound), upper = min(run.upperBound, during.upperBound)
                return lower < upper ? (lower - during.lowerBound)...(upper - during.lowerBound) : nil
            }
            if let read = symbolReading(long, sampleRate: sampleRate, trace: narrow.trace, pointHz: pointHz,
                                        map: timing.map, mapStart: during.lowerBound, on: on, seconds: readSeconds,
                                        measured: slow) {
                slow = read
                longReading = true
            }
            slow.slotFits = slots
            if Task.isCancelled { return cancelled(slow) }
        }
        var refined = identify(slow, rfHz: captureCenterHz + slow.offsetHz)
        // Tones the first pass read stand when the longer read shows nothing better (more symbols are more of a fade, a
        // neighbour's turn, or the receiver's gain stepping down).
        if !longReading, refined.best == nil || slow.family == .psk, var firstReading {
            if !slots.isEmpty { firstReading.slotFits = slots }
            let kept = identify(firstReading, rfHz: captureCenterHz + firstReading.offsetHz)
            if kept.best != nil { refined = kept }
        }
        if narrow != nil, slow.family == .psk, !longReading, refined.measurement.family == .psk,
           inSlotFrequencies(captureCenterHz + slow.offsetHz) {
            refined = heldForTones(refined)
        }
        if refined.best == nil, slow.family == .unknown, let tones {
            let rereading = tones.reading(read.iq, rate: sampleRate, zeroHz: 0)
            let seen = rereading?.reading.baud != nil ? rereading : fskRead
            if let seen {
                let at = seen == rereading ? snapshotSeconds : seconds
                refined = identify(seen.measurement(seconds: at), rfHz: captureCenterHz + seen.offsetHz)
            }
        }
        // The longer read has been made; only a shorter one than asked for leaves a need that more IQ could meet.
        refined.needsLongerRead = refined.needsLongerRead && snapshotSeconds < longSeconds - 0.1
        if let note = refined.note { notes.insert(note, at: 0) }
        refined.note = notes.isEmpty ? nil : notes.joined(separator: "; ")
        return answer(refined)
    }

    /// What a comb line measures as: a line (or a wandering one, which reads as nothing in particular), never modulation.
    static let combFamilies: Set<SignalFamily> = [.carrier, .unknown, .noise]

    /// Whether the trace at the point (`pointTrace`), outside any area, is a comb line (`InterferenceComb.isCombLine`).
    static func isOnCombLine(_ view: NeighbourhoodView, map: TimeFrequencyMap, pointHz: Double, radiusHz: Double,
                             combLinesHz: [Double]) -> Bool {
        guard !combLinesHz.isEmpty, !view.areas.contains(where: { $0.lowerHz...$0.upperHz ~= pointHz }),
              let line = pointTrace(view, pointHz: pointHz, radiusHz: radiusHz) else { return false }
        return InterferenceComb.isCombLine(line, view: view, map: map, linesHz: combLinesHz)
    }

    /// The note when there is nothing at the point.
    public static let noSignalNote = "No signal"
    /// The note when the IQ since the last retune is too short to read (under `minimumSeconds`).
    public static let tooSoonNote = "Too soon after tuning — try again"

    /// The note on an identification its task's cancellation cut short.
    public static let cancelledNote = "Cancelled"

    static func cancelled(_ m: SignalMeasurement) -> SignalIdentity {
        SignalIdentity(measurement: m, note: cancelledNote)
    }

    // MARK: Extent

    /// The extent around `pointHz` in an FFT-shifted spectrum of the whole capture.
    public static func extent(_ db: [Float], sampleRate: Double, pointHz: Double) -> (offsetHz: Double, widthHz: Double)? {
        let size = db.count
        guard size >= 8 else { return nil }
        let binHz = sampleRate / Double(size)
        let near = size / 2 + Int((pointHz / binHz).rounded())
        guard near >= 0, near < size,
              let e = Extent.find(spectrumDb: db, binHz: binHz, nearBin: near, searchBins: searchBins) else { return nil }
        return ((Double(e.lowerBin + e.upperBin) / 2 - Double(size / 2)) * binHz,
                Double(e.upperBin - e.lowerBin + 1) * binHz)
    }

    /// What was read around a point: `map`, and the samples it was built from (`rate`, their 0 Hz `centreHz` from the
    /// capture centre), which hold everything on it.
    struct Neighbourhood {
        var map: TimeFrequencyMap
        var samples: [DSPComplex]
        var rate: Double
        var centreHz: Double
    }

    /// What `TraceFinder` reads around `pointHz`: the map of ±`localWindowHz` / 2 of it, as far as the capture goes, cut
    /// to a channel first so a capture's rate makes no difference. The channel's rate only has to hold that span: its
    /// filter passes twice what it is asked for before anything aliasing onto it matters (half of `localWindowHz` asked
    /// for, 125 kS/s from 1 MS/s). A capture's outer edges are filter skirts, so the map leaves them out of its noise
    /// unless the point itself lies there: then it reaches the point and a little past, up to the capture's edge.
    static func neighbourhood(_ iq: [Float], sampleRate: Double, pointHz: Double) -> Neighbourhood {
        let nyquist = sampleRate / 2
        let edge = min(nyquist, max(usableCaptureShare * nyquist, abs(pointHz) + pointMarginHz))
        let lower = max(pointHz - localWindowHz / 2, -edge), upper = min(pointHz + localWindowHz / 2, edge)
        let width = max(upper - lower, 0), centre = (lower + upper) / 2
        // A capture no faster than the channel needs has nothing to filter: only the mix.
        guard Channel.outputRate(sampleRate: sampleRate, bandwidthHz: width / 2) < sampleRate else {
            var z = iq.withUnsafeBufferPointer { raw in raw.withMemoryRebound(to: DSPComplex.self) { Array($0) } }
            var mixer = BlockMixer(frequency: -centre, sampleRate: sampleRate)
            z.withUnsafeMutableBufferPointer { samples in
                var start = 0
                while start < samples.count {
                    let count = min(BlockMixer.blockSize, samples.count - start)
                    mixer.mix(samples.baseAddress! + start, count: count)
                    start += count
                }
            }
            let map = TimeFrequencyMap.build(z, rate: sampleRate, centerOffsetHz: centre, binHz: mapBinHz,
                                             hopSeconds: mapHopSeconds, halfSpanHz: width / 2)
            return Neighbourhood(map: map, samples: z, rate: sampleRate, centreHz: centre)
        }
        let channel = Channel.extract(iq, sampleRate: sampleRate, offsetHz: centre, bandwidthHz: width / 2, sharp: false)
        let map = TimeFrequencyMap.build(channel.samples, rate: channel.rate, centerOffsetHz: centre, binHz: mapBinHz,
                                         hopSeconds: mapHopSeconds, halfSpanHz: width / 2)
        return Neighbourhood(map: map, samples: channel.samples, rate: channel.rate, centreHz: centre)
    }

    /// `neighbourhood`'s map alone.
    static func neighbourhoodMap(_ iq: [Float], sampleRate: Double, pointHz: Double) -> TimeFrequencyMap {
        neighbourhood(iq, sampleRate: sampleRate, pointHz: pointHz).map
    }

    /// The view around the point as signals (`SignalGrouper`), from a picture of the frequencies the point's lines could
    /// have tones on, cut narrow so it costs little. When there aren't two lines there to try, it isn't made.
    static func candidates(_ hood: Neighbourhood, view: NeighbourhoodView, pointHz: Double, radiusHz: Double) -> [SignalCandidate] {
        let reach = radiusHz + SignalGrouper.maxShiftHz + turnsRoomHz
        guard SignalGrouper.mayHoldTones(view, band: (pointHz - reach)...(pointHz + reach), lines: hood.map) else {
            return SignalGrouper.group(view, map: .empty)
        }
        let cut = Channel.extract(SignalMeasurer.interleaved(hood.samples), sampleRate: hood.rate,
                                  offsetHz: pointHz - hood.centreHz, bandwidthHz: 2 * reach, sharp: false)
        let map = SignalGrouper.turnsMap(cut.samples, rate: cut.rate, centerOffsetHz: pointHz, halfSpanHz: reach)
        return SignalGrouper.group(view, map: map, lines: hood.map)
    }

    /// Room in the turns picture beyond the farthest tone it can be asked about.
    static let turnsRoomHz = 200.0

    /// What `SignalGrouper` found at the point that the view alone doesn't show, or nil when it is for the view to say:
    /// - the nearest line within `radiusHz`, a tone or a line of its own, the stronger of equals. A tone gives its FSK; a
    ///   station `SignalGrouper` found inside an FSK's span gives that station;
    /// - no line there, the FSK whose span the point lies in, or within `radiusHz` of.
    static func signalAtPoint(_ signals: [SignalCandidate], view: NeighbourhoodView, pointHz: Double,
                              radiusHz: Double) -> SignalCandidate? {
        guard !signals.contains(where: { $0.kind == .area && $0.lowerHz...$0.upperHz ~= pointHz }) else { return nil }
        func distance(_ lower: Double, _ upper: Double) -> Double { max(0, lower - pointHz, pointHz - upper) }
        var lines: [(distance: Double, levelDb: Double, signal: SignalCandidate)] = []
        for signal in signals {
            if let tones = signal.tones {
                lines += tones.map { (abs($0 - pointHz), .infinity, signal) }
            } else if signal.kind == .single, let line = signal.traces.first {
                lines.append((distance(line.lowerHz, line.upperHz), line.snrDb, signal))
            }
        }
        if let nearest = lines.filter({ $0.distance <= radiusHz }).min(by: { ($0.distance, -$0.levelDb) < ($1.distance, -$1.levelDb) }) {
            if nearest.signal.tones != nil { return nearest.signal }
            return view.traces.contains(nearest.signal.traces[0]) ? nil : nearest.signal
        }
        return signals.first { $0.tones != nil && ($0.lowerHz - radiusHz)...($0.upperHz + radiusHz) ~= pointHz }
    }

    /// Whether `rfHz` lies in a slot mode's own frequencies (its hint).
    static func inSlotFrequencies(_ rfHz: Double) -> Bool { ModeTable.rows.contains { $0.slotted && $0.hinted(rfHz) } }

    /// `identity` with a PSK name held under the name threshold and listed among the alternatives, said why.
    static func heldForTones(_ identity: SignalIdentity) -> SignalIdentity {
        guard var best = identity.best, ModeTable.row(best.name)?.families.contains(.psk) == true else { return identity }
        var held = identity
        best.confidence = min(best.confidence, nameThreshold - 0.01)
        best.evidence.append("a narrow trace in a slot mode's frequencies whose tones didn't read: may be its tones hopping")
        held.best = nil
        held.alternatives = Array(([best] + identity.alternatives).prefix(maxAlternatives))
        return held
    }

    /// The nearest trace within `radiusHz` of the point, the strongest of equals.
    static func pointTrace(_ view: NeighbourhoodView, pointHz: Double, radiusHz: Double) -> SignalTrace? {
        func distance(_ t: SignalTrace) -> Double { max(0, t.lowerHz - pointHz, pointHz - t.upperHz) }
        return view.traces.filter { distance($0) <= radiusHz }.min { (distance($0), -$0.snrDb) < (distance($1), -$1.snrDb) }
    }

    // MARK: Narrow MFSK

    /// A trace this narrow may be an MFSK whose tones the map can't part (FT4's four span 83 Hz; two FT8 stations side by
    /// side read about 170 Hz). A steady line holds one frequency.
    static let narrowMFSKMaxHz = 200.0
    /// Each side of a trace, the channel its tones are read from reaches this far (a map bin, for skirts it cut).
    static let narrowMarginHz = 8.0
    /// The picture its on-times come from over the longer read: this far either side of it.
    static let narrowViewHz = 500.0
    /// How a trace's presence (`SymbolTones.Presence`) is smoothed either side: one moment's power over the noise is
    /// itself noisy at a few dB.
    static let presenceSmoothingSeconds = 0.25

    static func mayBeNarrowMFSK(_ trace: SignalTrace) -> Bool {
        !trace.steady && trace.upperHz - trace.lowerHz <= narrowMFSKMaxHz
    }

    /// `trace`, in `iq` (`seconds` of it), read as an orthogonal MFSK (`SymbolTones`), each moment counting by how far the
    /// trace stands over the noise on `map` then (`mapStart` is `iq`'s start on it): its measurement, or nil when it doesn't
    /// read as one, or `measured` already shows a carrier line (keyed, AM or a carrier: one frequency). A trace with a deep
    /// valley in it is two stations side by side (two FT8s 50 Hz apart read as one 16-tone MFSK): the part on the point's
    /// side of it (`narrowPiece`) is read first, and the whole trace only if that doesn't read. Its SNR comes from `map` over the moments within `on` (seconds in `iq`), in its own
    /// width.
    static func symbolReading(_ iq: [Float], sampleRate: Double, trace: SignalTrace, pointHz: Double,
                              map: TimeFrequencyMap, mapStart: Double = 0, on: [ClosedRange<Double>], seconds: Double,
                              measured: SignalMeasurement) -> SignalMeasurement? {
        guard [.unknown, .psk, .fsk, .mfsk].contains(measured.family) else { return nil }
        let during = on.map { ($0.lowerBound + mapStart)...($0.upperBound + mapStart) }
        func presence(_ lower: Double, _ upper: Double) -> SymbolTones.Presence? {
            let low = max(0, map.bin(lower)), high = min(map.bins - 1, map.bin(upper))
            guard low <= high, map.rows > 0 else { return nil }
            let reach = Int((presenceSmoothingSeconds / map.hopSeconds).rounded())
            let excess = TraceFinder.smoothed(map.bandPower(low...high), reach: reach).map { Double($0) - 1 }
            return SymbolTones.Presence(excess: excess, hopSeconds: map.hopSeconds,
                                        firstSeconds: map.frameSeconds / 2 - mapStart)
        }
        var pieces = [(trace.lowerHz, trace.upperHz)]
        if let piece = narrowPiece(trace, pointHz: pointHz, map: map, during: during) { pieces.insert(piece, at: 0) }
        var found: (reading: SymbolTonesReading, centre: Double, lower: Double, upper: Double)?
        for (lower, upper) in pieces where found == nil {
            if Task.isCancelled { return nil }
            let centre = (lower + upper) / 2
            if let read = SymbolTones.read(iq, sampleRate: sampleRate, offsetHz: centre,
                                           widthHz: upper - lower + 2 * narrowMarginHz, presence: presence(lower, upper)) {
                found = (read, centre, lower, upper)
            }
        }
        guard let (read, centre, lower, upper) = found else { return nil }
        let snr = traceSNR(map, lowerHz: lower, upperHz: upper, during: during, widthHz: read.widthHz)
        var notes = [String(format: "%d tones a symbol rate apart (%.2f Hz as their symbols read), one a symbol at %.2f Bd (%d seen)",
                            read.toneCount, read.tonesSpacingHz, read.baud, read.tonesSeen)]
        if measured.family == .psk { notes.append("Its symbols hop between tones: not PSK") }
        // Its width is its parameters' (n − 1 spacings and a rate each side): the tones don't show where its edges lie, so
        // a named row's own keying gives it (`ParameterWidth`, R16), as for any FSK whose edges sit under the noise.
        return SignalMeasurement(offsetHz: centre + read.centreHz, occupiedBandwidthHz: read.widthHz,
                                 bandwidth6dBHz: read.widthHz, snrDb: snr, envelope: .steady,
                                 family: read.toneCount > 8 ? .mfsk : .fsk,
                                 familyConfidence: SymbolTones.confidence(read), symbolRate: read.baud,
                                 fskShiftHz: read.toneCount == 2 ? read.spacingHz : nil, toneCount: read.toneCount,
                                 toneSpacingHz: read.spacingHz, seconds: seconds, notes: notes, edgesUnderNoise: true)
    }

    /// Where a trace wider than one narrow MFSK (`narrowPieceMinHz`) dips deepest between two humps, each `pieceValleyDb`
    /// over the dip, on `map`'s average over `during`: the part on the point's side, or nil when there is no such dip.
    /// An MFSK's own tones ripple less: FT4's by 3 dB at most on the corpus's tuning part and in synthesis, where two FT8
    /// stations side by side dip 7 to 15.
    static func narrowPiece(_ trace: SignalTrace, pointHz: Double, map: TimeFrequencyMap,
                            during: [ClosedRange<Double>]) -> (Double, Double)? {
        let low = max(0, map.bin(trace.lowerHz)), high = min(map.bins - 1, map.bin(trace.upperHz))
        guard trace.upperHz - trace.lowerHz >= narrowPieceMinHz, high - low >= 4 else { return nil }
        let rows = (0..<map.rows).filter { r in during.contains { $0 ~= Double(r) * map.hopSeconds + map.frameSeconds / 2 } }
        guard !rows.isEmpty else { return nil }
        var mean = [Double](repeating: 0, count: high - low + 1)
        map.relativeDb.withUnsafeBufferPointer { db in
            for r in rows {
                for k in low...high { mean[k - low] += pow(10, Double(db[r * map.bins + k]) / 10) / Double(rows.count) }
            }
        }
        let depth = pow(10, pieceValleyDb / 10)
        var deepest: (bin: Int, ratio: Double)?
        for k in 1..<(mean.count - 1) where mean[k] <= mean[k - 1] && mean[k] <= mean[k + 1] {
            let left = mean[..<k].max()!, right = mean[(k + 1)...].max()!
            let ratio = min(left, right) / max(mean[k], 1e-9)
            if ratio >= depth, ratio > (deepest?.ratio ?? 0) { deepest = (k, ratio) }
        }
        guard let deepest else { return nil }
        let valley = map.offsetHz(Double(low + deepest.bin))
        return pointHz <= valley ? (trace.lowerHz, valley) : (valley, trace.upperHz)
    }

    /// A trace this wide may hold two narrow MFSKs side by side (FT8's 50 Hz each).
    static let narrowPieceMinHz = 80.0
    static let pieceValleyDb = 6.0

    /// The power in `lowerHz…upperHz` of `map`, over the rows within `during`, less the noise, over the noise in `widthHz`.
    static func traceSNR(_ map: TimeFrequencyMap, lowerHz: Double, upperHz: Double, during: [ClosedRange<Double>],
                         widthHz: Double) -> Double {
        let low = max(0, map.bin(lowerHz)), high = min(map.bins - 1, map.bin(upperHz))
        guard low <= high, map.rows > 0 else { return 0 }
        let levels = map.bandPower(low...high)
        let rows = levels.indices.filter { r in during.contains { $0 ~= Double(r) * map.hopSeconds + map.frameSeconds / 2 } }
        guard !rows.isEmpty else { return 0 }
        let mean = rows.reduce(0.0) { $0 + Double(levels[$1]) } / Double(rows.count)
        // Each bin's noise reads 1, and a bin sums its share of power over one frame's width.
        let excess = (mean - 1) * Double(high - low + 1) * map.binHz
        return 10 * log10(max(excess / max(widthHz, map.binHz), 1e-3))
    }

    /// A map of `trace`'s neighbourhood over `iq` and the trace's on-times there.
    static func narrowTiming(_ iq: [Float], sampleRate: Double,
                             trace: SignalTrace) -> (map: TimeFrequencyMap, onTimes: [ClosedRange<Double>])? {
        let centre = (trace.lowerHz + trace.upperHz) / 2
        let half = narrowViewHz + (trace.upperHz - trace.lowerHz) / 2
        let cut = Channel.extract(iq, sampleRate: sampleRate, offsetHz: centre, bandwidthHz: 2 * half, sharp: false)
        let map = TimeFrequencyMap.build(cut.samples, rate: cut.rate, centerOffsetHz: centre, binHz: mapBinHz,
                                         hopSeconds: mapHopSeconds, halfSpanHz: half)
        let low = max(0, map.bin(trace.lowerHz)), high = min(map.bins - 1, map.bin(trace.upperHz))
        guard map.rows > 0, low <= high else { return nil }
        return (map, TraceFinder.onTimes(low...high, map: map, quiet: 1))
    }

    /// The longest of `onTimes` as transmissions (`SlotEvidence.transmissions`: a blip of noise in the silence between two
    /// would join them, a fade or a gain step would cut one), when there is silence in the read to set it apart and it
    /// lasts `Transmissions.minSeconds`.
    static func longestTransmission(_ onTimes: [ClosedRange<Double>], readSeconds: Double) -> ClosedRange<Double>? {
        let runs = SlotEvidence.transmissions(onTimes).map { max(0, $0.lowerBound)...min(readSeconds, $0.upperBound) }
        guard let run = runs.max(by: { $0.upperBound - $0.lowerBound < $1.upperBound - $1.lowerBound }),
              run.upperBound - run.lowerBound >= Transmissions.minSeconds,
              run.upperBound - run.lowerBound < readSeconds - 2 * SlotEvidence.readEdgeSeconds else { return nil }
        return run
    }

    /// Where to measure for the point: what `signalAtPoint` found (`signal`: an FSK whose tones didn't give their own
    /// answer, or a station in an FSK's span), the area the point lies in, or the nearest trace within `radiusHz` (the
    /// strongest of equals). Nil when there is none of those:
    /// nothing further out is looked for. A strong line with sidebands in view (`TraceFinder.hasSidebands`) is more than
    /// the line: its extent is theirs, on the read's average, out to where they stay over the noise on both sides, and
    /// grows as far as whatever next has no mirror image about the line.
    ///
    /// The extent keeps some room each side (`seedRoomHz` or `seedRoomShare` of its width), for skirts the read's
    /// average can't show and the measurement's width settles on, but no more than halfway to whatever is next to it.
    /// `coreHz` is the width without that room.
    static func located(_ view: NeighbourhoodView, signal: SignalCandidate? = nil, signals: [SignalCandidate] = [],
                        map: TimeFrequencyMap, pointHz: Double,
                        radiusHz: Double) -> (offsetHz: Double, widthHz: Double, coreHz: Double,
                                              ceiling: SignalMeasurer.Ceiling)? {
        var extent: (lower: Double, upper: Double)
        var mayBeLine = true, grows = false
        var line: SignalTrace?
        if let signal {
            extent = (signal.lowerHz, signal.upperHz)
            mayBeLine = signal.tones == nil && signal.upperHz - signal.lowerHz <= TraceFinder.steadyMaxHz
        } else if let area = view.areas.first(where: { $0.lowerHz...$0.upperHz ~= pointHz }) {
            extent = (area.lowerHz, area.upperHz)
            grows = true
        } else {
            guard let trace = pointTrace(view, pointHz: pointHz, radiusHz: radiusHz) else { return nil }
            extent = (trace.lowerHz, trace.upperHz)
            mayBeLine = trace.upperHz - trace.lowerHz <= TraceFinder.steadyMaxHz
            if mayBeLine {
                line = trace
                if TraceFinder.hasSidebands(trace, view) {
                    grows = true
                    let db = map.meanPower().map { 10 * log10(max($0, 1e-6)) }
                    if let wide = Extent.find(spectrumDb: db, binHz: map.binHz, nearBin: map.bin((trace.lowerHz + trace.upperHz) / 2),
                                              searchBins: searchBins) {
                        extent = (map.offsetHz(Double(wide.lowerBin)), map.offsetHz(Double(wide.upperBin)))
                    }
                }
            }
        }
        // Next to it, what isn't a line's sidebands.
        var others = TraceFinder.beside(view, line: mayBeLine ? line : nil)
        if let signal {
            // What held it is no neighbour; the tones and stations beside it, whichever span they came in, are.
            others = others.filter { !($0.lower...$0.upper).overlaps(signal.lowerHz...signal.upperHz) }
            for other in signals where other != signal {
                others += (other.tones ?? []).map { TraceFinder.Neighbour(lower: $0, upper: $0, snrDb: 0) }
                if other.kind == .single {
                    others.append(TraceFinder.Neighbour(lower: other.lowerHz, upper: other.upperHz, snrDb: 0))
                }
            }
        }
        let nextBelow = others.filter { $0.upper < extent.lower }.map(\.upper).max()
        let nextAbove = others.filter { $0.lower > extent.upper }.map(\.lower).min()
        let room = max(seedRoomHz, seedRoomShare * (extent.upper - extent.lower))
        let lower = max(extent.lower - room, nextBelow.map { ($0 + extent.lower) / 2 } ?? -.infinity)
        let upper = min(extent.upper + room, nextAbove.map { ($0 + extent.upper) / 2 } ?? .infinity)
        return ((lower + upper) / 2, upper - lower, extent.upper - extent.lower,
                .found(mayBeLine: mayBeLine, within: (nextBelow ?? -.infinity)...(nextAbove ?? .infinity), grows: grows))
    }

    /// The FFT size for bins of about `binHz` (1024…16 384).
    static func spectrumSize(sampleRate: Double, binHz: Double) -> Int {
        var size = 1024
        while size < 16_384 && sampleRate / Double(size) > binHz { size *= 2 }
        return size
    }

    /// Nothing at the point: "Too weak to identify (SNR n dB)" when the default window around it holds energy over the
    /// noise beside it (the median of the map's bins within ±3 windows, the window's own left out), in an averaged
    /// spectrum (the map's rows by their own noise levels), "No signal" otherwise. A clear trace beside the point isn't
    /// energy too weak to read, at any strength, so its bins (`TraceFinder.isClear`, and its skirts) are left out of both.
    /// A comb's lines (`combLinesHz`) are left out the same way, at any width or strength. What
    /// remains must come to something a measurement can't quite read. Under `weakSNRDb` it is the band's own ripple
    /// (the tuning part's empty points reach −4.1 dB, where the noise is taken this near: a real band stands a dB or two
    /// proud for kHz around a strong signal), and over it something stands in the window that isn't at the point. Real
    /// voice too weak to measure reads −0.5 to +2.2 dB, and a synthetic one at −3 dB, −2.7 dB.
    static func tooWeak(_ map: TimeFrequencyMap, view: NeighbourhoodView, pointHz: Double, seconds: Double,
                        combLinesHz: [Double] = []) -> SignalIdentity {
        var result = SignalMeasurement(offsetHz: pointHz, family: .noise, seconds: seconds)
        let none = SignalIdentity(measurement: result, note: noSignalNote)
        guard map.rows > 0, map.bins > 0 else { return none }
        let power = map.meanPower(levelWeighted: true).map(Double.init)
        let centre = map.bin(pointHz), half = max(1, Int(defaultWindowHz / 2 / map.binHz))
        guard centre + half >= 0, centre - half < map.bins else { return none }
        var masked = [Bool](repeating: false, count: map.bins)
        let skirt = Int((clearSkirtHz / map.binHz).rounded())
        for trace in view.traces where TraceFinder.isClear(trace) {
            let low = max(0, map.bin(trace.lowerHz) - skirt), high = min(map.bins - 1, map.bin(trace.upperHz) + skirt)
            if low <= high { for k in low...high { masked[k] = true } }
        }
        // A comb's lines are neither noise nor energy at the point, however faint or wide (`TraceFinder.combBins`).
        if !combLinesHz.isEmpty {
            let fine = TraceFinder.smoothed(map.meanPower(), reach: Int((TraceFinder.traceReachHz / map.binHz).rounded()))
            for run in TraceFinder.combBins(fine, map: map, linesHz: combLinesHz) {
                for k in run { masked[k] = true }
            }
        }
        let window = max(0, centre - half)...min(map.bins - 1, centre + half)
        let around = max(0, centre - weakNoiseWindows * half)...min(map.bins - 1, centre + weakNoiseWindows * half)
        let inside = window.filter { !masked[$0] }.map { power[$0] }
        let outside = around.filter { !window.contains($0) && !masked[$0] }.map { power[$0] }.sorted()
        guard !inside.isEmpty, !outside.isEmpty else { return none }
        let noise = outside[outside.count / 2]
        // The noise bins' own scatter, for the window's mean (its bins share leakage: half as many independent).
        let mean = outside.reduce(0, +) / Double(outside.count)
        let scatter = (outside.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(outside.count)).squareRoot()
        let excess = inside.reduce(0) { $0 + $1 - noise }
        guard noise > 0, excess > 3 * scatter * (2 * Double(inside.count)).squareRoot() else { return none }
        let snr = 10 * log10(excess / (noise * Double(inside.count)))
        guard weakSNRDb ~= snr else { return none }
        result.snrDb = snr
        result.family = .unknown   // energy there, too weak to measure
        return SignalIdentity(measurement: result, note: String(format: "Too weak to identify (SNR %.0f dB)", snr))
    }
}

/// The longest transmission in a read. A slot mode's longer read (FT8's 15 s slots, FT4's 7.5 s) spans the silence
/// between slots, which the measurer would take for speech pauses: one transmission is measured instead.
///
/// The signal's channel (its width and a half, at least 50 Hz) in 50 ms blocks; when the strongest blocks (90th
/// percentile) stand 6 dB over the weakest (10th) and at most 20% of the blocks lie between (3 dB inside each),
/// the blocks over their geometric mean are on, gaps of up to 0.1 s bridged. The longest run of 2 s or more that isn't the whole read, in input samples.
enum Transmissions {
    static let blockSeconds = 0.05
    static let minContrast = 4.0
    static let maxMiddleShare = 0.2
    static let bridgeBlocks = 2
    static let minSeconds = 2.0

    static func longest(_ iq: [Float], sampleRate: Double, offsetHz: Double, bandwidthHz: Double) -> Range<Int>? {
        let channel = Channel.extract(iq, sampleRate: sampleRate, offsetHz: offsetHz,
                                      bandwidthHz: max(1.5 * bandwidthHz, 50))
        let block = max(1, Int((blockSeconds * channel.rate).rounded()))
        var power = [Float](repeating: 0, count: channel.samples.count)
        channel.samples.withUnsafeBufferPointer { p in
            p.baseAddress!.withMemoryRebound(to: Float.self, capacity: 2 * channel.samples.count) { f in
                var split = DSPSplitComplex(realp: UnsafeMutablePointer(mutating: f),
                                            imagp: UnsafeMutablePointer(mutating: f + 1))
                vDSP_zvmags(&split, 2, &power, 1, vDSP_Length(channel.samples.count))
            }
        }
        let blocks = EnvelopeFeatures.blockMeans(power, length: block).map(Double.init)
        guard blocks.count >= 8 else { return nil }
        let sorted = blocks.sorted()
        let low = sorted[blocks.count / 10], high = sorted[blocks.count * 9 / 10]
        guard low > 0, high >= minContrast * low else { return nil }
        // Slots are on or off: few blocks sit between the two levels. A level that drifts (a recording's AGC
        // recovering) fills the middle, and is no gap.
        let middle = blocks.filter { $0 > 2 * low && $0 < high / 2 }.count
        guard Double(middle) <= maxMiddleShare * Double(blocks.count) else { return nil }
        let threshold = (low * high).squareRoot()
        var runs: [Range<Int>] = []
        var start: Int?
        var lastOn = -1
        for (k, p) in blocks.enumerated() where p >= threshold {
            if let s = start, k - lastOn - 1 > bridgeBlocks {
                runs.append(s..<(lastOn + 1))
                start = k
            } else if start == nil {
                start = k
            }
            lastOn = k
        }
        if let s = start { runs.append(s..<(lastOn + 1)) }
        guard let run = runs.max(by: { $0.count < $1.count }),
              Double(run.count) * blockSeconds >= minSeconds, run.count < blocks.count - bridgeBlocks else { return nil }
        let scale = sampleRate / channel.rate * Double(block)
        let n = iq.count / 2
        return min(n, Int(Double(run.lowerBound) * scale))..<min(n, Int(Double(run.upperBound) * scale))
    }
}

/// SubFloor's SSB audio recordings as IQ: the demodulated audio of one sideband is that sideband's passband
/// shifted to 0 Hz, so its analytic signal (the audio plus j × its Hilbert transform: positive frequencies only)
/// is the passband's IQ, centred on the dial frequency (USB audio at +f, the spec's "second entry point"). It can't
/// show the other sideband, so it can't tell AM from SSB.
///
/// A capture has band noise everywhere; the audio has it only inside the receiver's passband, and not at all where
/// the recording's squelch muted it (runs of exact zeros). That noise is put back, at the passband's own noise
/// floor, so the measurer finds noise beside the signal as it would in a capture: the floor is each passband
/// frequency's 10th percentile over time (32 ms frames, not muted, averaged over 128 ms: the quiet moments between
/// words), less that percentile's bias for noise (× 1/0.436), the median over the passband (the frequencies within
/// 10 dB of the strongest floors' median). Complex white
/// noise at that level (a fixed seed) is added outside the passband everywhere, and inside it where muted.
public enum AnalyticAudio {
    /// Muted: at least this long of exact zeros.
    static let mutedSeconds = 0.01
    static let frameSeconds = 0.032
    static let floorPercentile = 0.1
    /// Frames (half overlapped, so about 4 independent ones) each power is averaged over.
    static let smoothingFrames = 8
    /// The 10th percentile of the mean of 4 exponentials (noise's power so averaged), over its mean.
    static let percentileBias = 0.436
    static let noiseSeed: UInt64 = 0x5EED_A0D1

    /// Interleaved IQ at the audio's own rate.
    public static func iq(fromSSBAudio audio: [Float], sampleRate: Double) -> (iq: [Float], rate: Double) {
        let n = audio.count
        guard n > 1, sampleRate > 0 else { return ([], sampleRate) }
        let size = FFT.size(atLeast: n)
        var re = [Float](repeating: 0, count: size), im = [Float](repeating: 0, count: size)
        re.replaceSubrange(0..<n, with: audio)
        FFT.transform(&re, &im)
        // Positive frequencies doubled, DC and Nyquist kept, negative ones cleared.
        for k in 1..<(size / 2) {
            re[k] *= 2
            im[k] *= 2
        }
        for k in (size / 2 + 1)..<size {
            re[k] = 0
            im[k] = 0
        }
        FFT.transform(&re, &im, inverse: true)
        let scale = 1 / Float(size)
        var iq = [Float](repeating: 0, count: 2 * n)
        for k in 0..<n {
            iq[2 * k] = re[k] * scale
            iq[2 * k + 1] = im[k] * scale
        }
        restoreNoise(&iq, audio: audio, sampleRate: sampleRate)
        return (iq, sampleRate)
    }

    /// Puts back the band noise the receiver's passband and squelch took out (see the type's notes).
    static func restoreNoise(_ iq: inout [Float], audio: [Float], sampleRate: Double) {
        let n = audio.count
        // Muted runs.
        var muted = [Bool](repeating: false, count: n)
        let minRun = max(1, Int(mutedSeconds * sampleRate))
        var k = 0
        while k < n {
            guard audio[k] == 0 else { k += 1; continue }
            var end = k
            while end < n && audio[end] == 0 { end += 1 }
            if end - k >= minRun { for j in k..<end { muted[j] = true } }
            k = end
        }
        // Each frequency's floor over unmuted frames (Hann-windowed, half overlapped).
        let frame = FFT.size(atLeast: Int(frameSeconds * sampleRate))
        let window = (0..<frame).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(frame))) }
        let windowPower = window.reduce(0) { $0 + Double($1 * $1) }
        var powers: [[Float]] = Array(repeating: [], count: frame)
        var start = 0
        while start + frame <= n {
            defer { start += frame / 2 }
            guard !muted[start..<(start + frame)].contains(true) else { continue }
            var fr = (0..<frame).map { iq[2 * (start + $0)] * window[$0] }
            var fi = (0..<frame).map { iq[2 * (start + $0) + 1] * window[$0] }
            FFT.transform(&fr, &fi)
            for b in 0..<frame { powers[b].append(fr[b] * fr[b] + fi[b] * fi[b]) }
        }
        guard powers[0].count >= 2 * smoothingFrames else { return }
        let floors = powers.map { p -> Double in
            // Each frequency's power over `smoothingFrames` frames (128 ms): the quiet moments between words.
            let smoothed = (0...(p.count - smoothingFrames)).map { i in
                p[i..<(i + smoothingFrames)].reduce(0, +) / Float(smoothingFrames)
            }.sorted()
            return Double(smoothed[Int(floorPercentile * Double(smoothed.count - 1))]) / percentileBias / windowPower
        }
        guard let strongest = floors.max(), strongest > 0 else { return }
        let strong = floors.filter { $0 >= strongest / 100 }.sorted()
        let level = strong[strong.count / 2]
        let passband = floors.map { $0 >= level / 10 }
        guard passband.contains(true), passband.contains(false) || muted.contains(true) else { return }

        // White noise at that level, split at the passband in frequency.
        let size = FFT.size(atLeast: n)
        var noise = [Float](repeating: 0, count: 2 * size)
        var random = SynthRandom(seed: noiseSeed, stream: 2)
        SynthNoise.add(to: &noise, power: level, random: &random)
        var outRe = (0..<size).map { noise[2 * $0] }, outIm = (0..<size).map { noise[2 * $0 + 1] }
        FFT.transform(&outRe, &outIm)
        var inRe = [Float](repeating: 0, count: size), inIm = [Float](repeating: 0, count: size)
        for b in 0..<size where passband[b * frame / size] {
            inRe[b] = outRe[b]
            inIm[b] = outIm[b]
            outRe[b] = 0
            outIm[b] = 0
        }
        FFT.transform(&outRe, &outIm, inverse: true)
        FFT.transform(&inRe, &inIm, inverse: true)
        let scale = 1 / Float(size)
        for j in 0..<n {
            iq[2 * j] += (outRe[j] + (muted[j] ? inRe[j] : 0)) * scale
            iq[2 * j + 1] += (outIm[j] + (muted[j] ? inIm[j] : 0)) * scale
        }
    }
}
