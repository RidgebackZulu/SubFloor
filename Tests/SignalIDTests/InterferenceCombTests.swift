import Foundation
import Testing
@testable import SignalID

/// The interference comb (`InterferenceComb`): found on the capture's spectrum, and the lines on it labelled, never named.
@Suite(.serialized) struct InterferenceCombTests {
    /// The synthetic comb: wider spaced than the measurer's FM-comb reach (`SignalMeasurer.combMaxHz`), as the owner's is.
    static let rate = 72_000.0
    static let centreHz = 7_000_000.0
    static let spacingHz = 6000.0
    static let firstHz = -27_000.0
    static let lines = 10

    /// Noise of unit power over `rate`, with a comb `db` over the noise in a map bin (`TraceFinderTests.amplitude`).
    static func capture(lines: Int = lines, db: Double = 25, wanderHz: Double = 0, skipping: Set<Int> = [],
                        seconds: Double = 3, seed: UInt64) -> [Float] {
        var iq = SignalSynth.make(.noise, sampleRate: rate, seconds: seconds, snrDb: 0, seed: seed)
        let comb = SignalSynth.comb(firstHz: firstHz, spacingHz: spacingHz, count: lines,
                                    amplitude: TraceFinderTests.amplitude(db: db, rate: rate), sampleRate: rate, seconds: seconds,
                                    wanderHz: wanderHz, skipping: skipping, seed: seed)
        for k in iq.indices { iq[k] += comb[k] }
        return iq
    }

    /// The app's averaged spectrum of a capture.
    static func spectrum(_ iq: [Float], rate: Double = rate) -> [Float] {
        PowerSpectrum.average(iq, size: 8192, maxFrames: .max, hop: 2048)
    }

    /// `signal` (unit mean power) added to `iq` `snrDb` over the noise (unit power over `rate`) in `widthHz`.
    static func add(_ signal: [Float], to iq: inout [Float], snrDb: Double, widthHz: Double, rate: Double = rate) {
        let gain = Float((pow(10, snrDb / 10) * widthHz / rate).squareRoot())
        for k in iq.indices { iq[k] += gain * signal[k] }
    }

    /// `iq` identified at `offsetHz`, with the capture's spectrum, and `iq` itself again when a longer read is asked for
    /// (`longer`: what a narrow trace's tones are read on).
    static func identified(_ iq: [Float], at offsetHz: Double, spectrum: [Float]?, longer: Bool = false) -> SignalIdentity {
        let seconds = Double(iq.count / 2) / rate
        return SignalIdentifier.identify(iq: iq, sampleRate: rate, captureCenterHz: centreHz, atHz: centreHz + offsetHz,
                                         bandwidthHz: nil, spectrumDb: nil, longer: longer ? { (iq, seconds) } : nil,
                                         captureSpectrumDb: spectrum, captureRate: rate)
    }

    static func lineHz(_ k: Int) -> Double { firstHz + Double(k) * spacingHz }

    // MARK: The owner's recordings

    /// The 14 MHz recording's comb: lines about 19.3 kHz apart from 13.69 to 14.35 MHz at least, many doubled about 1 kHz
    /// apart (the corpus's comb points, 14.0769 and 14.0780 MHz, are one such pair), their steps 19.0 to 20.1 kHz.
    /// Both parts' spectra (the held-out one read only once the code was final).
    @Test func realCaptureHasTheComb() throws {
        for part in CorpusPart.allCases {
            let clip = try #require(try RealCorpus.clips().first { $0.part == part && $0.name.hasPrefix("14MHz") })
            let found = try #require(InterferenceComb.detect(spectrumDb: clip.captureSpectrumDb, sampleRate: clip.captureRate))
            print("realCaptureHasTheComb \(part): \(found.info), \(found.lineOffsetsHz.count) lines")
            #expect((19_000...19_500).contains(found.info.spacingHz), "\(part): \(found.info)")
            #expect(found.info.lineCount >= InterferenceComb.minimumLines, "\(part): \(found.info)")
            let rf = found.lineOffsetsHz.map { clip.captureCenterHz + $0 }
            for line in [14_076_917.0, 14_077_955] {
                #expect(rf.contains { abs($0 - line) < 60 }, "\(part): \(line) Hz isn't a line of \(found.info)")
            }
            #expect((rf.min() ?? .infinity) <= 13_690_000 && (rf.max() ?? 0) >= 14_350_000, "\(part): \(found.info)")
        }
    }

