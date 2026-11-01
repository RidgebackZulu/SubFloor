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

    public init(measurement: SignalMeasurement, best: ModeMatch? = nil, alternatives: [ModeMatch] = [],
                needsLongerRead: Bool = false, confirmedByDecode: Bool = false, note: String? = nil) {
        self.measurement = measurement
        self.best = best
        self.alternatives = alternatives
        self.needsLongerRead = needsLongerRead
        self.confirmedByDecode = confirmedByDecode
        self.note = note
    }

    /// The one-line text: `RTTY · 45.45 Bd · 170 Hz shift · 91%` when named, `2-FSK · 50 Bd · 850 Hz shift` when
    /// not, or the note when there is nothing to measure.
    public var label: String {
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
    static func familyName(_ m: SignalMeasurement) -> String {
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
            if let rate { out.append(rate) }
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
/// then frequency hints add up to +0.15 inside a row's bands and, for modes that live only there, take up to 0.15
/// outside. A hint can't lift a match whose parameters alone score under 0.55 to 0.7. A row is named at 0.7 or
/// more when no other is within 0.1 of it (neighbours that can't be told apart, DMR and P25 at an in-between
/// deviation, are listed instead); a signal wider than the view is never named (family only, ruling R5).
///
/// **The longer read** (the spec's slow-signal rules; `needsLongerRead`) when the first pass finds:
/// - a signal under 50 Hz wide, or keying slower than 10 WPM;
/// - a carrier on a read too short to resolve 1.46 Hz structure (under 8 s): it could be WSPR, so its family
///   confidence is held under 0.7 until the longer read (ruling R13);
/// - weak keying (CW under 15 dB): its −20 dB width, and so its SNR, read narrow on 3 s (ruling R12);
/// - a candidate that needs timing (WSPR, FT8/FT4 slots, fax lines, time-signal ticks) at 0.4 or more, or at 0.2
///   inside its own frequencies, or an unidentified signal there.
public enum SignalIdentifier {
    public static let nameThreshold: Float = 0.7
    static let alternativeThreshold: Float = 0.3
    static let maxAlternatives = 3
    static let ambiguityMargin: Float = 0.1
    /// Parameters scoring under this can't be lifted to a name by a hint.
    static let hintFloor = 0.55
    static let firstSeconds = 3.0
    static let longSeconds = 16.0
    static let minimumSeconds = 1.0
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
    /// The read's own spectra, coarse then fine, when the app's shows no extent.
    static let spectrumBinHz = [12.0, 3.0]
    static let localWindowHz = 48_000.0
    static let localCaptureFactor = 1.5

    /// Names `m`, measured at `rfHz` (display Hz), from the mode table.
    public static func identify(_ m: SignalMeasurement, rfHz: Double) -> SignalIdentity {
        var m = m
        var longer = false
        let longEnough = m.seconds >= longRead
        if m.family == .noise {
            return SignalIdentity(measurement: m, note: "No signal")
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
            if parameters < hintFloor { confidence = min(confidence, Double(nameThreshold) - 0.01) }
            if wider != nil { confidence = min(confidence, Double(nameThreshold) - 0.01) }
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
        // A named FSK whose shift doesn't show how it is keyed (WSPR, MFSK16, FT8/FT4, Olivia): its width from its
        // parameters and its standard's keying, where the edges sit under the noise (R16).
        if let best, let shaping = ModeTable.row(best.name)?.shaping { ParameterWidth.apply(to: &m, shaping: shaping) }
        return SignalIdentity(measurement: m, best: best, alternatives: Array(alternatives), needsLongerRead: longer,
                              note: wider)
    }

    /// The whole identification at `atHz` (display Hz) in a capture centred on `captureCenterHz`:
    /// - the signal's extent from `spectrumDb` (an averaged spectrum of the capture, FFT-shifted; worked out
    ///   from the IQ at about 12 Hz a bin, then 3, when nil or when it shows nothing there), unless `bandwidthHz` (an agent's)
    ///   gives it; none gives "Too weak to identify (SNR n dB)" when the default window holds energy over the
    ///   local noise, "No signal" when not;
    /// - the newest 3 s measured (`SignalMeasurer`) and named (`identify(_:rfHz:)`); under 1 s of IQ is "Too soon
    ///   after tuning — try again";
    /// - when the slow-signal rules apply and `longer` is given, it is called (up to 16 s of IQ, ending where
    ///   `iq` ends) and the signal measured and named again from the same extent: a slot mode (FT8, FT4) over its
    ///   longest transmission in the read. A shorter read than asked for is used, and said in `note`. The longer
    ///   read's answer replaces the first's, a name the first gave included.
    public static func identify(iq: [Float], sampleRate: Double, captureCenterHz: Double, atHz: Double,
                                bandwidthHz: Double?, spectrumDb: [Float]?,
                                longer: (() -> (iq: [Float], seconds: Double)?)?) -> SignalIdentity {
        let available = sampleRate > 0 ? Double(iq.count / 2) / sampleRate : 0
        guard available >= minimumSeconds else {
            return SignalIdentity(measurement: SignalMeasurement(seconds: available),
                                  note: "Too soon after tuning — try again")
        }
        let seconds = min(firstSeconds, available)
        let first = Array(iq.suffix(2 * Int((seconds * sampleRate).rounded())))
        let pointHz = atHz - captureCenterHz

        // The seed: an agent's bandwidth, or the extent.
        var seed: (offsetHz: Double, widthHz: Double)
        if let bandwidthHz {
            seed = (pointHz, bandwidthHz)
        } else {
            // In a wide capture, first the point's own neighbourhood (`localExtent`); then the app's spectrum, then
            // the read's own at about 12 Hz a bin, then at about 3 Hz (a narrow signal such as WSPR stands out only
            // there; a wide one pointed between its tones only at the coarser).
            var found = localExtent(first, sampleRate: sampleRate, pointHz: pointHz)
            if found == nil { found = spectrumDb.flatMap { extent($0, sampleRate: sampleRate, pointHz: pointHz) } }
            var spectra: [[Float]] = []
            for binHz in spectrumBinHz where found == nil {
                let size = spectrumSize(sampleRate: sampleRate, binHz: binHz)
                guard spectra.last?.count != size else { continue }
                spectra.append(PowerSpectrum.average(first, size: size, hop: size / 4))
                found = extent(spectra.last!, sampleRate: sampleRate, pointHz: pointHz)
            }
            guard let found else {
                return tooWeak(spectrumDb ?? spectra[0], sampleRate: sampleRate, pointHz: pointHz, seconds: seconds)
            }
            seed = found
        }

        let m = SignalMeasurer.measure(first, sampleRate: sampleRate, offsetHz: seed.offsetHz,
                                       bandwidthHz: seed.widthHz, seconds: seconds)
        let identity = identify(m, rfHz: captureCenterHz + m.offsetHz)
        guard identity.needsLongerRead, let read = longer?(), read.iq.count >= 2 else { return identity }

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
        if slotted, let span = Transmissions.longest(long, sampleRate: sampleRate, offsetHz: m.offsetHz,
                                                      bandwidthHz: max(m.occupiedBandwidthHz, seed.widthHz)) {
            long = Array(long[(2 * span.lowerBound)..<(2 * span.upperBound)])
            readSeconds = Double(span.count) / sampleRate
            notes.append(String(format: "Measured over its longest transmission, %.1f s", readSeconds))
        }
        let slow = SignalMeasurer.measure(long, sampleRate: sampleRate, offsetHz: seed.offsetHz,
                                          bandwidthHz: seed.widthHz, seconds: readSeconds)
        var refined = identify(slow, rfHz: captureCenterHz + slow.offsetHz)
        // The longer read has been made; only a shorter one than asked for leaves a need that more IQ could meet.
        refined.needsLongerRead = refined.needsLongerRead && snapshotSeconds < longSeconds - 0.1
        if let note = refined.note { notes.insert(note, at: 0) }
        refined.note = notes.isEmpty ? nil : notes.joined(separator: "; ")
        return refined
    }

    // MARK: Extent

    /// The extent around `pointHz` in an FFT-shifted spectrum of the whole capture.
    static func extent(_ db: [Float], sampleRate: Double, pointHz: Double) -> (offsetHz: Double, widthHz: Double)? {
        let size = db.count
        guard size >= 8 else { return nil }
        let binHz = sampleRate / Double(size)
        let near = size / 2 + Int((pointHz / binHz).rounded())
        guard near >= 0, near < size,
              let e = Extent.find(spectrumDb: db, binHz: binHz, nearBin: near, searchBins: searchBins) else { return nil }
        return ((Double(e.lowerBin + e.upperBin) / 2 - Double(size / 2)) * binHz,
                Double(e.upperBin - e.lowerBin + 1) * binHz)
    }

    /// The extent in a `localWindowHz` view around the point, for a capture over 1.5 times as wide: there the noise
    /// is the point's own neighbourhood's. Across a whole capture a receiver's IF filter leaves the edges well under
    /// the middle, and a whole-capture percentile takes the passband's own noise for a signal (the owner's 1.25 MS/s
    /// IQ recording read as one "signal" 820 kHz wide wherever it was pointed). Nil when the capture is narrower,
    /// or when the extent reaches the view's edge (a wider signal: the whole capture's spectra find it).
    static func localExtent(_ iq: [Float], sampleRate: Double, pointHz: Double) -> (offsetHz: Double, widthHz: Double)? {
        guard sampleRate >= localCaptureFactor * localWindowHz else { return nil }
        let channel = Channel.extract(iq, sampleRate: sampleRate, offsetHz: pointHz, bandwidthHz: localWindowHz,
                                      sharp: false)
        for binHz in spectrumBinHz {
            var size = 1024
            while size < 65_536 && channel.rate / Double(size) > binHz { size *= 2 }
            let full = PowerSpectrum.average(channel.samples, size: size, hop: size / 4)
            let bin = channel.rate / Double(size)
            let half = Int(0.45 * localWindowHz / bin)
            let view = Array(full[(size / 2 - half)...(size / 2 + half)])
            guard let e = Extent.find(spectrumDb: view, binHz: bin, nearBin: half, searchBins: searchBins) else { continue }
            guard e.lowerBin > 2 && e.upperBin < view.count - 3 else { return nil }
            return (pointHz + (Double(e.lowerBin + e.upperBin) / 2 - Double(half)) * bin,
                    Double(e.upperBin - e.lowerBin + 1) * bin)
        }
        return nil
    }

    /// The FFT size for bins of about `binHz` (1024…16 384); the spectra are averaged over 75%-overlapped frames.
    static func spectrumSize(sampleRate: Double, binHz: Double) -> Int {
        var size = 1024
        while size < 16_384 && sampleRate / Double(size) > binHz { size *= 2 }
        return size
    }

    /// No extent: "Too weak to identify (SNR n dB)" when the default window around the point holds energy over the
    /// local noise (the median of the bins within ±10 windows, the window's own left out), "No signal" otherwise.
    static func tooWeak(_ db: [Float], sampleRate: Double, pointHz: Double, seconds: Double) -> SignalIdentity {
        let size = db.count
        let binHz = sampleRate / Double(size)
        let centre = size / 2 + Int((pointHz / binHz).rounded())
        let half = max(1, Int(defaultWindowHz / 2 / binHz))
        let window = max(0, centre - half)...min(size - 1, centre + half)
        let power = db.map { pow(10, Double($0) / 10) }
        let around = max(0, centre - 10 * half)...min(size - 1, centre + 10 * half)
        let outside = around.filter { !window.contains($0) }.map { power[$0] }.sorted()
        var result = SignalMeasurement(offsetHz: pointHz, seconds: seconds)
        guard !outside.isEmpty, !window.isEmpty else { return SignalIdentity(measurement: result, note: "No signal") }
        let noise = outside[outside.count / 2]
        // The noise bins' own scatter, for the window's mean (its bins share leakage: half as many independent).
        let mean = outside.reduce(0, +) / Double(outside.count)
        let scatter = (outside.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(outside.count)).squareRoot()
        let excess = window.reduce(0) { $0 + power[$1] - noise }
        let threshold = 3 * scatter * (2 * Double(window.count)).squareRoot()
        guard noise > 0, excess > threshold else { return SignalIdentity(measurement: result, note: "No signal") }
        let snr = 10 * log10(excess / (noise * Double(window.count)))
        result.snrDb = snr
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
