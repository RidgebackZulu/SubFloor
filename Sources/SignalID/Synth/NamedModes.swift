import Foundation

/// The spec's named modes as test signals. Parameters are the published ones where the spec gives them;
/// shaping that the spec leaves open is noted on each.
extension SynthSpec {
    // MARK: Analog

    /// USB voice, 300–3000 Hz (2.7 kHz).
    public static let usbVoice = SynthSpec.ssb(upper: true, lowHz: 300, highHz: 3000)
    /// LSB voice, 300–3000 Hz (2.7 kHz).
    public static let lsbVoice = SynthSpec.ssb(upper: false, lowHz: 300, highHz: 3000)
    /// AM voice (airband and HF): 300–3000 Hz audio, 80% peak modulation (6 kHz).
    public static let amVoice = SynthSpec.am(.voice(lowHz: 300, highHz: 3000), depth: 0.8)
    /// AM broadcast: steady programme 100–4500 Hz, 80% (9 kHz).
    public static let amBroadcast = SynthSpec.am(.program(lowHz: 100, highHz: 4500, pilotHz: nil), depth: 0.8)
    /// NFM voice: 300–3000 Hz audio; 2.5 kHz deviation for 12.5 kHz channels, 5 kHz for 25 kHz.
    public static func nfmVoice(deviationHz: Double = 2500) -> SynthSpec {
        .fm(.voice(lowHz: 300, highHz: 3000), deviationHz: deviationHz)
    }
    /// WFM broadcast: mono programme 50–15000 Hz plus a 19 kHz pilot, 75 kHz deviation.
    public static let wfmBroadcast = SynthSpec.fm(.program(lowHz: 50, highHz: 15_000, pilotHz: 19_000),
                                                  deviationHz: 75_000)
    /// HF fax: ±400 Hz (1500–2300 Hz on the receiver), 120 lines per minute.
    public static func hfFax(linesPerMinute: Double = 120) -> SynthSpec {
        .fm(.faxVideo(linesPerMinute: linesPerMinute), deviationHz: 400)
    }
    /// WWV-like time signal: AM carrier with second ticks and a 600 Hz tone.
    public static let timeSignal = SynthSpec.am(.timeTicks, depth: 1)
    /// ACARS: AM (80%) carrying 2400 Bd MSK audio, 1200/2400 Hz tones.
    public static let acars = SynthSpec.am(.afsk(centreHz: 1800, FSK(tones: 2, rate: 2400, spacingHz: 1200)),
                                           depth: 0.8)
    /// NOAA APT: FM, ±17 kHz, carrying the 2400 Hz AM subcarrier.
    public static let noaaAPT = SynthSpec.fm(.aptVideo, deviationHz: 17_000)
    /// APRS / AX.25: NFM (3 kHz deviation) carrying Bell 202 AFSK, 1200 Bd, 1200/2200 Hz.
    public static let aprs = SynthSpec.fm(.afsk(centreHz: 1700, FSK(tones: 2, rate: 1200, spacingHz: 1000)),
                                          deviationHz: 3000)

    // MARK: HF digital

