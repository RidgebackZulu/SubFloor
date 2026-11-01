import Foundation
import Testing
@testable import SignalID

/// Task 5: the mode table and the matcher, through `SignalIdentifier.identify(iq:…)` the way the app calls it (a
/// capture, the point the pointer rests on, a longer read on request). Seeds 1–50 only (thresholds were tuned on
/// seeds 1000–1099).
@Suite struct IdentifyTests {
    /// Where a catalogue entry is synthesised: the capture rate, its offset in the capture, where the pointer
    /// rests (on one tone of a wide-shift FSK), the signal's RF frequency (inside its row's hints, when it has
    /// any), and how much IQ the first pass gets (wideband captures are kept to 1 s).
    struct Placement: Sendable, CustomStringConvertible {
        var name: String
        var spec: SynthSpec
        var rfHz: Double
        var sampleRate = 48_000.0
        var offsetHz = 3000.0
        var pointHz = 0.0
        var seconds = 3.0
        var description: String { "\(name) [\(spec.label)]" }
        var captureCenterHz: Double { rfHz - offsetHz }
    }

    /// Every catalogue entry, placed.
    static let placements: [Placement] = SynthSpec.catalogue.map { name, spec in
        var p = Placement(name: name, spec: spec, rfHz: 14_000_000)
        switch name {
        case "SSB voice (USB/LSB)": p.rfHz = spec == .lsbVoice ? 7_150_000 : 14_250_000
        case "AM voice/broadcast": p.rfHz = 6_050_000
        case "CW": p.rfHz = 7_020_000
        case "RTTY": p.rfHz = 14_085_000
        case "NAVTEX / SITOR-B": p.rfHz = 518_000
        case "PSK31 / PSK63": p.rfHz = 14_071_000
        case "FT8 / FT4": p.rfHz = spec.label.hasPrefix("FT4") ? 14_081_500 : 14_075_500
        case "WSPR": p.rfHz = 14_097_100
        case "Olivia": p.rfHz = 14_106_000
        case "MFSK16": p.rfHz = 14_108_000
        case "ALE (MIL-STD-188-141)": p.rfHz = 8_000_000
        case "STANAG 4285": p.rfHz = 8_400_000
        case "HF fax": p.rfHz = 7_881_900
        case "DRM": p.rfHz = 9_500_000; p.offsetHz = 6000
        case "HFDL": p.rfHz = 8_977_000
        case "Time signal (WWV/WWVH/CHU)": p.rfHz = 10_000_000
        case "NFM voice": p.rfHz = spec == .nfmVoice(deviationHz: 2500) ? 146_520_000 : 446_100_000
        case "WFM broadcast": p.rfHz = 98_100_000; p.sampleRate = 1_000_000; p.offsetHz = 100_000; p.seconds = 1
        case "AM airband": p.rfHz = 125_000_000
        case "APRS / AX.25": p.rfHz = 144_390_000; p.offsetHz = 6000
        case "POCSAG": p.rfHz = 153_275_000; p.pointHz = 4500
        case "DMR": p.rfHz = 438_500_000
        case "P25 Phase 1": p.rfHz = 851_000_000
        case "NXDN": p.rfHz = 451_000_000
        case "D-STAR": p.rfHz = 145_670_000
        case "YSF (C4FM)": p.rfHz = 439_000_000
        case "AIS": p.rfHz = 161_975_000; p.sampleRate = 96_000
        case "ACARS": p.rfHz = 131_550_000; p.offsetHz = 6000
        case "NOAA APT": p.rfHz = 137_620_000; p.sampleRate = 96_000; p.offsetHz = 6000
        case "DAB": p.rfHz = 222_064_000; p.sampleRate = 2_048_000; p.offsetHz = 0; p.seconds = 1
        default: Issue.record("no placement for \(name)")
        }
        // The wide-shift FSKs: the pointer on one tone (their centre is empty).
        if spec == .rtty(baud: 50, shiftHz: 850) { p.pointHz = 425 }
        if spec == .rtty(baud: 75, shiftHz: 425) { p.pointHz = -212.5 }
        return p
    }

