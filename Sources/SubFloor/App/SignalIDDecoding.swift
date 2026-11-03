import Accelerate
import DSPCore
import Foundation
import Modems
import Recording
import SignalID

/// What a trial decode read: in the mode table's name (`mode`), its text (radio text: untrusted, `SignalIDDecoding.clean`),
/// and how strong a proof it is: `checked`, a message that passed its code's checks (FT8's LDPC and CRC), or `readable`,
/// text that reads as words (`ReadableText`: RTTY, PSK31).
struct TrialDecode: Sendable, Equatable {
    var mode: String
    var text: String
    var strength: Strength
    /// Where the decoded signal is (display Hz): an FT8 message's centre (tone 0 and 3.5 tones), a stream's centre.
    var rfHz: Double
    /// The keying RTTY text read at (what it reads at is its speed and shift).
    var baud: Double? = nil
    var shiftHz: Double? = nil

    enum Strength: Sendable { case checked, readable }
}

/// Signal ID's trial decodes: proof of a name, for the card and for agents (`SignalIDService.identify(tryDecode:)`),
/// never for hover. Each runs privately on the IQ ring's samples, with decoder instances of its own: it never sees the
/// decoder panel, its settings or the decode history, and nothing it reads reaches them.
///
/// - **FT8** (`ft8`): `ft8RingSeconds` of the ring read as a channel around the signal (or its group), and timed
///   (`OnAirMap`): when each trace under the point was on the air, over all of that read. The latest complete 15 s slot
///   in it that the point's own trace was on the air in (`onAir`: stations keep a parity, so most of the slot before
///   the one now on is other stations') is demodulated as USB to a 3 kHz box of 12 kHz audio (`ModemChannel`) and
///   decoded (`FT8Modem.decode`). Only with a true time (the RSP's): the slots are placed by it. The box's read, its
///   timing and every slot decoded in it are kept (`BoxRead`), so a scan decodes a slot once. A checked message names
///   the trace it lies on, when that trace offers FT8 and was on the air in the slot (`applied`).
/// - **RTTY and PSK31** (`stream`): the newest `streamSeconds` around the signal, demodulated the same way, through an
///   RTTY decoder at the measured shift (the standard one it is: 170, 425 or 850 Hz) and each standard speed within
///   `rttyBaudSearch` of the measured one (45.45, 50, 75 Bd: a character's 1.5 stop bits can make its keying read 7/7.5
///   of its speed), or a PSK31 one at 31.25 Bd. Its text counts only when it reads (`ReadableText.score` ≥
///   `readableScore`), the best reading if several did; RTTY's speed and shift are then the decoder's.
/// - **None** for WSPR (its 2 minute slot doesn't fit the ring) or FT4 (no full decoder).
///
/// Everything a decoder prints is cleaned (`clean`): control characters out, `maxTextCharacters` at most. It is data,
/// shown as heard, never interpreted.
enum SignalIDDecoding {
    /// The most of the ring an FT8 trial reads back from its newest sample: one own-parity period (30 s: a station sends
    /// every other slot) and a slot, so a station clicked while it sends is decoded in its previous own slot. The read is a
    /// 4 kHz channel at under 32 kS/s whatever the capture's rate (`Channel.outputRate`): 11.5 MB of IQ at most, read a
    /// piece at a time (`SignalIDService.channelRead`).
    static let ft8RingSeconds = 45.0
    /// A stream's trial reads this much of the newest IQ, at least `minimumStreamSeconds` (a shorter ring is read whole).
    static let streamSeconds = 10.0
    static let minimumStreamSeconds = 3.0
    /// The most of a decode's text kept.
    static let maxTextCharacters = 500
    /// Text reading at least this well (`ReadableText.score`) is evidence for the mode that printed it.
    static let readableScore = ReadableText.readableScore
    /// A checked FT8 message names a trace when it lies inside its extent widened by this much each side (a tone).
    static let ft8MatchHz = FT8Encoder.toneSpacing
    /// A trace wider than this is no FT8's (two tones' width over FT8's 50 Hz): a decode inside it names nothing.
    static let ft8WidestTraceHz = 100.0
    /// The channel read around a box: the box's 3.2 kHz and a margin (the read keeps its middle clean).
    static let channelHz = 4_000.0
    /// The box's audio: `ModemChannel`'s centre (1800 Hz); FT8 tone 0 is decoded from `ft8AudioBand`.
    static let boxCentreHz = 1_800.0
    static let ft8AudioBand = 200.0...3_300.0
    /// A group spanning at most this much is decoded in one box around its middle, else the box is around the signal.
    static let groupBoxHz = 2_800.0
    /// A stream's centre in the box's audio.
    static let streamAudioHz = 1_500.0
    /// IQ is demodulated this many frames at a time.
    static let demodulatePieceFrames = 1 << 14
    /// The audio's rate (the decoders').
    static let audioRate = ModemChannel.outputRate
    /// A slot read that starts this much after the slot is still decoded, its start silence filled in (a transmission
    /// starts 0.5 s in).
    static let slotLateSeconds = 0.3
    /// A box's read (`BoxRead`) is used again for this long after it ended, by the ring's clock: a scan's other points.
    static let boxReuseSeconds = 5.0
    /// The ring read short of `ft8RingSeconds` by more than this held less than it.
    static let ringShortSeconds = 0.5
    /// RTTY's standard speeds and shifts; a speed is tried within `rttyBaudSearch` of the measured one (a character's
    /// stop bits can make it read 7 % low), a shift taken within `rttyShiftTolerance`.
    static let rttyBauds = [45.45, 50, 75]
    static let rttyShiftsHz = [170.0, 425, 850]
    static let rttyBaudSearch = 0.1
    static let rttyShiftTolerance = 0.04
    /// PSK31's speed, and how near a measurement must be.
    static let pskBaud = PSK31Encoder.symbolRate
    static let pskBaudTolerance = 0.03
    /// The mode table's names.
    static let ft8Name = "FT8", rttyName = "RTTY", pskName = "PSK31 / PSK63"