    /// RTTY: 2-FSK, `baud` (45.45, 50, 75) and `shiftHz` (170, 425, 850).
    public static func rtty(baud: Double = 45.45, shiftHz: Double = 170) -> SynthSpec {
        .fsk(FSK(tones: 2, rate: baud, spacingHz: shiftHz))
    }
    /// NAVTEX / SITOR-B: 2-FSK, 100 Bd, 170 Hz.
    public static let navtex = SynthSpec.fsk(FSK(tones: 2, rate: 100, spacingHz: 170))
    /// PSK31: BPSK, 31.25 Bd, cosine-shaped reversals.
    public static let psk31 = SynthSpec.psk(PSK(order: 2, rate: 31.25, shape: .cosine))
    /// QPSK31.
    public static let qpsk31 = SynthSpec.psk(PSK(order: 4, rate: 31.25, shape: .cosine))
    /// PSK63: BPSK, 62.5 Bd.
    public static let psk63 = SynthSpec.psk(PSK(order: 2, rate: 62.5, shape: .cosine))
    /// FT8: 8-GFSK (BT 2), 6.25 Bd and Hz, 79 symbols (12.64 s) from 0.5 s into each 15 s slot.
    /// `captureStartInSlot` is where the capture begins on the slot clock.
    public static func ft8(captureStartInSlot: Double = 0) -> SynthSpec {
        .bursts(.fsk(FSK(tones: 8, rate: 6.25, spacingHz: 6.25, gaussianBT: 2)),
                Bursts(periodSeconds: 15, onSeconds: 79 / 6.25, startSeconds: 0.5,
                       captureStartSeconds: captureStartInSlot, rampSeconds: 0.02))
    }
    /// FT4: 4-GFSK (BT 1), 20.833 Bd and Hz, 105 symbols (5.04 s) from 0.5 s into each 7.5 s slot.
    public static func ft4(captureStartInSlot: Double = 0) -> SynthSpec {
        .bursts(.fsk(FSK(tones: 4, rate: 12_000 / 576, spacingHz: 12_000 / 576, gaussianBT: 1)),
                Bursts(periodSeconds: 7.5, onSeconds: 105 * 576 / 12_000.0, startSeconds: 0.5,
                       captureStartSeconds: captureStartInSlot, rampSeconds: 0.01))
    }
    /// WSPR: 4-FSK, 1.4648 Bd and Hz, 162 symbols (110.6 s) from 1 s into each 2 min slot. The default
    /// capture starts 2 s into the slot, inside the transmission.
    public static func wspr(captureStartInSlot: Double = 2) -> SynthSpec {
        .bursts(.fsk(FSK(tones: 4, rate: 12_000 / 8192, spacingHz: 12_000 / 8192)),
                Bursts(periodSeconds: 120, onSeconds: 162 * 8192 / 12_000.0, startSeconds: 1,
                       captureStartSeconds: captureStartInSlot, rampSeconds: 0.1))
    }
    /// Olivia: `tones` MFSK tones across `bandwidthHz`; symbol rate = spacing = bandwidth / tones. The
    /// tones are Gaussian-shaped (BT 1) as an approximation of Olivia's smoothed symbols.
    public static func olivia(tones: Int = 32, bandwidthHz: Double = 1000) -> SynthSpec {
        let spacing = bandwidthHz / Double(tones)
        return .fsk(FSK(tones: tones, rate: spacing, spacingHz: spacing, gaussianBT: 1))
    }
    /// MFSK16: 16 tones, 15.625 Bd and Hz.
    public static let mfsk16 = SynthSpec.fsk(FSK(tones: 16, rate: 15.625, spacingHz: 15.625))
    /// ALE (MIL-STD-188-141): 8-FSK, 125 Bd, 250 Hz spacing (750–2500 Hz on the receiver).
    public static let ale = SynthSpec.fsk(FSK(tones: 8, rate: 125, spacingHz: 250))
    /// STANAG 4285: 8PSK, 2400 Bd, RRC 0.2 (centre = the 1800 Hz carrier).
    public static let stanag4285 = SynthSpec.psk(PSK(order: 8, rate: 2400, shape: .rootRaisedCosine(rolloff: 0.2)))
    /// HFDL: PSK at 1800 Bd (QPSK, RRC 0.35).
    public static let hfdl = SynthSpec.psk(PSK(order: 4, rate: 1800, shape: .rootRaisedCosine(rolloff: 0.35)))
    /// DRM (robustness mode B, 10 kHz): 41.67 Hz spacing, 240 carriers, 1/4 guard interval.
    public static let drm = SynthSpec.ofdm(OFDM(carriers: 240, spacingHz: 1000 / 24.0, cpFraction: 0.25))

    // MARK: VHF and above digital