    /// The longest read the slow pass asks for.
    static let longSeconds = 16.0

    /// A capture of `p` at `snr` and what the first pass and the slow pass get from it. At 48 kS/s the capture is
    /// 16 s and the first pass gets its newest `p.seconds` (the slot modes start where their newest 3 s fall inside
    /// a transmission); wider captures get `p.seconds`, and a slow pass synthesises its 16 s afresh.
    static func capture(_ p: Placement, snr: Double, seed: UInt64) -> (iq: [Float], longer: () -> (iq: [Float], seconds: Double)?) {
        var spec = p.spec
        // FT8/FT4: the newest 3 s inside a transmission, at a slot phase that varies with the seed.
        if case .bursts(let inner, var bursts) = spec, bursts.periodSeconds < 60 {
            let end = bursts.startSeconds + 3.5 + Double(seed % 7) / 7 * (bursts.onSeconds - 3.5)
            bursts.captureStartSeconds = (end - longSeconds).truncatingRemainder(dividingBy: bursts.periodSeconds)
                + bursts.periodSeconds
            spec = .bursts(inner, bursts)
        }
        if p.sampleRate <= 96_000 {
            let long = SignalSynth.make(spec, sampleRate: p.sampleRate, seconds: longSeconds, snrDb: snr,
                                        offsetHz: p.offsetHz, seed: seed)
            let first = Array(long.suffix(2 * Int(p.seconds * p.sampleRate)))
            return (first, { (long, longSeconds) })
        }
        let first = SignalSynth.make(spec, sampleRate: p.sampleRate, seconds: p.seconds, snrDb: snr,
                                     offsetHz: p.offsetHz, seed: seed)
        return (first, { nil })
    }

    /// Identifies `p` at `snr` as the app would: pointed at its centre (or tone), with a longer read on request.
    static func identified(_ p: Placement, snr: Double, seed: UInt64, longer: Bool = true) -> SignalIdentity {
        let (iq, read) = capture(p, snr: snr, seed: seed)
        return SignalIdentifier.identify(iq: iq, sampleRate: p.sampleRate, captureCenterHz: p.captureCenterHz,
                                         atHz: p.rfHz + p.pointHz, bandwidthHz: nil, spectrumDb: nil,
                                         longer: longer ? read : nil)
    }

    static func describe(_ id: SignalIdentity) -> String {
        "\(id.label) | best \(id.best.map { "\($0.name) \($0.confidence)" } ?? "nil") | alt "
            + id.alternatives.map { "\($0.name) \(String(format: "%.2f", $0.confidence))" }.joined(separator: ", ")
            + " | \(id.measurement.family) \(id.measurement.notes) | note \(id.note ?? "-")"
    }

    // MARK: Every row

    /// Each row, synthesised at 20 dB at a frequency inside its hints, is named.
    @Test(arguments: placements.indices)
    func eachRowIsNamed(index: Int) {
        let p = Self.placements[index]
        let id = Self.identified(p, snr: 20, seed: UInt64(1 + index % 50))
        #expect(id.best?.name == p.name, "\(p): \(Self.describe(id))")
        #expect(!id.needsLongerRead, "\(p): the slow pass ran but still wants more: \(Self.describe(id))")
    }

    // MARK: Neighbours