    /// The tuning part's comb windows, with a longer read of 5 s (the hover's goes to 16 s; `heldOutTargets` takes that
    /// path): a line whose level dips with the receiver's gain (12 s, keeping step with its pair), and one whose doubled
    /// pair with a slot mode's tracks beside it would make an area of them (15 s), are both labelled comb.
    ///
    /// A margin to know of: on the held-out part the 14076917 Hz line stands 2.91 dB over its floor against
    /// `InterferenceComb.bareDb`'s 3 dB cut (0.09 dB, measured once the code was final, not tuned on), so a change to the
    /// app's spectrum averaging, `backgroundHz` or `floorShare` can flip it, and the gated `heldOutTargets` comb row with
    /// it. The principled fix is a separate, higher cut for dropping one line from an otherwise-bare grid, chosen on the
    /// tuning part (the Task 5 note); `bareDb` is not to be retuned on held-out data.
    @Test func realCombLinesAreLabelled() throws {
        let clips = try RealCorpus.clips()
        for (atHz, end) in [(14_077_955.0, 12.0), (14_076_917, 15)] {
            let point = try #require(try RealCorpus.points(.tuning).first { $0.truth == "comb" && $0.atHz == atHz && $0.endSeconds == end })
            let clip = try #require(clips.first { $0.name == point.clip })
            func read(_ seconds: Double) -> [Float] {
                let last = 2 * Int((end * clip.rate).rounded())
                return Array(clip.iq[(last - 2 * Int((seconds * clip.rate).rounded()))..<last])
            }
            let long = read(5)
            let id = SignalIdentifier.identify(iq: read(3), sampleRate: clip.rate, captureCenterHz: clip.centerHz, atHz: atHz,
                                               bandwidthHz: nil, spectrumDb: clip.spectrumDb, longer: { (long, 5) },
                                               captureSpectrumDb: clip.captureSpectrumDb, captureRate: clip.captureRate,
                                               captureSpectrumCenterHz: clip.captureCenterHz)
            #expect(id.comb != nil && id.label == "Interference comb · 19.3 kHz spacing", "\(atHz) Hz at \(end) s: \(IdentifyTests.describe(id))")
        }
    }