    static let noTrueTimeNote = "No FT8 decode: the IQ has no true time to find its slots by"
    static let noOwnSlotNote = String(format: "No FT8 decode: it was on the air in no complete slot of the last %.0f s; named from its tones and slots",
                                      ft8RingSeconds)
    /// The note when the ring held only `seconds`, and no complete slot the signal was on the air in.
    static func ringShortNote(_ seconds: Double) -> String {
        String(format: "No FT8 decode: the ring holds %.0f s, and no complete slot it was on the air in; named from its tones and slots",
               seconds)
    }

    // MARK: Plans

    /// Which trial applies to an identity.
    enum Plan: Sendable, Equatable {
        /// The FT8 slot decode, in the box whose dial (display Hz) puts `targetHz` in it.
        case ft8(targetHz: Double)
        /// Stream decoders on the signal at `centerHz` (display Hz): each tried, the best reading kept.
        case stream([Stream], centerHz: Double)
    }

    enum Stream: Sendable, Equatable {
        case rtty(baud: Double, shiftHz: Double)
        case psk31

        var mode: String { if case .rtty = self { SignalIDDecoding.rttyName } else { SignalIDDecoding.pskName } }
    }

    /// The trial for `identity` (in the frame of a capture centred on `centerHz`), or nil when none applies: FT8 when it
    /// or a signal under the point is named or offered FT8 (inherited too); otherwise RTTY or PSK31 by the point's own
    /// measurement, at speeds and shifts their decoders follow.
    static func plan(for identity: SignalIdentity, centerHz: Double) -> Plan? {
        if ([identity] + identity.signals).contains(where: offersFT8) {
            let own = centerHz + identity.measurement.offsetHz
            if let span = identity.groupSpanHz, span.upperBound - span.lowerBound <= groupBoxHz {
                let base = identity.captureCenterHz ?? centerHz
                return .ft8(targetHz: base + (span.lowerBound + span.upperBound) / 2)
            }
            return .ft8(targetHz: own)
        }
        let m = identity.measurement
        guard m.occupiedBandwidthHz > 0, let rate = m.symbolRate else { return nil }
        let centre = centerHz + m.offsetHz
        if m.family == .fsk, m.toneCount == nil || m.toneCount == 2, let shift = m.fskShiftHz,
           let standard = nearest(shift, in: rttyShiftsHz, within: rttyShiftTolerance) {
            let bauds = rttyBauds.filter { abs(rate - $0) <= rttyBaudSearch * $0 }
                .sorted { abs(rate - $0) < abs(rate - $1) }
            guard !bauds.isEmpty else { return nil }
            return .stream(bauds.map { .rtty(baud: $0, shiftHz: standard) }, centerHz: centre)
        }
        if m.family == .psk, m.pskOrder == nil || m.pskOrder == 2 || m.pskOrder == 4,
           nearest(rate, in: [pskBaud], within: pskBaudTolerance) != nil {
            return .stream([.psk31], centerHz: centre)
        }
        return nil
    }