    /// DMR (bursty, ±1.944 kHz) and P25 (continuous, ±1.8 kHz) are told apart; a continuous 4-FSK 4800 whose
    /// deviation sits between theirs is named neither, and both are listed. (The in-between case is a measurement:
    /// the measurer reads C4FM spacing within about 2%, so a synthesised one can land on either side.)
    @Test func tdmaAndContinuousFourFSKAreToldApartOrNotNamed() {
        for seed in UInt64(11)...12 {
            let dmr = Self.placements.first { $0.name == "DMR" }!
            let dmrID = Self.identified(dmr, snr: 20, seed: seed)
            #expect(dmrID.best?.name == "DMR", "\(Self.describe(dmrID))")
            let p25 = Self.placements.first { $0.name == "P25 Phase 1" }!
            let p25ID = Self.identified(p25, snr: 20, seed: seed)
            #expect(p25ID.best?.name == "P25 Phase 1", "\(Self.describe(p25ID))")
        }
        // Spacing 1247 Hz: 3.9% over P25's 1200 and 3.8% under DMR's 1296, transmitted continuously.
        let between = SignalMeasurement(occupiedBandwidthHz: 8100, snrDb: 20, envelope: .steady, family: .fsk,
                                        familyConfidence: 1, symbolRate: 4800, toneCount: 4, toneSpacingHz: 1247,
                                        seconds: 3)
        let id = SignalIdentifier.identify(between, rfHz: 440_000_000)
        #expect(id.best == nil, "\(Self.describe(id))")
        let names = id.alternatives.map(\.name)
        #expect(names.contains("DMR") && names.contains("P25 Phase 1"), "\(Self.describe(id))")
        #expect(id.label == "4-FSK · 4800 Bd · 1.2 kHz spacing", "\(id.label)")
    }

    // MARK: Slow signals