    /// POCSAG: 2-FSK, ±4.5 kHz, at 512, 1200 or 2400 Bd.
    public static func pocsag(baud: Double = 1200) -> SynthSpec {
        .fsk(FSK(tones: 2, rate: baud, spacingHz: 9000))
    }
    /// DMR: 4-FSK 4800 Bd, ±648/±1944 Hz, in 27.5 ms bursts every 60 ms (one TDMA slot). The RRC
    /// shaping is approximated by a Gaussian pulse (BT 0.5).
    public static let dmr = SynthSpec.bursts(.fsk(FSK(tones: 4, rate: 4800, spacingHz: 1296, gaussianBT: 0.5)),
                                             Bursts(periodSeconds: 0.06, onSeconds: 0.0275))
    /// P25 Phase 1 (C4FM): 4-FSK 4800 Bd, ±600/±1800 Hz, continuous (Gaussian BT 0.5 for the C4FM filter).
    public static let p25 = SynthSpec.fsk(FSK(tones: 4, rate: 4800, spacingHz: 1200, gaussianBT: 0.5))
    /// NXDN: 4-FSK at 2400 Bd (±350/±1050 Hz, 6.25 kHz) or 4800 Bd (±800/±2400 Hz, 12.5 kHz).
    public static func nxdn(baud: Double = 4800) -> SynthSpec {
        .fsk(FSK(tones: 4, rate: baud, spacingHz: baud < 3600 ? 700 : 1600, gaussianBT: 0.5))
    }
    /// D-STAR: GMSK 4800 Bd, BT 0.5.
    public static let dstar = gmsk(rate: 4800, bt: 0.5)
    /// YSF (C4FM): 4-FSK 4800 Bd, ±900/±2700 Hz.
    public static let ysf = SynthSpec.fsk(FSK(tones: 4, rate: 4800, spacingHz: 1800, gaussianBT: 0.5))
    /// AIS: GMSK 9600 Bd, BT 0.4.
    public static let ais = gmsk(rate: 9600, bt: 0.4)
    /// DAB (mode I): 1536 carriers at 1 kHz, guard 246/1000 (1.537 MHz; needs a 2.048 MS/s capture).
    public static let dab = SynthSpec.ofdm(OFDM(carriers: 1536, spacingHz: 1000, cpFraction: 0.246))

    // MARK: Building blocks

    /// MSK: 2-FSK with shift = rate / 2.
    public static func msk(rate: Double) -> SynthSpec { .fsk(FSK(tones: 2, rate: rate, spacingHz: rate / 2)) }
    /// GMSK: MSK with a Gaussian pulse.
    public static func gmsk(rate: Double, bt: Double) -> SynthSpec {
        .fsk(FSK(tones: 2, rate: rate, spacingHz: rate / 2, gaussianBT: bt))
    }
    /// TDMA bursts of `inner`: on for `duty` of every `periodSeconds`.
    public static func tdma(_ inner: SynthSpec, periodSeconds: Double, duty: Double) -> SynthSpec {
        .bursts(inner, Bursts(periodSeconds: periodSeconds, onSeconds: periodSeconds * duty))
    }

    /// One or more test signals for every row of the spec's mode tables, under the row's exact name.
    public static let catalogue: [(name: String, spec: SynthSpec)] = [
        ("SSB voice (USB/LSB)", usbVoice),
        ("SSB voice (USB/LSB)", lsbVoice),
        ("AM voice/broadcast", amVoice),
        ("AM voice/broadcast", amBroadcast),
        ("CW", .cw(wpm: 20)),
        ("CW", .cw(wpm: 8)),
        ("CW", .cw(wpm: 40)),
        ("RTTY", rtty(baud: 45.45, shiftHz: 170)),
        ("RTTY", rtty(baud: 50, shiftHz: 850)),
        ("RTTY", rtty(baud: 75, shiftHz: 425)),
        ("NAVTEX / SITOR-B", navtex),
        ("PSK31 / PSK63", psk31),
        ("PSK31 / PSK63", qpsk31),
        ("PSK31 / PSK63", psk63),
        ("FT8 / FT4", ft8()),
        ("FT8 / FT4", ft4()),
        ("WSPR", wspr()),
        ("Olivia", olivia(tones: 32, bandwidthHz: 1000)),
        ("Olivia", olivia(tones: 8, bandwidthHz: 250)),
        ("MFSK16", mfsk16),
        ("ALE (MIL-STD-188-141)", ale),
        ("STANAG 4285", stanag4285),
        ("HF fax", hfFax()),
        ("DRM", drm),
        ("HFDL", hfdl),
        ("Time signal (WWV/WWVH/CHU)", timeSignal),
        ("NFM voice", nfmVoice(deviationHz: 2500)),
        ("NFM voice", nfmVoice(deviationHz: 5000)),
        ("WFM broadcast", wfmBroadcast),
        ("AM airband", amVoice),
        ("APRS / AX.25", aprs),
        ("POCSAG", pocsag(baud: 512)),
        ("POCSAG", pocsag(baud: 1200)),
        ("POCSAG", pocsag(baud: 2400)),
        ("DMR", dmr),
        ("P25 Phase 1", p25),
        ("NXDN", nxdn(baud: 2400)),
        ("NXDN", nxdn(baud: 4800)),
        ("D-STAR", dstar),
        ("YSF (C4FM)", ysf),
        ("AIS", ais),
        ("ACARS", acars),
        ("NOAA APT", noaaAPT),
        ("DAB", dab),
    ]
}