    static func offersFT8(_ identity: SignalIdentity) -> Bool {
        identity.best?.name == ft8Name || identity.alternatives.contains { $0.name == ft8Name }
    }

    /// The value of `values` within `tolerance` (relative) of `x`, the nearest.
    static func nearest(_ x: Double, in values: [Double], within tolerance: Double) -> Double? {
        values.filter { abs(x - $0) <= tolerance * $0 }.min { abs(x - $0) < abs(x - $1) }
    }

    // MARK: Decoders

    /// The decoders a trial runs (test hook: `SignalIDService.decoders`): fresh instances each time.
    struct Decoders: Sendable {
        /// One FT8 slot of 12 kHz audio, `audio[0]` at `slotStart`.
        var ft8: @Sendable (_ audio: [Float], _ slotStart: Date) -> [SlotDecode]
        /// A stream decoder's text for 12 kHz audio with the signal at `streamAudioHz`.
        var stream: @Sendable (_ stream: Stream, _ audio: [Float]) -> String

        static let standard = Decoders(
            ft8: { FT8Modem.decode(samples: $0, sampleRate: audioRate, slotStart: $1, audioBand: ft8AudioBand) },
            stream: { stream, audio in
                let decoder: any SignalDecoder = switch stream {
                case .rtty(let baud, let shift):
                    RTTYSignalDecoder(frequencyHz: streamAudioHz, sampleRate: audioRate, baud: baud, shiftHz: shift)
                case .psk31: PSK31Modem.makeDecoder(frequencyHz: streamAudioHz, sampleRate: audioRate)
                }
                // A second of silence after lets it finish the last characters it holds back.
                let tail = [Float](repeating: 0, count: Int(audioRate))
                return audio.withUnsafeBufferPointer { decoder.process($0) } + tail.withUnsafeBufferPointer { decoder.process($0) }
            })
    }

    // MARK: The FT8 slot cache

    /// One box's read: when everything in it was on the air (`map`, over the channel the trial read), and the messages
    /// of every slot decoded in it, kept for the scan's other points.
    struct BoxRead: Sendable, Equatable {
        var state: TuneBarrier.State
        /// The box's dial (display Hz): its audio is RF less this.
        var dialHz: Double
        var map: OnAirMap
        var slots: [Date: [TrialDecode]] = [:]

        /// Whether a signal at `rfHz` was in this box's decoded band.
        func covers(_ rfHz: Double) -> Bool {
            let audio = rfHz - dialHz - 3.5 * FT8Encoder.toneSpacing
            return SignalIDDecoding.ft8AudioBand.contains(audio)
        }
    }

    // MARK: Attempt

    /// What a trial made: its decodes (the FT8 slot's every message, or a stream's readable text), the box's read to keep
    /// (nil when it made none), and a note when it couldn't try (no true time, no slot of its own in reach).
    struct Attempt: Sendable, Equatable {
        var decodes: [TrialDecode] = []
        /// The FT8 slot `decodes` are of: a trace is named by them only when it was on the air in it.
        var slotStart: Date?
        /// When the traces in the box were on the air: what says which were on in `slotStart`.
        var map: OnAirMap?
        var box: BoxRead?
        var note: String?
    }

    /// The trial for `identity` (see the type's notes), made off the ring in the tuning `state` (`barrier` says when that
    /// changes): nil when cancelled or the radio retuned (the answer is dropped). `known`: boxes already read; a recent
    /// one in this tuning that covers the signal is used (`boxReuseSeconds`), and its slots decoded.
    static func attempt(for identity: SignalIdentity, plan: Plan, state: TuneBarrier.State, trueTime: Bool,
                        known: [BoxRead], chunks: SignalIDService.ChunkProvider, barrier: TuneBarrier,
                        decoders: Decoders = .standard, cancelled: () -> Bool) -> Attempt? {
        guard !cancelled(), barrier.current == state else { return nil }
        switch plan {
        case .ft8(let targetHz):
            guard trueTime else { return Attempt(note: noTrueTimeNote) }
            return ft8(targetHz: targetHz, own: identity, state: state, known: known, chunks: chunks, barrier: barrier,
                       decoders: decoders, cancelled: cancelled)
        case .stream(let streams, let centre):
            return stream(streams, centerHz: centre, state: state, chunks: chunks, barrier: barrier,
                          decoders: decoders, cancelled: cancelled)
        }
    }