    /// WSPR's 1.46 Hz structure doesn't show in 3 s (it reads as a carrier, ruling R13): the first pass asks for
    /// the longer read and doesn't trust the carrier; 16 s names it. It is never named a carrier.
    @Test func wsprNeedsTheLongerRead() {
        let wspr = Self.placements.first { $0.name == "WSPR" }!
        for seed in UInt64(21)...23 {
            let first = Self.identified(wspr, snr: 20, seed: seed, longer: false)
            #expect(first.needsLongerRead, "seed \(seed): \(Self.describe(first))")
            #expect(first.best?.name != "WSPR" || first.best!.confidence >= 0.7)
            #expect(!(first.measurement.family == .carrier && first.measurement.familyConfidence >= 0.7),
                    "seed \(seed): a confident carrier \(Self.describe(first))")
            let slow = Self.identified(wspr, snr: 20, seed: seed)
            #expect(slow.best?.name == "WSPR", "seed \(seed): \(Self.describe(slow))")
            #expect(slow.measurement.family != .carrier, "seed \(seed): \(Self.describe(slow))")
            #expect(slow.measurement.seconds >= 15, "seed \(seed): read \(slow.measurement.seconds) s")
        }
    }

    /// A true carrier waits for the longer read before it is trusted, then is (R13).
    @Test func aCarrierIsTrustedAfterTheLongerRead() {
        let carrier = Placement(name: "carrier", spec: .carrier, rfHz: 10_123_400)
        for seed in UInt64(24)...25 {
            let first = Self.identified(carrier, snr: 20, seed: seed, longer: false)
            #expect(first.needsLongerRead && first.measurement.family == .carrier
                    && first.measurement.familyConfidence < 0.7, "\(Self.describe(first))")
            let slow = Self.identified(carrier, snr: 20, seed: seed)
            #expect(slow.measurement.family == .carrier && slow.measurement.familyConfidence >= 0.7,
                    "\(Self.describe(slow))")
            #expect(slow.best == nil && slow.label.hasPrefix("Carrier"), "\(Self.describe(slow))")
        }
    }

    /// A snapshot shorter than asked for: the slow pass uses what it gets and says so.
    @Test func aShortLongerReadIsUsedAndSaid() {
        let wspr = Self.placements.first { $0.name == "WSPR" }!
        let (iq, read) = Self.capture(wspr, snr: 20, seed: 26)
        let id = SignalIdentifier.identify(iq: iq, sampleRate: wspr.sampleRate, captureCenterHz: wspr.captureCenterHz,
                                           atHz: wspr.rfHz, bandwidthHz: nil, spectrumDb: nil) {
            read().map { (Array($0.iq.suffix(2 * 8 * 48_000)), 8) }
        }
        #expect(id.measurement.seconds <= 8.01, "\(id.measurement.seconds)")
        #expect(id.note?.contains("8.0 s") == true, "\(id.note ?? "no note")")
    }

    /// Weak CW: its SNR read 1–5 dB high on 3 s, the occupied width narrow under the noise (R12). The slow pass reads
    /// it again and its width comes from its keying speed (R16), and its SNR is then within −2/+4 dB (R18).
    @Test func weakCWSNRAfterTheSlowPass() {
        for (index, wpm) in [20.0, 8, 40].enumerated() {
            let cw = Placement(name: "CW", spec: .cw(wpm: wpm), rfHz: 7_020_000)
            for seed in UInt64(27 + 2 * index)...UInt64(28 + 2 * index) {
                let id = Self.identified(cw, snr: 10, seed: seed)
                #expect(id.measurement.seconds >= 15, "\(wpm) WPM seed \(seed): no slow pass \(Self.describe(id))")
                print(String(format: "weakCWSNRAfterTheSlowPass: %.0f WPM seed %d: SNR %.2f dB, width %.0f of %.0f Hz",
                             wpm, seed, id.measurement.snrDb, id.measurement.occupiedBandwidthHz,
                             cw.spec.occupiedBandwidthHz))
                // R18 (superseding R12's 2 dB): within −2/+4 dB after the slow pass.
                let error = id.measurement.snrDb - 10
                #expect(error >= -2 && error <= 4, "\(wpm) WPM seed \(seed): SNR \(id.measurement.snrDb)")
            }
        }
    }

    /// The whole first pass as the app runs it (the read's own spectra, the extent, the measurement and the match)
    /// on 3 s at 2 MS/s with a 12.5 kHz NFM: ≤ 150 ms in a release build, like `firstPassBudget`.
    @Test func identifyFirstPassBudget() {
        let fs = 2_000_000.0
        let iq = SignalSynth.make(.nfmVoice(deviationHz: 5000), sampleRate: fs, seconds: 3, snrDb: 20,
                                  offsetHz: 250_000, seed: 7)
        func run() -> SignalIdentity {
            SignalIdentifier.identify(iq: iq, sampleRate: fs, captureCenterHz: 446_000_000 - 250_000,
                                      atHz: 446_000_000, bandwidthHz: nil, spectrumDb: nil, longer: nil)
        }
        _ = run()
        let clock = ContinuousClock()
        var id = SignalIdentity(measurement: SignalMeasurement())
        let elapsed = clock.measure { id = run() }
        #expect(id.best?.name == "NFM voice", "\(Self.describe(id))")
        print("identifyFirstPassBudget: \(elapsed)")
        if AnalogFamilyTests.optimised() {
            #expect(elapsed <= .milliseconds(150), "identify took \(elapsed)")
        }
    }

    // MARK: Never guess

    /// No name below 0.7, alternatives between 0.3 and the best, at most 3; a hint can't lift a match whose
    /// parameters score under 0.55 to a name.
    @Test func confidenceNeverNamesBelowSeventy() {
        var cases: [(SignalMeasurement, Double)] = []
        // Real identities across the table, at a weak SNR where matches are partial.
        for (index, p) in Self.placements.enumerated() where p.sampleRate <= 96_000 && index % 3 == 0 {
            let id = Self.identified(p, snr: 6, seed: UInt64(30 + index % 20), longer: false)
            cases.append((id.measurement, p.rfHz))
        }
        // Hand-made ones: AM at WWV's frequency without ticks (the hint alone can't name it a time signal), FT8's
        // doubled rate at the FT8 frequency, RTTY's tones at an unknown rate in the RTTY segment.
        cases.append((SignalMeasurement(occupiedBandwidthHz: 6000, snrDb: 20, envelope: .voice, family: .am,
                                        familyConfidence: 1, seconds: 3), 10_000_000))
        cases.append((SignalMeasurement(occupiedBandwidthHz: 64, snrDb: 20, envelope: .steady, family: .fsk,
                                        familyConfidence: 0.6, symbolRate: 12.5, toneCount: 8, toneSpacingHz: 6.25,
                                        seconds: 3), 14_075_500))
        cases.append((SignalMeasurement(occupiedBandwidthHz: 320, snrDb: 20, envelope: .steady, family: .fsk,
                                        familyConfidence: 1, symbolRate: 60, fskShiftHz: 170, toneCount: 2,
                                        toneSpacingHz: 170, seconds: 3), 14_085_000))
        for (m, rf) in cases {
            let id = SignalIdentifier.identify(m, rfHz: rf)
            if let best = id.best { #expect(best.confidence >= 0.7, "\(Self.describe(id))") }
            #expect(id.alternatives.count <= 3)
            for alt in id.alternatives {
                #expect(alt.confidence >= 0.3 && alt.confidence <= (id.best?.confidence ?? 1), "\(Self.describe(id))")
                #expect(alt.name != id.best?.name)
            }
        }
        let wwv = SignalIdentifier.identify(cases[cases.count - 3].0, rfHz: 10_000_000)
        #expect(wwv.best?.name != "Time signal (WWV/WWVH/CHU)", "\(Self.describe(wwv))")
        #expect(wwv.needsLongerRead, "a timing candidate asks for the longer read")
        let ft8 = SignalIdentifier.identify(cases[cases.count - 2].0, rfHz: 14_075_500)
        #expect(ft8.best == nil && ft8.needsLongerRead, "\(Self.describe(ft8))")
        let rtty = SignalIdentifier.identify(cases[cases.count - 1].0, rfHz: 14_085_000)
        #expect(rtty.best == nil, "\(Self.describe(rtty))")
        #expect(rtty.label == "2-FSK · 60 Bd · 170 Hz shift", "\(rtty.label)")
    }

    // MARK: Lines and notes

    @Test func labelsAndSummary() {
        let rtty = SignalMeasurement(offsetHz: 0, occupiedBandwidthHz: 360, snrDb: 20, envelope: .steady, family: .fsk,
                                     familyConfidence: 1, symbolRate: 45.45, fskShiftHz: 169.7, toneCount: 2,
                                     toneSpacingHz: 169.7, seconds: 3)
        let id = SignalIdentifier.identify(rtty, rfHz: 14_085_000)
        #expect(id.best?.name == "RTTY")
        let percent = Int((100 * (id.best?.confidence ?? 0)).rounded())
        #expect(id.label == "RTTY · 45.45 Bd · 170 Hz shift · \(percent)%", "\(id.label)")
        #expect(id.summary["Family"] == "2-FSK")
        #expect(id.summary["Symbol rate"] == "45.45 Bd")
        #expect(id.summary["Shift"] == "170 Hz")

        let sitor = SignalMeasurement(occupiedBandwidthHz: 1300, snrDb: 20, envelope: .steady, family: .fsk,
                                      familyConfidence: 1, symbolRate: 50, fskShiftHz: 850, toneCount: 2,
                                      toneSpacingHz: 850, seconds: 3)
        // 850 Hz RTTY outside the amateur segments (weather, military) is still RTTY by its parameters.
        #expect(SignalIdentifier.identify(sitor, rfHz: 8_000_000).best?.name == "RTTY")
        var unnamed = sitor
        unnamed.symbolRate = 57
        #expect(SignalIdentifier.identify(unnamed, rfHz: 8_000_000).label == "2-FSK · 57 Bd · 850 Hz shift")
    }

    /// Noise gives "No signal"; a signal too weak for an extent gives its SNR from a default window.
    @Test func noSignalAndTooWeak() {
        let noise = SignalSynth.make(.noise, sampleRate: 48_000, seconds: 3, snrDb: 0, seed: 40)
        let none = SignalIdentifier.identify(iq: noise, sampleRate: 48_000, captureCenterHz: 7_000_000,
                                             atHz: 7_003_000, bandwidthHz: nil, spectrumDb: nil, longer: nil)
        #expect(none.best == nil && none.note == "No signal", "\(Self.describe(none))")
        #expect(none.label == "No signal")

        let weak = SignalSynth.make(.usbVoice, sampleRate: 48_000, seconds: 3, snrDb: -3, offsetHz: 3000, seed: 41)
        let id = SignalIdentifier.identify(iq: weak, sampleRate: 48_000, captureCenterHz: 7_000_000,
                                           atHz: 7_003_000, bandwidthHz: nil, spectrumDb: nil, longer: nil)
        #expect(id.best == nil, "\(Self.describe(id))")
        #expect(id.note?.hasPrefix("Too weak to identify (SNR ") == true, "\(Self.describe(id))")
        #expect(id.label == id.note)

        let short = SignalSynth.make(.usbVoice, sampleRate: 48_000, seconds: 0.5, snrDb: 20, offsetHz: 3000, seed: 42)
        let soon = SignalIdentifier.identify(iq: short, sampleRate: 48_000, captureCenterHz: 7_000_000,
                                             atHz: 7_003_000, bandwidthHz: nil, spectrumDb: nil, longer: nil)
        #expect(soon.best == nil && soon.note == "Too soon after tuning — try again", "\(Self.describe(soon))")
    }

    /// A mode wider than the capture is named by family only, with the note (R5, R14).
    @Test func widerThanTheViewIsFamilyOnly() {
        let capture = DigitalFamilyTests.narrowDAB(snr: 20, seed: 43, centreHz: 400_000)
        let id = SignalIdentifier.identify(iq: capture.iq, sampleRate: capture.rate, captureCenterHz: 222_064_000 - 400_000,
                                           atHz: 222_064_000 - 600_000, bandwidthHz: nil, spectrumDb: nil, longer: nil)
        #expect(id.best == nil, "\(Self.describe(id))")
        #expect(id.measurement.family == .ofdm, "\(Self.describe(id))")
        #expect(id.note?.contains("wider than the view — bandwidth is a lower bound") == true, "\(Self.describe(id))")
    }

    /// An agent's bandwidth replaces the extent.
    @Test func anAgentsBandwidthIsTheSeed() {
        let p = Self.placements.first { $0.name == "NAVTEX / SITOR-B" }!
        let (iq, _) = Self.capture(p, snr: 20, seed: 44)
        let id = SignalIdentifier.identify(iq: iq, sampleRate: p.sampleRate, captureCenterHz: p.captureCenterHz,
                                           atHz: p.rfHz, bandwidthHz: 500, spectrumDb: nil, longer: nil)
        #expect(id.best?.name == "NAVTEX / SITOR-B", "\(Self.describe(id))")
    }

    // MARK: Real recordings

    /// The owner's IQ recording (R19, the spec's "one IQ WAV", `SubFloor_20261028_134251Z_11112500Hz_IQ.wav`):
    /// 6 s channelised to 78 125 S/s around 11.180 MHz, through the app's own IQ path. It holds no voice at
    /// 11.175 MHz (its USB passband is flat noise, level with its neighbours, every second of the 17 s) but a comb of
    /// interference lines about 19.4 kHz apart, one at 11.1862 MHz. The passband is "No signal"; the line is never
    /// named.
    @Test func realIQRecording() throws {
        let capture = try Self.iqFixture("SubFloor_20261028_134251Z_IQ_11180000Hz_78125Sps_6s")
        let first = Array(capture.iq.suffix(2 * Int(3 * capture.rate)))
        let voiceBand = SignalIdentifier.identify(iq: first, sampleRate: capture.rate, captureCenterHz: 11_180_000,
                                                  atHz: 11_176_500, bandwidthHz: nil, spectrumDb: nil,
                                                  longer: { (capture.iq, 6) })
        #expect(voiceBand.best == nil && voiceBand.note == "No signal", "\(Self.describe(voiceBand))")
        let line = SignalIdentifier.identify(iq: first, sampleRate: capture.rate, captureCenterHz: 11_180_000,
                                             atHz: 11_186_200, bandwidthHz: nil, spectrumDb: nil,
                                             longer: { (capture.iq, 6) })
        #expect(line.best == nil, "\(Self.describe(line))")
        #expect(line.measurement.occupiedBandwidthHz > 0 && line.measurement.occupiedBandwidthHz < 6000,
                "the line is found locally, not the capture's whole passband: \(Self.describe(line))")
        print("realIQRecording: 11.1765 MHz \(Self.describe(voiceBand)); 11.1862 MHz \(Self.describe(line))")
    }

    /// HFGCS activity at 11.175 MHz in the owner's hour-long IQ capture `captures/SubFloor_20261027_150938Z_11125000Hz_IQ.wav`
    /// (found by scanning it for voice-band excess; 2040–2047.5 s, channelised to 62 500 S/s around 11.178 MHz).
    /// Never a wrong name. It measures as an unknown 3.7–4 kHz signal: see the report.
    @Test func realIQCaptureVoiceBand() throws {
        let capture = try Self.iqFixture("SubFloor_20261027_150938Z_IQ_11178000Hz_62500Sps_7.5s")
        for end in [3.0, 4.5, 6.0, 7.5] {
            let slice = Array(capture.iq[(2 * Int((end - 3) * capture.rate))..<(2 * Int(end * capture.rate))])
            let id = SignalIdentifier.identify(iq: slice, sampleRate: capture.rate, captureCenterHz: 11_178_000,
                                               atHz: 11_176_500, bandwidthHz: nil, spectrumDb: nil, longer: nil)
            #expect(id.best == nil || id.best?.name == "SSB voice (USB/LSB)", "to \(end) s: \(Self.describe(id))")
            print("realIQCaptureVoiceBand to \(end) s: \(Self.describe(id))")
        }
    }

    /// SubFloor's own audio recordings, turned back into IQ (`AnalyticAudio`): 30 s of 11.175 MHz USB voice (HFGCS,
    /// its speech confirmed by the transcription fixtures). The recording's audio AGC lifts the noise between words to
    /// the speech level, so the voice reads 1–2 dB over its passband floor: never a wrong name (see the report).
    @Test func realAudioVoiceIsNeverWronglyNamed() throws {
        let voice = try Self.fixture("SubFloor_20261028_140122Z_11175000Hz_USB_30s")
        let (iq, rate) = AnalyticAudio.iq(fromSSBAudio: voice.samples, sampleRate: voice.rate)
        for end in stride(from: 3.0, through: 30.0, by: 1.0) {
            let start = Int((end - 3) * rate), stop = Int(end * rate)
            let id = SignalIdentifier.identify(iq: Array(iq[(2 * start)..<(2 * stop)]), sampleRate: rate,
                                               captureCenterHz: 11_175_000, atHz: 11_176_500, bandwidthHz: nil,
                                               spectrumDb: nil, longer: nil)
            #expect(id.best == nil || id.best?.name == "SSB voice (USB/LSB)", "window to \(end) s: \(Self.describe(id))")
            print("realAudioVoiceIsNeverWronglyNamed to \(end) s: \(Self.describe(id))")
        }
    }

    /// An FT8 clip from 14.074 MHz (8 s of the :30 slot): pointed at one transmission's track, the strongest
    /// narrow (about 50 Hz) plateau in the averaged spectrum. Never a wrong name; FT8 itself is a known issue (see the
    /// report: the tracks stand about 5 dB over the AGC'd passband).
    @Test func realFT8Track() throws {
        let ft8 = try Self.fixture("SubFloor_20261028_015635Z_14074000Hz_USB_FT8")
        let (iq, rate) = AnalyticAudio.iq(fromSSBAudio: ft8.samples, sampleRate: ft8.rate)
        let audioHz = Self.strongestTrack(iq, rate: rate)
        let id = SignalIdentifier.identify(iq: Array(iq.suffix(2 * Int(3 * rate))), sampleRate: rate,
                                           captureCenterHz: 14_074_000, atHz: 14_074_000 + audioHz, bandwidthHz: nil,
                                           spectrumDb: nil, longer: { (iq, Double(iq.count / 2) / rate) })
        print("realFT8Track at \(audioHz) Hz: \(Self.describe(id))")
        #expect(id.best == nil || id.best?.name == "FT8 / FT4", "FT8 at \(audioHz) Hz: \(Self.describe(id))")
        withKnownIssue("A real FT8 track about 5 dB over an AGC'd passband, 8 s: its FSK doesn't show") {
            #expect(id.best?.name == "FT8 / FT4", "FT8 at \(audioHz) Hz: \(Self.describe(id))")
        }
    }

    /// The audio frequency (200–3000 Hz) of the strongest ~50 Hz plateau: the mean over ±22 Hz against the mean
    /// 43–70 Hz either side, in a spectrum of about 2 Hz bins.
    static func strongestTrack(_ iq: [Float], rate: Double) -> Double {
        let size = 4096
        let power = PowerSpectrum.average(iq, size: size, maxFrames: 4096, hop: size / 8).map { pow(10, Double($0) / 10) }
        let bin = rate / Double(size)
        var best = (hz: 0.0, contrast: -Double.infinity)
        for k in (size / 2 + Int(200 / bin))..<(size / 2 + Int(3000 / bin)) {
            var inner = 0.0, outer = 0.0
            for j in (k - 11)...(k + 11) { inner += power[j] / 23 }
            for j in (k - 36)...(k - 22) { outer += power[j] / 30 }
            for j in (k + 22)...(k + 36) { outer += power[j] / 30 }
            if inner / outer > best.contrast { best = (Double(k - size / 2) * bin, inner / outer) }
        }
        return best.hz
    }

    /// A 16-bit stereo (I, Q) WAV fixture, as interleaved Floats in ±1.
    static func iqFixture(_ name: String) throws -> (iq: [Float], rate: Double) {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "wav", subdirectory: "Fixtures"))
        let data = try Data(contentsOf: url)
        let rate = Double(data[24..<28].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
        let iq = data[44...].withUnsafeBytes { raw in raw.bindMemory(to: Int16.self).map { Float(Int16(littleEndian: $0)) / 32768 } }
        return (iq, rate)
    }

    /// A 16-bit mono WAV fixture, as Floats in ±1.
    static func fixture(_ name: String) throws -> (samples: [Float], rate: Double) {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "wav", subdirectory: "Fixtures"))
        let data = try Data(contentsOf: url)
        func u32(_ at: Int) -> UInt32 { data[at..<(at + 4)].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) } }
        func u16(_ at: Int) -> UInt16 { data[at..<(at + 2)].withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) } }
        var at = 12, rate = 0.0
        while at + 8 <= data.count {
            let id = String(decoding: data[at..<(at + 4)], as: UTF8.self)
            let size = Int(u32(at + 4))
            if id == "fmt " {
                try #require(u16(at + 8) == 1 && u16(at + 10) == 1 && u16(at + 22) == 16, "16-bit mono PCM")
                rate = Double(u32(at + 12))
            } else if id == "data" {
                let samples = data[(at + 8)..<min(data.count, at + 8 + size)].withUnsafeBytes { raw in
                    raw.bindMemory(to: Int16.self).map { Float(Int16(littleEndian: $0)) / 32768 }
                }
                return (samples, rate)
            }
            at += 8 + size + size % 2
        }
        throw FixtureError.noData
    }

    enum FixtureError: Error { case noData }
}

extension SynthSpec {
    /// A short name for test logs.
    var label: String {
        switch self {
        case .bursts(.fsk(let f), _) where f.rate < 2: "WSPR"
        case .bursts(.fsk(let f), _) where f.rate < 30: f.tones == 8 ? "FT8" : "FT4"
        case .bursts(let inner, _): "bursts of \(inner.label)"
        case .fsk(let f): "\(f.tones)-FSK \(f.rate) Bd \(f.spacingHz) Hz"
        case .psk(let p): "\(p.order)-PSK \(p.rate) Bd"
        case .ofdm(let o): "OFDM \(o.carriers) × \(o.spacingHz) Hz"
        case .cw(let wpm): "CW \(wpm) WPM"
        case .fm(_, let deviation): "FM ±\(deviation) Hz"
        case .am(_, let depth): "AM \(depth)"
        case .ssb(let upper, _, _): upper ? "USB" : "LSB"
        case .carrier: "carrier"
        case .noise: "noise"
        }
    }
}
