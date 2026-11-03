import Accelerate
import DSPCore
import Foundation
import Modems
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
/// - **FT8** (`ft8`): the latest complete 15 s slot the ring holds within `ft8RingSeconds`, read as a channel around the
///   signal (or its group) and demodulated as USB to a 3 kHz box of 12 kHz audio (`ModemChannel`), and decoded
///   (`FT8Modem.decode`). Only with a true time (the RSP's): the slot is placed by it, and it is the latest complete one
///   the point's own trace was on the air in (`OnAir.covers`): stations keep a parity, so the slot before the one now
///   on is mostly other stations'. Every message in the box is kept (`SlotDecodes`, per slot start and box), so a scan
///   decodes a slot once. A checked message names the trace it lies on, when that trace offers FT8 and was on the air in
///   the slot (`applied`).
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
    /// The most of the ring an FT8 trial reads back from its newest sample.
    static let ft8RingSeconds = 28.0
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
    /// A slot read reaches this far past the slot at either end (the ring moves on between the probe and the read).
    static let slotMarginSeconds = 0.25
    /// A slot read that starts this much after the slot is still decoded, its start silence filled in (a transmission
    /// starts 0.5 s in).
    static let slotLateSeconds = 0.3
    /// The decode cache keeps a slot's messages this long after the slot ended.
    static let slotKeepSeconds = 60.0
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
    static let noSlotNote = "No FT8 decode: no complete slot it was on the air in is in reach of the ring; named from its tones and slots"

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

    /// One FT8 slot's messages in one box: every checked message there, kept for the scan's other points.
    struct SlotDecodes: Sendable, Equatable {
        var state: TuneBarrier.State
        var slotStart: Date
        /// The box's dial (display Hz): its audio is RF less this.
        var dialHz: Double
        var decodes: [TrialDecode]

        /// Whether a signal at `rfHz` was in this box's decoded band.
        func covers(_ rfHz: Double) -> Bool {
            let audio = rfHz - dialHz - 3.5 * FT8Encoder.toneSpacing
            return SignalIDDecoding.ft8AudioBand.contains(audio)
        }
    }

    // MARK: Attempt

    /// What a trial made: its decodes (the FT8 slot's every message, or a stream's readable text), the slot it decoded
    /// to keep (nil when it reused one, or made none), and a note when it couldn't try (no true time, no slot in reach).
    struct Attempt: Sendable, Equatable {
        var decodes: [TrialDecode] = []
        /// The FT8 slot `decodes` are of: a trace is named by them only when it was on the air in it.
        var slotStart: Date?
        var slot: SlotDecodes?
        var note: String?
    }

    /// The trial for `identity` (see the type's notes), made off the ring in the tuning `state` (`barrier` says when that
    /// changes): nil when cancelled or the radio retuned (the answer is dropped). `known`: slots already decoded; one
    /// for the same slot whose box covers the signal is used as it is.
    static func attempt(for identity: SignalIdentity, plan: Plan, state: TuneBarrier.State, trueTime: Bool,
                        known: [SlotDecodes], chunks: SignalIDService.ChunkProvider, barrier: TuneBarrier,
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
                        known: [SlotDecodes] = [], decoders: Decoders = .standard,
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
    /// the box around `targetHz` (or one decoded already that covers `own`). The decode is kept once it is made, though
    /// the job was then cancelled (stopped for the owner: its retry uses it); a retune drops it.
    static func ft8(targetHz: Double, own: SignalIdentity, state: TuneBarrier.State, known: [SlotDecodes],
                    chunks: SignalIDService.ChunkProvider, barrier: TuneBarrier, decoders: Decoders,
                    cancelled: () -> Bool) -> Attempt? {
        // Where the ring ends now.
        guard let probe = chunks(SignalIDService.probeSeconds, SignalIDService.maxChunkFrames, { _ in true }),
              probe.sampleRate > 0 else {
            return barrier.current == state ? Attempt(note: noSlotNote) : nil
        }
        guard !cancelled(), barrier.current == state else { return nil }
        let slotSeconds = FT8Modem.slotSeconds
        let ownHz = state.centerHz + own.measurement.offsetHz
        // The complete slots in reach, newest first: the first `own` was on the air in.
        var slotStart = SlotRecorder.slotStart(for: probe.endTime.addingTimeInterval(-slotSeconds), slotSeconds: slotSeconds)
        while !onAir(own, in: slotStart) {
            slotStart = slotStart.addingTimeInterval(-slotSeconds)
            guard probe.endTime.timeIntervalSince(slotStart) + slotMarginSeconds <= ft8RingSeconds else {
                return Attempt(note: noSlotNote)
            }
        }
        if let hit = known.first(where: { $0.state == state && $0.slotStart == slotStart && $0.covers(ownHz) }) {
            return Attempt(decodes: hit.decodes, slotStart: slotStart)
        }
        let back = probe.endTime.timeIntervalSince(slotStart) + slotMarginSeconds
        guard back <= ft8RingSeconds else { return Attempt(note: noSlotNote) }
        let dial = targetHz - boxCentreHz
        let offset = dial + boxCentreHz - state.centerHz
        switch SignalIDService.channelRead(seconds: back, offsetHz: offset, windowHz: channelHz, tuning: state,
                                           sampleRate: probe.sampleRate, chunks: chunks, barrier: barrier,
                                           feedSeconds: slotSeconds + 2 * slotMarginSeconds) {
        case .dropped: return nil
        case .failed: return Attempt(note: noSlotNote)
        case .read(let read):
            guard !cancelled(), barrier.current == state else { return nil }
            // The read's first sample against the slot's start: what is before it dropped, a late start filled in.
            let readStart = read.endTime.addingTimeInterval(-read.seconds)
            let early = slotStart.timeIntervalSince(readStart)
            // It must start by `slotLateSeconds` into the slot (a ring holding less than the slot starts later); it ends
            // past the slot's end, which the ring held when probed.
            guard early >= -slotLateSeconds else { return Attempt(note: noSlotNote) }
            let drop = min(read.iq.count / 2, max(0, Int((early * read.sampleRate).rounded())))
            var audio = [Float](repeating: 0, count: max(0, Int((-early * audioRate).rounded())))
            audio += demodulate(read.iq, fromFrame: drop, sampleRate: read.sampleRate,
                                dialOffsetHz: dial - (state.centerHz + read.offsetHz))
            let length = Int(slotSeconds * audioRate)
            if audio.count > length { audio.removeLast(audio.count - length) }
            audio += [Float](repeating: 0, count: length - audio.count)
            guard !cancelled(), barrier.current == state else { return nil }
            let decodes = decoders.ft8(audio, slotStart).map {
                TrialDecode(mode: ft8Name, text: clean($0.message), strength: .checked,
                            rfHz: dial + $0.frequencyHz + 3.5 * FT8Encoder.toneSpacing)
            }.filter { !$0.text.isEmpty }
            // Made: kept though cancelled meanwhile (the decode can't be stopped, and a retry would make it again).
            guard barrier.current == state else { return nil }
            let slot = SlotDecodes(state: state, slotStart: slotStart, dialHz: dial, decodes: decodes)
            return Attempt(decodes: decodes, slotStart: slotStart, slot: slot)
        }
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

    /// Interleaved IQ at `sampleRate` (from its frame `fromFrame` on) as 12 kHz USB audio of the 3 kHz box whose dial is
    /// `dialOffsetHz` from its centre: a `ModemChannel` of its own.
    static func demodulate(_ iq: [Float], fromFrame: Int = 0, sampleRate: Double, dialOffsetHz: Double) -> [Float] {
        let channel = ModemChannel(inputRate: sampleRate, dialOffsetHz: dialOffsetHz)
        let frames = max(0, iq.count / 2 - fromFrame)
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
        let eligible = made.slotStart.map { slot in traces.map { offersFT8($0) && onAir($0, in: slot) } }
            ?? traces.map { _ in false }
        var claimed: [Int: TrialDecode] = [:]
        for d in made.decodes where d.strength == .checked && d.mode == ft8Name {
            // The one it lies on, the nearest; and on that one, the nearest message.
            guard let k = traces.indices.filter({ eligible[$0] && lies(d, on: traces[$0], centerHz: centerHz) })
                .min(by: { distance(d, traces[$0], centerHz) < distance(d, traces[$1], centerHz) }) else { continue }
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

    /// Whether `s`'s trace was on the air for the transmission of the FT8 slot starting at `slotStart` (`OnAir.covers`),
    /// and in neither slot beside it as far as its read saw (`OnAir.heard`): stations keep a parity, so a line on in both
    /// is two stations, and a message of one slot isn't said to be its.
    static func onAir(_ s: SignalIdentity, in slotStart: Date) -> Bool {
        guard let air = s.measurement.onAir else { return false }
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