    /// The trial decode of the signal at `atHz` (display Hz) that `identity` describes, in a capture centred on
    /// `centerHz` now: nil when no decoder applies, or it found nothing there. Never sees the decoder panel or decode
    /// history. (`attempt(for:plan:…)` is the service's, with its slot cache and tuning.)
    static func attempt(for identity: SignalIdentity, atHz: Double, centerHz: Double,
                        chunks: SignalIDService.ChunkProvider, trueTime: Bool = true,
                        known: [BoxRead] = [], decoders: Decoders = .standard,
                        cancelled: () -> Bool) -> TrialDecode? {
        let barrier = TuneBarrier()
        barrier.end(centerHz: centerHz)
        guard let plan = plan(for: identity, centerHz: centerHz),
              let made = attempt(for: identity, plan: plan, state: barrier.current, trueTime: trueTime,
                                 known: known.map { var k = $0; k.state = barrier.current; return k },
                                 chunks: chunks, barrier: barrier, decoders: decoders, cancelled: cancelled)
        else { return nil }
        let named = applied(made, to: identity, centerHz: centerHz)
        let texts = Set(([named] + named.signals).compactMap(\.decodedText))
        return made.decodes.filter { texts.contains($0.text) }.min { abs($0.rfHz - atHz) < abs($1.rfHz - atHz) }
    }

    /// The latest complete FT8 slot within `ft8RingSeconds` that `own` (the point's signal) was on the air in, decoded in
    /// the box around `targetHz`: the box read, timed (`OnAirMap`), its slot chosen (`ownSlot`) and decoded; or, from a
    /// recent read of it (`known`), the slot chosen by that read's timing and its decodes taken. The decode is kept once it is made, though the job
    /// was then cancelled (stopped for the owner: its retry uses it); a retune drops it.
    static func ft8(targetHz: Double, own: SignalIdentity, state: TuneBarrier.State, known: [BoxRead],
                    chunks: SignalIDService.ChunkProvider, barrier: TuneBarrier, decoders: Decoders,
                    cancelled: () -> Bool) -> Attempt? {
        // Where the ring ends now.
        guard let probe = chunks(SignalIDService.probeSeconds, SignalIDService.maxChunkFrames, { _ in true }),
              probe.sampleRate > 0 else {
            return barrier.current == state ? Attempt(note: noOwnSlotNote) : nil
        }
        guard !cancelled(), barrier.current == state else { return nil }
        let ownHz = state.centerHz + own.measurement.offsetHz
        let end = probe.endTime.timeIntervalSince1970
        // A recent read of a box holding the signal, and the slot it was on in there, decoded already.
        if let box = known.first(where: {
            $0.state == state && $0.covers(ownHz) && end - $0.map.readEndUTC <= boxReuseSeconds
        }) {
            switch ownSlot(own, map: box.map, centerHz: state.centerHz) {
            case .none(let note): return Attempt(map: box.map, note: note)
            case .slot(let slot):
                if let decodes = box.slots[slot] { return Attempt(decodes: decodes, slotStart: slot, map: box.map) }
                // Not decoded in it yet (its first point wasn't on then): read afresh.
            }
        }
        let dial = targetHz - boxCentreHz
        switch SignalIDService.channelRead(seconds: ft8RingSeconds, offsetHz: dial + boxCentreHz - state.centerHz,
                                           windowHz: channelHz, tuning: state, sampleRate: probe.sampleRate,
                                           chunks: chunks, barrier: barrier) {
        case .dropped: return nil
        case .failed: return Attempt(note: noOwnSlotNote)
        case .read(let read):
            guard !cancelled(), barrier.current == state else { return nil }
            let map = OnAirMap(iq: read.iq, sampleRate: read.sampleRate, centerOffsetHz: read.offsetHz,
                               halfSpanHz: channelHz / 2, readEnd: read.endTime)
            var box = BoxRead(state: state, dialHz: dial, map: map)
            guard !cancelled(), barrier.current == state else { return nil }
            let slot: Date
            switch ownSlot(own, map: map, centerHz: state.centerHz) {
            case .none(let note): return Attempt(map: map, box: box, note: note)
            case .slot(let s): slot = s
            }
            // The slot's 15 s of the read, from its start.
            let readStart = read.endTime.addingTimeInterval(-read.seconds)
            let early = slot.timeIntervalSince(readStart)
            let drop = min(read.iq.count / 2, max(0, Int((early * read.sampleRate).rounded())))
            var audio = [Float](repeating: 0, count: max(0, Int((-early * audioRate).rounded())))
            audio += demodulate(read.iq, fromFrame: drop, frames: Int(FT8Modem.slotSeconds * read.sampleRate),
                                sampleRate: read.sampleRate, dialOffsetHz: dial - (state.centerHz + read.offsetHz))
            guard !cancelled(), barrier.current == state else { return nil }
            let decodes = ft8Decodes(audio, slot: slot, dialHz: dial, decoders: decoders)
            // Made: kept though cancelled meanwhile (the decode can't be stopped, and a retry would make it again).
            guard barrier.current == state else { return nil }
            box.slots[slot] = decodes
            return Attempt(decodes: decodes, slotStart: slot, map: map, box: box)
        }
    }