    /// The 11.7 MHz recording, inside the 25 m broadcast band. The receiver's comb is there too: its lines make a grid
    /// about 19.3 kHz apart, as at 14 MHz, none of them on the FSK's tones. But half of them and more stand on broadcasts'
    /// sidebands, so no comb is reported (step 4): a change to either shows here.
    @Test func realFSKCaptureComb() throws {
        let fsk = try #require(try RealCorpus.points(.tuning).first { $0.truth == "2-FSK" })
        let shift = try #require(fsk.parameters?["shiftHz"])
        for part in CorpusPart.allCases {
            let clip = try #require(try RealCorpus.clips().first { $0.part == part && $0.name.hasPrefix("11.7MHz") })
            let binHz = clip.captureRate / Double(clip.captureSpectrumDb.count)
            let found = InterferenceComb.detect(spectrumDb: clip.captureSpectrumDb, sampleRate: clip.captureRate)
            #expect(found == nil, "\(part): \(String(describing: found?.info))")
            let grid = try #require(InterferenceComb.fit(InterferenceComb.lines(clip.captureSpectrumDb, binHz: binHz),
                                                         spacing: 19_270), "\(part): no grid")
            let bare = InterferenceComb.bare(grid.lines, spacing: grid.spacing, db: clip.captureSpectrumDb, binHz: binHz)
                .compactMap { $0 }
            print("realFSKCaptureComb \(part): grid \(grid.spacing) Hz, \(grid.places) places, \(bare.filter { $0 }.count) of \(bare.count) bare")
            #expect((19_000...19_500).contains(grid.spacing) && grid.places >= InterferenceComb.minimumLines, "\(part)")
            #expect(Double(bare.filter { $0 }.count) < InterferenceComb.minBareShare * Double(bare.count), "\(part)")
            for line in grid.lines {
                for tone in [fsk.atHz - shift / 2, fsk.atHz + shift / 2] {
                    #expect(abs(clip.captureCenterHz + line.offsetHz - tone) > 100,
                            "\(part): a grid line at \(clip.captureCenterHz + line.offsetHz) Hz")
                }
            }
        }
    }

    // MARK: What is a comb

    /// Steady lines evenly spaced are a comb from `minimumLines` of them; fewer are only lines.
    @Test func tooFewLinesIsNoComb() {
        let many = InterferenceComb.detect(spectrumDb: Self.spectrum(Self.capture(lines: 8, seconds: 1, seed: 501)), sampleRate: Self.rate)
        #expect(many?.info.lineCount == 8 && abs((many?.info.spacingHz ?? 0) - Self.spacingHz) < 20, "\(String(describing: many?.info))")
        let few = InterferenceComb.detect(spectrumDb: Self.spectrum(Self.capture(lines: 5, seconds: 1, seed: 502)), sampleRate: Self.rate)
        #expect(few == nil, "\(String(describing: few?.info))")
    }

    /// The lines of one comb are alike in width: narrow lines and lines four times as wide on one grid are two sources.
    /// Six narrow and four wide are no comb; eight narrow and two wide are the eight narrow lines' comb.
    @Test func linesUnlikeTheCombAreNotItsLines() throws {
        func grid(wide: Set<Int>, seed: UInt64) -> [Float] {
            var iq = Self.capture(skipping: wide, seconds: 1, seed: seed)
            let others = SignalSynth.comb(firstHz: Self.firstHz, spacingHz: Self.spacingHz, count: Self.lines,
                                          amplitude: TraceFinderTests.amplitude(db: 30, rate: Self.rate), sampleRate: Self.rate,
                                          seconds: 1, wanderHz: 60, skipping: Set(0..<Self.lines).subtracting(wide), seed: seed + 1)
            for k in iq.indices { iq[k] += others[k] }
            return Self.spectrum(iq)
        }
        let mixed = InterferenceComb.detect(spectrumDb: grid(wide: [1, 4, 6, 8], seed: 571), sampleRate: Self.rate)
        #expect(mixed == nil, "\(String(describing: mixed?.info))")
        let mostly = try #require(InterferenceComb.detect(spectrumDb: grid(wide: [3, 7], seed: 573), sampleRate: Self.rate))
        #expect(mostly.info.lineCount == 8, "\(mostly.info)")
        for wide in [3, 7] {
            #expect(!mostly.lineOffsetsHz.contains { abs($0 - Self.lineHz(wide)) < 100 }, "the wide line at \(Self.lineHz(wide)) Hz")
        }
    }

    /// Stations packed close (FT8 tracks 200 Hz apart in a sub-band) are no comb, however evenly spaced: a comb's lines
    /// stand many of their widths apart.
    @Test func packedStationsAreNoComb() {
        let seconds = 2.0
        var iq = SignalSynth.make(.noise, sampleRate: Self.rate, seconds: seconds, snrDb: 0, seed: 581)
        for k in 0..<12 {
            let ft8 = SignalSynth.make(.ft8(captureStartInSlot: 1), sampleRate: Self.rate, seconds: seconds, snrDb: .infinity,
                                       offsetHz: Double(k) * 200 - 1100, seed: 560 + UInt64(k))
            Self.add(ft8, to: &iq, snrDb: 10, widthHz: 50)
        }
        let found = InterferenceComb.detect(spectrumDb: Self.spectrum(iq), sampleRate: Self.rate)
        #expect(found == nil, "\(String(describing: found?.info))")
    }

    /// `stations` AM stations `channelHz` apart (voice to 4.5 kHz) at `topDb` down to 10 dB under it over the noise in 9 kHz,
    /// in a 150 kS/s capture over 0.5 s, and the same carriers bare; their averaged spectra.
    static func broadcasts(channelHz: Double, topDb: Double, stations: Int = 12) -> (broadcast: [Float], bare: [Float]) {
        let rate = 150_000.0, seconds = 0.5
        var broadcast = SignalSynth.make(.noise, sampleRate: rate, seconds: seconds, snrDb: 0, seed: 511)
        var bare = broadcast
        for k in 0..<stations {
            let offset = (Double(k) - Double(stations - 1) / 2) * channelHz
            let am = SignalSynth.make(.am(.voice(lowHz: 100, highHz: 4500), depth: 0.8), sampleRate: rate, seconds: seconds,
                                      snrDb: .infinity, offsetHz: offset, seed: 512 + UInt64(k))
            Self.add(am, to: &broadcast, snrDb: topDb - Double(k % 3) * 5, widthHz: 9000, rate: rate)
            TraceFinderTests.addCarrier(to: &bare, offsetHz: offset, rate: rate,
                                        amplitude: TraceFinderTests.amplitude(db: topDb + 10, rate: rate))
        }
        let spectrum = { (iq: [Float]) in PowerSpectrum.average(iq, size: 8192, maxFrames: .max, hop: 2048) }
        return (spectrum(broadcast), spectrum(bare))
    }

    static let broadcastRate = 150_000.0

    /// Channelled AM broadcasts, 10 kHz apart (and 9 under `SUBFLOOR_SIGNALID_MATRIX=1`), strong or weak: never a comb.
    /// A weak station's sidebands lie under the noise, so its raster tells it.
    @Test(arguments: Sweep.full ? [10_000.0, 9000] : [10_000]) func channelledBroadcastsAreNotAComb(channelHz: Double) {
        for topDb in Sweep.full ? [15.0, 30, 45] : [15] {
            let found = InterferenceComb.detect(spectrumDb: Self.broadcasts(channelHz: channelHz, topDb: topDb).broadcast,
                                                sampleRate: Self.broadcastRate)
            #expect(found == nil, "\(channelHz) Hz channels at \(topDb) dB: \(String(describing: found?.info))")
        }
    }

    /// Strong AM stations evenly spaced off any broadcast raster (11 kHz) stand on their own sidebands: no comb. The same
    /// carriers bare are one.
    @Test func modulatedLinesAreNoComb() {
        let (broadcast, bare) = Self.broadcasts(channelHz: 11_000, topDb: 30)
        let found = InterferenceComb.detect(spectrumDb: broadcast, sampleRate: Self.broadcastRate)
        #expect(found == nil, "\(String(describing: found?.info))")
        let lines = InterferenceComb.detect(spectrumDb: bare, sampleRate: Self.broadcastRate)
        #expect(lines?.info.lineCount == 12 && abs((lines?.info.spacingHz ?? 0) - 11_000) < 20,
                "the same carriers bare: \(String(describing: lines?.info))")
    }

    /// On the grid, a keyed or modulated signal keeps its own answer: CW is named, a carrier keyed on and off slowly (a
    /// beacon) and an AM station are no comb lines. A steady line beside them is.
    @Test func keyedSignalOnTheGridIsNamed() {
        let slot = 5, amSlot = 2, fskSlot = 8
        let seconds = 2.0
        var iq = Self.capture(skipping: [slot, slot + 2, amSlot, fskSlot], seconds: seconds, seed: 521)
        let cw = SignalSynth.make(.cw(wpm: 20), sampleRate: Self.rate, seconds: seconds, snrDb: .infinity,
                                  offsetHz: Self.lineHz(slot), seed: 522)
        Self.add(cw, to: &iq, snrDb: 20, widthHz: 100)
        // On for 1.2 s of every 2: it measures as a carrier, so only its keying says it is no comb line.
        let keyed = SignalSynth.make(.bursts(.carrier, .init(periodSeconds: 2, onSeconds: 1.2)), sampleRate: Self.rate,
                                     seconds: seconds, snrDb: .infinity, offsetHz: Self.lineHz(slot + 2), seed: 523)
        Self.add(keyed, to: &iq, snrDb: 20, widthHz: 100)
        // AM by a steady tone: nothing names it, so only its modulation says it is no comb line.
        let am = SignalSynth.make(.am(.tone(1000), depth: 0.5), sampleRate: Self.rate, seconds: seconds, snrDb: .infinity,
                                  offsetHz: Self.lineHz(amSlot), seed: 524)
        Self.add(am, to: &iq, snrDb: 20, widthHz: 2000)
        // RTTY centred on a place: its tones key in turn.
        let rtty = SignalSynth.make(.rtty(), sampleRate: Self.rate, seconds: seconds, snrDb: .infinity,
                                    offsetHz: Self.lineHz(fskSlot), seed: 525)
        Self.add(rtty, to: &iq, snrDb: 20, widthHz: 250)
        let spectrum = Self.spectrum(iq)
        let comb = InterferenceComb.detect(spectrumDb: spectrum, sampleRate: Self.rate)
        #expect(comb != nil, "the comb is found")
        let onCW = Self.identified(iq, at: Self.lineHz(slot), spectrum: spectrum)
        #expect(onCW.comb == nil && onCW.best?.name == "CW", "CW: \(IdentifyTests.describe(onCW))")
        // After the longer read (its tones tried): only its keying keeps it from the comb.
        let onKeyed = Self.identified(iq, at: Self.lineHz(slot + 2), spectrum: spectrum, longer: true)
        #expect(onKeyed.comb == nil && onKeyed.label == "Carrier", "keyed: \(IdentifyTests.describe(onKeyed))")
        let onAM = Self.identified(iq, at: Self.lineHz(amSlot), spectrum: spectrum)
        #expect(onAM.comb == nil && onAM.best == nil && onAM.measurement.family == .am, "AM: \(IdentifyTests.describe(onAM))")
        let onFSK = Self.identified(iq, at: Self.lineHz(fskSlot) + 85, spectrum: spectrum)
        #expect(onFSK.comb == nil && onFSK.measurement.family == .fsk
                && abs((onFSK.measurement.fskShiftHz ?? 0) - 170) <= 5, "RTTY: \(IdentifyTests.describe(onFSK))")
        let onLine = Self.identified(iq, at: Self.lineHz(slot - 1), spectrum: spectrum)
        #expect(onLine.comb != nil && onLine.best == nil && onLine.label == "Interference comb · 6.0 kHz spacing",
                "a steady line: \(IdentifyTests.describe(onLine))")
        // A capture's spectrum without its rate shows no grid: no rate is guessed for it.
        let rateless = SignalIdentifier.identify(iq: iq, sampleRate: Self.rate, captureCenterHz: Self.centreHz,
                                                 atHz: Self.centreHz + Self.lineHz(slot - 1), bandwidthHz: nil, spectrumDb: nil,
                                                 longer: nil, captureSpectrumDb: spectrum)
        #expect(rateless.comb == nil, "without the capture's rate: \(IdentifyTests.describe(rateless))")
    }

    /// A strong AM voice station on a comb place (its carrier on it, and 600 Hz off another) keeps its name: a carrier on
    /// its own sidebands is none of the comb's lines, so neither its area nor its window is taken for the comb.
    @Test func aStationOnACombPlaceKeepsItsName() throws {
        let seconds = 2.0, onPlace = 2, offPlace = 7
        var iq = Self.capture(skipping: [onPlace, offPlace], seconds: seconds, seed: 591)
        for (slot, offset, snr) in [(onPlace, 0.0, 35.0), (offPlace, 600, 45)] {
            let am = SignalSynth.make(.am(.voice(lowHz: 100, highHz: 4500), depth: 0.8), sampleRate: Self.rate, seconds: seconds,
                                      snrDb: .infinity, offsetHz: Self.lineHz(slot) + offset, seed: 592 + UInt64(slot))
            Self.add(am, to: &iq, snrDb: snr, widthHz: 9000)
        }
        let spectrum = Self.spectrum(iq)
        let comb = try #require(InterferenceComb.detect(spectrumDb: spectrum, sampleRate: Self.rate))
        for (slot, offset, snr) in [(onPlace, 0.0, 35.0), (offPlace, 600, 45)] {
            let carrier = Self.lineHz(slot) + offset
            #expect(!comb.lineOffsetsHz.contains { abs($0 - carrier) < 100 }, "\(snr) dB carrier taken for a comb line")
            let id = Self.identified(iq, at: carrier, spectrum: spectrum)
            #expect(id.comb == nil && id.best?.name == "AM voice/broadcast", "\(snr) dB: \(IdentifyTests.describe(id))")
        }
    }

    /// A comb's lines are neither noise nor energy at an empty point: lines wandering about 120 Hz wide, too faint there to
    /// say plainly they are signals of their own, leave the noise the view reads within 2 dB of what it is without them,
    /// and the points beside them `No signal` (without the comb known they read `Too weak to identify`).
    @Test func combIgnoredByNoiseFloor() throws {
        let seed: UInt64 = 531
        let iq = Self.capture(db: 20, wanderHz: 60, seconds: 2, seed: seed)
        let noise = SignalSynth.make(.noise, sampleRate: Self.rate, seconds: 2, snrDb: 0, seed: seed)
        let spectrum = Self.spectrum(iq)
        try #require(InterferenceComb.detect(spectrumDb: spectrum, sampleRate: Self.rate) != nil)
        let point = Self.lineHz(4) + 700
        let near = TraceFinder.find(SignalIdentifier.neighbourhoodMap(iq, sampleRate: Self.rate, pointHz: point)).noiseDb
        let without = TraceFinder.find(SignalIdentifier.neighbourhoodMap(noise, sampleRate: Self.rate, pointHz: point)).noiseDb
        #expect(abs(near - without) <= 2, "\(near) dB near the comb, \(without) dB without it")
        for beside in [300.0, 1100] {
            let id = Self.identified(iq, at: Self.lineHz(4) + beside, spectrum: spectrum)
            #expect(id.note == SignalIdentifier.noSignalNote && id.measurement.occupiedBandwidthHz == 0,
                    "\(beside) Hz from a line: \(IdentifyTests.describe(id))")
        }
        // As wide as it is, it may be a narrow MFSK: labelled once the longer read has tried its tones.
        let quick = Self.identified(iq, at: Self.lineHz(4), spectrum: spectrum)
        #expect(quick.comb == nil && quick.needsLongerRead, "the quick answer: \(IdentifyTests.describe(quick))")
        let line = Self.identified(iq, at: Self.lineHz(4), spectrum: spectrum, longer: true)
        #expect(line.comb != nil, "the line itself: \(IdentifyTests.describe(line))")
    }

    /// A beacon on a comb place, on for 3.5 s of every 6: steady over the newest 3 s, which it is on for, but keyed over the
    /// longer read, so no comb line once that is made. A steady line beside it, on the same read, still is one.
    @Test func aSlowBeaconIsJudgedOnTheLongerRead() throws {
        let slot = 5, seconds = 9.4   // the newest 3 s (6.4–9.4 s) lie in its second transmission
        var iq = Self.capture(skipping: [slot], seconds: seconds, seed: 601)
        let beacon = SignalSynth.make(.bursts(.carrier, .init(periodSeconds: 6, onSeconds: 3.5)), sampleRate: Self.rate,
                                      seconds: seconds, snrDb: .infinity, offsetHz: Self.lineHz(slot), seed: 602)
        Self.add(beacon, to: &iq, snrDb: 20, widthHz: 100)
        let spectrum = Self.spectrum(iq)
        try #require(InterferenceComb.detect(spectrumDb: spectrum, sampleRate: Self.rate) != nil)
        let first = Array(iq.suffix(2 * Int(3 * Self.rate)))
        let quick = Self.identified(first, at: Self.lineHz(slot), spectrum: spectrum)
        #expect(quick.comb != nil, "the newest 3 s alone: \(IdentifyTests.describe(quick))")
        func long(_ offsetHz: Double) -> SignalIdentity {
            SignalIdentifier.identify(iq: first, sampleRate: Self.rate, captureCenterHz: Self.centreHz,
                                      atHz: Self.centreHz + offsetHz, bandwidthHz: nil, spectrumDb: nil,
                                      longer: { (iq, seconds) }, captureSpectrumDb: spectrum, captureRate: Self.rate)
        }
        let keyed = long(Self.lineHz(slot))
        #expect(keyed.comb == nil && keyed.best == nil, "over the longer read: \(IdentifyTests.describe(keyed))")
        let steady = long(Self.lineHz(slot - 1))
        #expect(steady.comb != nil, "a steady line: \(IdentifyTests.describe(steady))")
    }

    /// An agent's width on a wandering comb line: the quick answer asks for the longer read, which tries its tones (they
    /// don't read) and labels it the comb's, as without a width; an FT8's do read, and it is none.
    @Test func anAgentsWidthOnACombLineIsLabelled() throws {
        let iq = Self.capture(db: 20, wanderHz: 60, seconds: 2, seed: 531)
        let spectrum = Self.spectrum(iq)
        let comb = try #require(CaptureComb.find(spectrumDb: spectrum, sampleRate: Self.rate, centerHz: Self.centreHz))
        func at(_ widthHz: Double, longer: Bool) -> SignalIdentity {
            SignalIdentifier.identify(iq: iq, sampleRate: Self.rate, captureCenterHz: Self.centreHz,
                                      atHz: Self.centreHz + Self.lineHz(4), bandwidthHz: widthHz, spectrumDb: nil,
                                      longer: longer ? { (iq, 2) } : nil, comb: comb)
        }
        for width in [200.0, 2000] {
            let quick = at(width, longer: false)
            #expect(quick.comb == nil && quick.needsLongerRead, "\(width) Hz, quick: \(IdentifyTests.describe(quick))")
            let line = at(width, longer: true)
            #expect(line.comb == comb.info, "\(width) Hz, the longer read: \(IdentifyTests.describe(line))")
        }
        // An FT8 on a comb place (its average a line of the grid, and on for all 3 s), under a width too narrow to name it:
        // its tones read on the longer read, so it is no comb line.
        let slot = 6, seconds = 6.0
        var withFT8 = Self.capture(db: 20, wanderHz: 60, skipping: [slot], seconds: seconds, seed: 531)
        let ft8 = SignalSynth.make(.ft8(captureStartInSlot: 1), sampleRate: Self.rate, seconds: seconds, snrDb: .infinity,
                                   offsetHz: Self.lineHz(slot), seed: 611)
        Self.add(ft8, to: &withFT8, snrDb: 15, widthHz: 50)
        let ft8Comb = try #require(CaptureComb.find(spectrumDb: Self.spectrum(withFT8), sampleRate: Self.rate,
                                                    centerHz: Self.centreHz))
        let onFT8 = SignalIdentifier.identify(iq: Array(withFT8.suffix(2 * Int(3 * Self.rate))), sampleRate: Self.rate,
                                              captureCenterHz: Self.centreHz, atHz: Self.centreHz + Self.lineHz(slot),
                                              bandwidthHz: 20, spectrumDb: nil, longer: { (withFT8, seconds) },
                                              comb: ft8Comb)
        #expect(onFT8.comb == nil, "an FT8 under a 20 Hz width: \(IdentifyTests.describe(onFT8))")
    }

    /// An FT8 beside a comb line (`lineFromFT8Hz` above its centre), 2.5 s into its transmission, keeps its name: the
    /// comb takes no name away. The line beside it is the comb's.
    static func ft8BesideALine(lineFromFT8Hz: Double, spectrum withComb: Bool = true) -> (ft8: SignalIdentity, line: SignalIdentity) {
        let rfHz = 14_075_500.0
        let capture = SlotEvidenceTests.capture(.ft8(), readSeconds: 3, endInTransmission: 2.5, rfHz: rfHz, seed: 12)
        var iq = capture.first
        // The comb across a wider capture, centred so that one of its lines lies there.
        let wideCentre = rfHz + lineFromFT8Hz - Self.lineHz(4)
        let spectrum = Self.spectrum(Self.capture(seconds: 1, seed: 541))
        let ft8Rate = SlotEvidenceTests.rate, iqCentre = rfHz - SlotEvidenceTests.offsetHz
        let noisePerBin = 0.1 * 12 / SynthSpec.ft8().occupiedBandwidthHz
        for k in 0..<Self.lines {
            let offset = wideCentre + Self.lineHz(k) - iqCentre
            guard abs(offset) < 0.45 * ft8Rate else { continue }
            TraceFinderTests.addCarrier(to: &iq, offsetHz: offset, rate: ft8Rate,
                                        amplitude: Float((10 * noisePerBin).squareRoot()), phase: Double(k))
        }
        func at(_ hz: Double) -> SignalIdentity {
            SignalIdentifier.identify(iq: iq, sampleRate: ft8Rate, captureCenterHz: iqCentre, atHz: hz, bandwidthHz: nil,
                                      spectrumDb: nil, longer: nil, captureSpectrumDb: withComb ? spectrum : nil,
                                      captureRate: Self.rate, captureSpectrumCenterHz: wideCentre)
        }
        return (at(rfHz), at(rfHz + lineFromFT8Hz))
    }

    /// (`SUBFLOOR_SIGNALID_MATRIX=1`: no guard rests on it alone; the corpus's FT8 beside the real pair is scored there too.)
    @Test(.enabled(if: Sweep.full)) func aNamedSignalBesideALineKeepsItsName() throws {
        let (ft8, line) = Self.ft8BesideALine(lineFromFT8Hz: 300)
        #expect(ft8.comb == nil && ft8.best?.name == "FT8", "\(IdentifyTests.describe(ft8))")
        #expect(line.comb != nil, "\(IdentifyTests.describe(line))")
    }

    /// Rows of stations (`SUBFLOOR_SIGNALID_MATRIX=1`). Scattered as real ones are (FT8 in a 3 kHz sub-band, RTTY over
    /// 12 kHz), or packed as a sub-band's tracks are (FT8 200 Hz apart, each line on the others' skirts): no comb. Evenly spaced, a spectrum alone can't tell their keying from a comb's steady lines, and may call
    /// them one; the read can (an FT8's tones once the longer read has read them), and none of them is labelled comb.
    @Test(.enabled(if: Sweep.full)) func rowsOfStationsAreNeverLabelledComb() {
        let rate = Self.rate, seconds = 3.0
        var random = SynthRandom(seed: 551, stream: 9)
        let rows: [(name: String, spec: SynthSpec, widthHz: Double, offsets: [Double])] = [
            ("FT8 scattered", .ft8(captureStartInSlot: 1), 50, (0..<12).map { _ in random.uniform(-1500...1500) }),
            ("RTTY scattered", .rtty(), 250, (0..<12).map { _ in random.uniform(-6000...6000) }),
            ("FT8 every 1 kHz", .ft8(captureStartInSlot: 1), 50, (0..<12).map { Double($0) * 1000 - 5500 }),
            ("FT8 every 200 Hz", .ft8(captureStartInSlot: 1), 50, (0..<12).map { Double($0) * 200 - 1100 }),
            ("RTTY every 1 kHz", .rtty(), 250, (0..<12).map { Double($0) * 1000 - 5500 }),
            ("RTTY every 5 kHz", .rtty(), 250, (0..<12).map { Double($0) * 5000 - 27_500 }),
            ("PSK31 every 400 Hz", .psk31, 60, (0..<12).map { Double($0) * 400 - 2200 }),
        ]
        for (index, row) in rows.enumerated() {
            for snr in [10.0, 25] {
                var iq = SignalSynth.make(.noise, sampleRate: rate, seconds: seconds, snrDb: 0, seed: 552 + UInt64(index))
                for (k, offset) in row.offsets.enumerated() {
                    let station = SignalSynth.make(row.spec, sampleRate: rate, seconds: seconds, snrDb: .infinity,
                                                   offsetHz: offset, seed: 560 + UInt64(k))
                    Self.add(station, to: &iq, snrDb: snr, widthHz: row.widthHz)
                }
                let spectrum = Self.spectrum(iq)
                let found = InterferenceComb.detect(spectrumDb: spectrum, sampleRate: rate)
                if row.name.hasSuffix("scattered") || row.name == "FT8 every 200 Hz" {
                    #expect(found == nil, "\(row.name) at \(snr) dB: \(String(describing: found?.info))")
                }
                for offset in row.offsets.prefix(3) {
                    let id = Self.identified(iq, at: offset, spectrum: spectrum, longer: true)
                    #expect(id.comb == nil, "\(row.name) at \(snr) dB, \(offset) Hz: \(IdentifyTests.describe(id))")
                }
                print("rowsOfStationsAreNeverLabelledComb: \(row.name) at \(snr) dB: \(found.map { "\($0.info)" } ?? "no comb")")
            }
        }
    }
}