    /// Which slot `own` is decoded in, by `map`: the latest complete one in it that `own` was on the air in (`onAir`).
    enum OwnSlot { case slot(Date), none(String) }

    static func ownSlot(_ own: SignalIdentity, map: OnAirMap, centerHz: Double) -> OwnSlot {
        let air = band(own).flatMap { map.onAir($0) }
        let slotSeconds = FT8Modem.slotSeconds
        var slot = SlotRecorder.slotStart(for: Date(timeIntervalSince1970: map.readEndUTC - slotSeconds),
                                          slotSeconds: slotSeconds)
        // Complete slots wholly in the read (or starting `slotLateSeconds` before it), newest first.
        while slot.timeIntervalSince1970 >= map.readStartUTC - slotLateSeconds {
            if let air, onAir(air, in: slot) { return .slot(slot) }
            slot = slot.addingTimeInterval(-slotSeconds)
        }
        let held = map.readEndUTC - map.readStartUTC
        return .none(held < ft8RingSeconds - ringShortSeconds ? ringShortNote(held) : noOwnSlotNote)
    }

    /// One slot's 12 kHz audio (cut or filled to 15 s) through the FT8 decoder, its messages cleaned.
    static func ft8Decodes(_ audio: [Float], slot: Date, dialHz: Double, decoders: Decoders) -> [TrialDecode] {
        var audio = audio
        let length = Int(FT8Modem.slotSeconds * audioRate)
        if audio.count > length { audio.removeLast(audio.count - length) }
        audio += [Float](repeating: 0, count: length - audio.count)
        return decoders.ft8(audio, slot).map {
            TrialDecode(mode: ft8Name, text: clean($0.message), strength: .checked,
                        rfHz: dialHz + $0.frequencyHz + 3.5 * FT8Encoder.toneSpacing)
        }.filter { !$0.text.isEmpty }
    }

    /// The newest `streamSeconds` of the signal at `centerHz` through each of `streams`' decoders: the text that reads
    /// best, when one reads.
    static func stream(_ streams: [Stream], centerHz: Double, state: TuneBarrier.State, chunks: SignalIDService.ChunkProvider,
                       barrier: TuneBarrier, decoders: Decoders, cancelled: () -> Bool) -> Attempt? {
        guard let probe = chunks(SignalIDService.probeSeconds, SignalIDService.maxChunkFrames, { _ in true }),
              probe.sampleRate > 0 else {
            return barrier.current == state ? Attempt() : nil
        }
        guard !cancelled(), barrier.current == state else { return nil }
        let dial = centerHz - streamAudioHz
        switch SignalIDService.channelRead(seconds: streamSeconds, offsetHz: centerHz - state.centerHz,
                                           windowHz: channelHz, tuning: state, sampleRate: probe.sampleRate,
                                           chunks: chunks, barrier: barrier) {
        case .dropped: return nil
        case .failed: return Attempt()
        case .read(let read):
            guard !cancelled(), barrier.current == state else { return nil }
            guard read.seconds >= minimumStreamSeconds else { return Attempt() }
            let audio = demodulate(read.iq, sampleRate: read.sampleRate,
                                   dialOffsetHz: dial - (state.centerHz + read.offsetHz))
            guard !cancelled(), barrier.current == state else { return nil }
            var best: (stream: Stream, text: String, score: Float)?
            for stream in streams {
                let text = clean(decoders.stream(stream, audio))
                guard !cancelled(), barrier.current == state else { return nil }
                let score = ReadableText.score(text)
                if score >= readableScore, score > best?.score ?? 0 { best = (stream, text, score) }
            }
            guard let best else { return Attempt() }
            var decode = TrialDecode(mode: best.stream.mode, text: best.text, strength: .readable, rfHz: centerHz)
            if case .rtty(let baud, let shift) = best.stream { (decode.baud, decode.shiftHz) = (baud, shift) }
            return Attempt(decodes: [decode])
        }
    }

    /// Interleaved IQ at `sampleRate` (from its frame `fromFrame` on, `frames` of it at most) as 12 kHz USB audio of the 3 kHz box whose dial is
    /// `dialOffsetHz` from its centre: a `ModemChannel` of its own.
    static func demodulate(_ iq: [Float], fromFrame: Int = 0, frames most: Int = .max, sampleRate: Double,
                           dialOffsetHz: Double) -> [Float] {
        let channel = ModemChannel(inputRate: sampleRate, dialOffsetHz: dialOffsetHz)
        let frames = max(0, min(most, iq.count / 2 - fromFrame))
        var audio: [Float] = []
        audio.reserveCapacity(Int(Double(frames) / sampleRate * audioRate) + 64)
        iq.withUnsafeBufferPointer { raw in
            guard let base = raw.baseAddress, frames > 0 else { return }
            base.withMemoryRebound(to: DSPComplex.self, capacity: raw.count / 2) { z in
                // A piece at a time: the channel's work buffers stay a piece long.
                var at = fromFrame
                while at < fromFrame + frames {
                    let n = min(demodulatePieceFrames, fromFrame + frames - at)
                    channel.process(UnsafeBufferPointer(start: z + at, count: n), audio: &audio)
                    at += n
                }
            }
        }
        return audio
    }

    // MARK: Text

    /// `text` as kept (`ReadableText.cleaned`): control and format characters out (line breaks and tabs become spaces),
    /// runs of spaces as one, at most `maxTextCharacters` scalars. It stays radio text: shown, never interpreted.
    static func clean(_ text: String) -> String { ReadableText.cleaned(text, maxScalars: maxTextCharacters) }

    // MARK: Applying

    /// `identity` (in the frame of a capture centred on `centerHz`) with what the trial made:
    /// - a checked FT8 message names FT8 at 1.0 (`confirmedByDecode`, its text in `decodedText`) the signal it lies on —
    ///   the point's own, or one under the point: inside its extent widened by `ft8MatchHz` each side, and no wider than
    ///   `ft8WidestTraceHz`, the nearest where two would — when that signal offers FT8 (named, offered or inherited) and
    ///   its trace was on the air in the message's slot (`onAir`). A message on no such signal names nothing; a signal
    ///   that wasn't on then, or offers no FT8, keeps its own answer. A name inherited is then the signal's own;
    /// - readable text names the point's own signal when the mode table does, given it (`readableDecode`), and its text
    ///   is kept: it satisfies what a row asks a decode for (RTTY outside the amateur segments). Text that doesn't name
    ///   its mode is kept as heard and changes nothing else;
    /// - the trial's note, if any, is added.
    static func applied(_ made: Attempt, to identity: SignalIdentity, centerHz: Double) -> SignalIdentity {
        var out = identity
        if let note = made.note { out.note = [out.note, note].compactMap { $0 }.joined(separator: "; ") }
        // The signals a message may lie on: those under the point (the point's own among them), else the point's own; only
        // one that offers FT8 and was on the air in the message's slot.
        let traces = out.signals.isEmpty ? [out] : out.signals
        let eligible = traces.map { trace -> Bool in
            guard let slot = made.slotStart, let map = made.map, offersFT8(trace),
                  let air = band(trace).flatMap({ map.onAir($0) }) else { return false }
            return onAir(air, in: slot)
        }
        var claimed: [Int: TrialDecode] = [:]
        for d in made.decodes where d.strength == .checked && d.mode == ft8Name {
            // The nearest it lies on is its trace (when that one may be named; never the next one over); and on that
            // one, the nearest message.
            guard let k = traces.indices.filter({ lies(d, on: traces[$0], centerHz: centerHz) })
                .min(by: { distance(d, traces[$0], centerHz) < distance(d, traces[$1], centerHz) }),
                  eligible[k] else { continue }
            if let other = claimed[k], distance(other, traces[k], centerHz) <= distance(d, traces[k], centerHz) { continue }
            claimed[k] = d
        }
        for (k, d) in claimed {
            if out.signals.isEmpty {
                out = named(out, by: d)
                continue
            }
            out.signals[k] = named(out.signals[k], by: d)
            if out.signals[k].measurement.offsetHz == identity.measurement.offsetHz { out = named(out, by: d) }
        }
        if let text = made.decodes.first(where: { $0.strength == .readable }) {
            out = readable(out, text: text, centerHz: centerHz)
            if let k = out.signals.firstIndex(where: { $0.measurement.offsetHz == identity.measurement.offsetHz }) {
                out.signals[k] = readable(out.signals[k], text: text, centerHz: centerHz)
            }
        }
        return out
    }

    /// The band a trace's timing is read over: its extent (relative to the capture centre).
    static func band(_ s: SignalIdentity) -> ClosedRange<Double>? {
        let m = s.measurement
        let half = max(m.occupiedBandwidthHz, m.bandwidth6dBHz) / 2
        return half > 0 ? (m.offsetHz - half)...(m.offsetHz + half) : nil
    }

    /// Whether a trace on the air at `air` was on for the transmission of the FT8 slot starting at `slotStart`
    /// (`OnAir.covers`), and in neither slot beside it as far as the read saw (`OnAir.heard`): stations keep a parity,
    /// so a line on in both is two stations, and a message of one slot isn't said to be its.
    static func onAir(_ air: OnAir, in slotStart: Date) -> Bool {
        func transmission(_ slot: Date) -> ClosedRange<Double> {
            let start = slot.timeIntervalSince1970 + FT8Encoder.startSeconds
            return start...(start + Double(FT8Encoder.toneCount) * FT8Encoder.symbolSeconds)
        }
        let slot = FT8Modem.slotSeconds
        return air.covers(transmission(slotStart))
            && ![-slot, slot].contains { air.heard(during: transmission(slotStart.addingTimeInterval($0))) }
    }

    /// Whether the FT8 message `d` lies on `s`'s extent (see `applied`).
    static func lies(_ d: TrialDecode, on s: SignalIdentity, centerHz: Double) -> Bool {
        let m = s.measurement
        let width = max(m.occupiedBandwidthHz, m.bandwidth6dBHz)
        guard width > 0, width <= ft8WidestTraceHz, s.comb == nil else { return false }
        return distance(d, s, centerHz) <= width / 2 + ft8MatchHz
    }

    static func distance(_ d: TrialDecode, _ s: SignalIdentity, _ centerHz: Double) -> Double {
        abs(d.rfHz - (centerHz + s.measurement.offsetHz))
    }

    /// `s` named FT8 by the checked message `d`.
    static func named(_ s: SignalIdentity, by d: TrialDecode) -> SignalIdentity {
        var out = s
        var best = s.best?.name == ft8Name ? s.best! : ModeMatch(name: ft8Name, confidence: 1, evidence: [])
        best.confidence = 1
        best.evidence.append("decoded: a checked FT8 message, by a trial decode of its slot")
        out.best = best
        out.alternatives.removeAll { $0.name == ft8Name }
        out.nameInherited = false
        out.confirmedByDecode = true
        out.needsLongerRead = false
        out.decodedText = d.text
        return out
    }

    /// `s` given the readable text `d`: re-named with it by the mode table (RTTY's speed and shift the decoder's, which
    /// the text read at), the name taken only when it is `d`'s mode.
    static func readable(_ s: SignalIdentity, text d: TrialDecode, centerHz: Double) -> SignalIdentity {
        var out = s
        out.decodedText = d.text
        var m = s.measurement
        if let baud = d.baud, let shift = d.shiftHz {
            if let measured = m.symbolRate, abs(measured - baud) > 0.005 * baud {
                m.notes.append(String(format: "%g Bd as decoded (its keying measured %.2f Bd)", baud,
                                      measured))
            }
            m.symbolRate = baud
            m.fskShiftHz = shift
            m.toneSpacingHz = shift
        }
        let again = SignalIdentifier.identify(m, rfHz: centerHz + m.offsetHz, readableDecode: true)
        guard var best = again.best, best.name == d.mode else { return out }
        best.evidence.append("decoded: readable \(d.mode == rttyName ? "RTTY" : "PSK31") text, by a trial decode")
        out.measurement = again.measurement
        out.best = best
        out.alternatives = again.alternatives
        return out
    }
}
