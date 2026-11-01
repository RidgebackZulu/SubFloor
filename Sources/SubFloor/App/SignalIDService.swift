import CoreGraphics
import Foundation
import Modems
import Recording
import SignalID
import SubFloorCore
import Synchronization

/// The capture's tuning as the IQ ring sees it, for reads off the main actor: a sequence lock. `AppModel` calls
/// `begin` before the radio retunes (or the engine starts) and its IQ history clears, and `end` after, with the
/// display centre the IQ now has; the sequence is odd in between. A read whose sequence is odd, or changed while it
/// copied the ring, may hold IQ from either side of the barrier.
final class TuneBarrier: Sendable {
    struct State: Sendable, Equatable {
        var sequence = 0
        /// The capture centre the ring's IQ was heard at, in display Hz.
        var centerHz = 0.0
    }

    private let state = Mutex(State())

    var current: State { state.withLock { $0 } }

    func begin() {
        state.withLock { if $0.sequence % 2 == 0 { $0.sequence += 1 } }
    }

    /// `centerHz` nil: the retune failed and the IQ is still the old centre's.
    func end(centerHz: Double?) {
        state.withLock {
            $0.sequence += $0.sequence % 2 == 0 ? 2 : 1
            if let centerHz { $0.centerHz = centerHz }
        }
    }
}

/// Signal ID in the app: names the signal at a display frequency from the newest IQ in the recorder's pre-roll ring
/// (`StreamRecorder.snapshot`), with `SignalIdentifier.identify`.
///
/// **Off the main actor.** The snapshots and the analysis run in a detached task, given only Sendable values;
/// awaiting `identify` from a task that is then cancelled cancels it: the identifier stops between its stages, the
/// longer read between pieces, and the answer is dropped. The main actor reads the model (running, the spectrum,
/// the decode log) and the cache only.
///
/// **The IQ and its centre.** Everything is in display Hz: the mode table's band hints are, and with HamItUp on the
/// radio is tuned `Upconverter.loHz` above. `AppModel` brackets every clear of the IQ history (a hardware retune, an
/// engine start) with the `tuning` barrier, which carries the display centre the ring's IQ is at; a read is
/// retried while the barrier is moving, and the whole identification is dropped (nil) when the radio retuned
/// before it finished. A read that reaches back to the barrier (shorter than asked for) loses its oldest
/// `settleSeconds`: the pipeline carries old-centre samples past it. Under a second left gives the identifier's
/// "Too soon after tuning — try again".
///
/// **The longer read** (ruling R26). The first pass is 3 s at the radio's rate. When it asks for more
/// (`needsLongerRead`), up to `longSeconds` are read off the ring a piece at a time (`chunkProvider`, at most
/// `chunkSeconds` or `maxChunkFrames` each) and each piece cut down as it comes (`ChannelExtractor`) to a channel
/// around the signal, `minimumChannelHz` or `channelWidths` × its width if wider: the read is never held at the
/// radio's rate (16 s at 2 MS/s would be 256 MB; the channel's is 32 MB, `longReadBudgetBytes` at most, a wider
/// channel's read shortened to fit). The identifier then runs again on the channel, at its own rate and centre,
/// with the channel as its longer read; its measurement is put back in the capture's frame. A ring holding less
/// gives what it holds (its oldest `settleSeconds` dropped when it reaches back to a retune), which the identifier
/// says in `note`.
///
/// **Cache.** An answer with an extent (and no longer read still wanted) is kept `cacheSeconds`, over the extent it
/// found (and the point asked about): a point on the same signal reuses it. A retune empties it.
///
/// **Decode confirmation.** A running decoder's row within ±half the signal's width (at least `minimumMatchHz`) —
/// a live row with text, or a slot row whose slot ended in the last `decodeSeconds` — whose mode is the one named,
/// or names one when none was, confirms it: `confirmedByDecode`, at 1.0. Applied to every answer, cached or new.
///
/// **Hover.** `AppModel.hover(at:viewSize:)` feeds the pointer: resting `dwellSeconds` starts `identify` there
/// (`hoverPending` while it runs, then `hoverIdentity`); moving more than `moveTolerance` points from where it
/// came to rest, leaving, or a retune cancels it and clears the answer.
@MainActor @Observable
final class SignalIDService {
    /// Up to `lastSeconds` of the ring's newest IQ (`StreamRecorder.snapshot`), any thread.
    typealias SnapshotProvider = @Sendable (_ lastSeconds: Double) -> IQSnapshot?
    /// The same span handed over a piece of at most `chunkFrames` at a time
    /// (`StreamRecorder.snapshot(lastSeconds:chunkFrames:_:)`), any thread.
    typealias ChunkProvider = @Sendable (_ lastSeconds: Double, _ chunkFrames: Int,
                                         _ visit: (UnsafeBufferPointer<Float>) -> Bool) -> IQRead?
    /// `SignalIdentifier.identify(iq:sampleRate:captureCenterHz:atHz:bandwidthHz:spectrumDb:longer:)`.
    typealias Analysis = @Sendable (_ iq: [Float], _ sampleRate: Double, _ captureCenterHz: Double, _ atHz: Double,
                                    _ bandwidthHz: Double?, _ spectrumDb: [Float]?,
                                    _ longer: (() -> (iq: [Float], seconds: Double)?)?) -> SignalIdentity

    nonisolated static let firstSeconds = 3.0
    nonisolated static let longSeconds = 16.0
    /// Pipeline latency: IQ this long after a retune's barrier may still be the old centre's.
    nonisolated static let settleSeconds = 0.05
    nonisolated static let chunkSeconds = 0.5
    nonisolated static let maxChunkFrames = 1 << 20
    /// The longer read's channel: at least this wide, or this many times the signal's width.
    nonisolated static let minimumChannelHz = 48_000.0
    nonisolated static let channelWidths = 4.0
    /// The longer read's channelised IQ at most (interleaved floats).
    nonisolated static let longReadBudgetBytes = 32 << 20
    static let cacheSeconds = 5.0
    /// A slot decode confirms for this long after its slot ended.
    static let decodeSeconds = 60.0
    /// The narrowest half-width a decode is matched over (a width-less answer, a narrow CW measurement).
    static let minimumMatchHz = 25.0
    static let dwellSeconds = 0.5
    /// Pointer movement, in view points, that leaves the point it rested on.
    static let moveTolerance = 3.0

    /// The answer for where the pointer rests (nil while none, or while it is pending).
    private(set) var hoverIdentity: SignalIdentity?
    /// An identification for the pointer's resting place is running.
    private(set) var hoverPending = false

    /// Test hook: where the IQ comes from (`AppModel` points it at its IQ recorder).
    @ObservationIgnored var snapshotProvider: SnapshotProvider = { _ in nil }
    /// Test hook: where the longer read comes from.
    @ObservationIgnored var chunkProvider: ChunkProvider = { _, _, _ in nil }
    /// Test hook: the analysis (the identifier).
    @ObservationIgnored var analysis: Analysis = { iq, rate, centre, at, width, spectrum, longer in
        SignalIdentifier.identify(iq: iq, sampleRate: rate, captureCenterHz: centre, atHz: at, bandwidthHz: width,
                                  spectrumDb: spectrum, longer: longer)
    }
    @ObservationIgnored let tuning = TuneBarrier()
    @ObservationIgnored private weak var model: AppModel?

    private struct CacheEntry {
        var range: ClosedRange<Double>
        var bandwidthHz: Double?
        var sequence: Int
        var centerHz: Double
        var at: Date
        var identity: SignalIdentity
    }

    @ObservationIgnored private var cache: [CacheEntry] = []
    @ObservationIgnored private var hoverAnchor: CGPoint?
    @ObservationIgnored private var hoverTask: Task<Void, Never>?

    /// Reads `model`'s radio, spectrum and decodes, and its IQ recorder's ring.
    func attach(to model: AppModel, recorder: StreamRecorder) {
        self.model = model
        snapshotProvider = { [recorder] in recorder.snapshot(lastSeconds: $0) }
        chunkProvider = { [recorder] in recorder.snapshot(lastSeconds: $0, chunkFrames: $1, $2) }
    }

    // MARK: Identify

    /// The signal at `atHz` (display Hz), or over `bandwidthHz` around it when given (an agent's); nil when there is
    /// no data (the radio stopped, an empty ring), when the radio retuned before it finished, or when cancelled.
    func identify(atHz: Double, bandwidthHz: Double? = nil) async -> SignalIdentity? {
        guard let model, model.isRunning else { return nil }
        let now = Date()
        let sequence = tuning.current.sequence
        cache.removeAll { $0.sequence != sequence || now.timeIntervalSince($0.at) > Self.cacheSeconds }
        if let hit = cache.first(where: { $0.range.contains(atHz) && $0.bandwidthHz == bandwidthHz }) {
            return confirmed(hit.identity, centerHz: hit.centerHz, atHz: atHz, bandwidthHz: bandwidthHz, now: now)
        }

        let spectrum = model.spectrumSnapshot()
        let provider = snapshotProvider, chunks = chunkProvider, analysis = self.analysis, barrier = tuning
        let task = Task.detached(priority: .userInitiated) {
            Self.run(atHz: atHz, bandwidthHz: bandwidthHz, spectrum: spectrum, provider: provider, chunks: chunks,
                     analysis: analysis, barrier: barrier)
        }
        let result = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        guard !Task.isCancelled, let (identity, state) = result, state == tuning.current else { return nil }

        // Kept when it found an extent, and had the read it asked for (a short ring's answer improves as it fills).
        let m = identity.measurement
        if m.occupiedBandwidthHz > 0 && !identity.needsLongerRead {
            let centre = state.centerHz + m.offsetHz, half = max(m.occupiedBandwidthHz, m.bandwidth6dBHz) / 2
            cache.append(CacheEntry(range: min(centre - half, atHz)...max(centre + half, atHz),
                                    bandwidthHz: bandwidthHz, sequence: state.sequence, centerHz: state.centerHz,
                                    at: Date(), identity: identity))
        }
        return confirmed(identity, centerHz: state.centerHz, atHz: atHz, bandwidthHz: bandwidthHz, now: Date())
    }

    /// Forgets every answer.
    func invalidateCache() { cache.removeAll() }

    /// The first read, the analysis and (on request) the longer read: off the main actor. Nil when there is no IQ,
    /// the radio retuned meanwhile, or the task was cancelled.
    private nonisolated static func run(atHz: Double, bandwidthHz: Double?, spectrum: SpectrumSnapshot?,
                                        provider: SnapshotProvider, chunks: ChunkProvider, analysis: Analysis,
                                        barrier: TuneBarrier) -> (SignalIdentity, TuneBarrier.State)? {
        guard case (var first, let state)? = read(firstSeconds, provider: provider, barrier: barrier) else {
            return nil
        }
        // The app's spectrum, when it is of this capture (the identifier works out its own otherwise).
        let spectrumDb = spectrum.flatMap { s in
            abs(s.centerHz - state.centerHz) < 0.5 && abs(s.spanHz - first.sampleRate) < 0.5 && s.average.count >= 8
                ? s.average : nil
        }
        let identity = analysis(first.samples, first.sampleRate, state.centerHz, atHz, bandwidthHz, spectrumDb, nil)
        guard !Task.isCancelled else { return nil }
        guard identity.needsLongerRead else { return (identity, state) }

        // The longer read, on the channel around what the first pass measured.
        let rate = first.sampleRate
        first.samples = []   // not held through the longer read
        let m = identity.measurement
        guard let long = longerRead(offsetHz: m.offsetHz, widthHz: max(m.occupiedBandwidthHz, bandwidthHz ?? 0),
                                    tuning: state, sampleRate: rate, chunks: chunks, barrier: barrier) else {
            return Task.isCancelled ? nil : (identity, state)
        }
        var refined = analysis(long.iq, long.sampleRate, state.centerHz + long.offsetHz, atHz, bandwidthHz, nil,
                               { (long.iq, long.seconds) })
        guard !Task.isCancelled else { return nil }
        refined.measurement.offsetHz += long.offsetHz   // back in the capture's frame
        return (refined, state)
    }

    /// The longer read's channel: interleaved IQ at `sampleRate`, centred `offsetHz` from the capture centre.
    struct LongRead: Sendable {
        var iq: [Float]
        var sampleRate: Double
        var offsetHz: Double
        var seconds: Double
    }

    /// Up to `longSeconds` (fewer for a channel too wide for `longReadBudgetBytes`) of the ring, read a piece at a
    /// time and cut to the channel around `offsetHz` (`widthHz` wide, the signal's) as it comes, in the tuning
    /// `tuning`. A read that reaches back to the barrier loses its oldest `settleSeconds`. Nil when there is no
    /// IQ, the radio retuned, or the task was cancelled.
    nonisolated static func longerRead(offsetHz: Double, widthHz: Double, tuning: TuneBarrier.State,
                                       sampleRate: Double, chunks: ChunkProvider,
                                       barrier: TuneBarrier) -> LongRead? {
        guard barrier.current == tuning, sampleRate > 0 else { return nil }
        let windowHz = max(minimumChannelHz, channelWidths * widthHz)
        let extractor = ChannelExtractor(sampleRate: sampleRate, offsetHz: offsetHz, bandwidthHz: windowHz,
                                         sharp: false)
        // A capture no wider than the channel needs no cutting.
        let whole = extractor.rate >= sampleRate
        let rate = whole ? sampleRate : extractor.rate
        let seconds = min(longSeconds, Double(longReadBudgetBytes / 8) / rate)
        let asked = seconds + settleSeconds
        var copied: [Float] = []
        let read = chunks(asked, min(Int(chunkSeconds * sampleRate), maxChunkFrames)) { piece in
            guard !Task.isCancelled else { return false }
            if whole { copied.append(contentsOf: piece) } else { extractor.feed(piece) }
            return true
        }
        guard let read, read.sampleRate == sampleRate, barrier.current == tuning else { return nil }
        var iq = whole ? copied : extractor.finish().samples
        // The oldest `settleSeconds` of a read reaching back to the barrier, and anything over `seconds`.
        let settle = read.frames < Int((asked * sampleRate).rounded()) ? Int((settleSeconds * rate).rounded()) : 0
        let keep = max(0, min(iq.count / 2 - settle, Int((seconds * rate).rounded())))
        iq.removeFirst(iq.count - 2 * keep)
        return LongRead(iq: iq, sampleRate: rate, offsetHz: whole ? 0 : offsetHz, seconds: Double(keep) / rate)
    }

    /// Up to `seconds` of the ring's IQ and the tuning it was heard at. A read shorter than asked for reaches back
    /// to the last barrier, and loses its oldest `settleSeconds`. Retried while the barrier moves; nil when there is
    /// no IQ.
    private nonisolated static func read(_ seconds: Double, provider: SnapshotProvider,
                                         barrier: TuneBarrier) -> (IQSnapshot, TuneBarrier.State)? {
        for _ in 0..<100 {
            let before = barrier.current
            guard before.sequence % 2 == 0 else {
                Thread.sleep(forTimeInterval: 0.002)
                continue
            }
            guard var snapshot = provider(seconds + settleSeconds) else { return nil }
            guard barrier.current == before else { continue }
            let rate = snapshot.sampleRate
            let asked = Int(((seconds + settleSeconds) * rate).rounded())
            let settle = snapshot.frames < asked ? Int((settleSeconds * rate).rounded()) : 0
            let keep = max(0, min(snapshot.frames - settle, Int((seconds * rate).rounded())))
            snapshot.samples.removeFirst(2 * (snapshot.frames - keep))
            return (snapshot, before)
        }
        return nil
    }

    // MARK: Decode confirmation

    /// `identity` with any decode confirming it (see the type's notes).
    private func confirmed(_ identity: SignalIdentity, centerHz: Double, atHz: Double, bandwidthHz: Double?,
                           now: Date) -> SignalIdentity {
        guard let model else { return identity }
        let m = identity.measurement
        let signalHz = m.occupiedBandwidthHz > 0 ? centerHz + m.offsetHz : atHz
        let halfWidth = max(max(m.occupiedBandwidthHz, bandwidthHz ?? 0) / 2, Self.minimumMatchHz)
        let log = model.decodeLog
        return Self.confirm(identity, signalHz: signalHz, halfWidthHz: halfWidth, rows: log.slotRows + log.liveRows,
                            box: model.modemBox, now: now)
    }

    /// `identity` confirmed by the nearest of `rows` (audio frequencies in `box`) within `halfWidthHz` of
    /// `signalHz` whose mode is the one named, or by the nearest when none was named.
    static func confirm(_ identity: SignalIdentity, signalHz: Double, halfWidthHz: Double, rows: [DecodeRow],
                        box: ModemBox, now: Date) -> SignalIdentity {
        let decoded = rows.compactMap { row -> (mode: ModeID, distance: Double)? in
            guard let mode = row.mode else { return nil }
            if let slotStart = row.utcTime {
                let slotSeconds = ModemCatalog.slot(mode)?.slotSeconds ?? 0
                guard now.timeIntervalSince(slotStart) - slotSeconds <= decodeSeconds else { return nil }
            } else {
                guard !row.isQuiet, !row.history.isEmpty else { return nil }
            }
            // A slot row's FT8 frequency is tone 0's; its signal's centre is 3.5 tones up (`DecodeLog.signalCentreHz`).
            let audio = row.utcTime != nil && mode == .ft8 ? row.frequencyHz + 3.5 * FT8Encoder.toneSpacing
                                                           : row.frequencyHz
            let distance = abs(box.rfHz(forAudio: audio) - signalHz)
            return distance <= halfWidthHz ? (mode, distance) : nil
        }.sorted { $0.distance < $1.distance }

        var out = identity
        let match: ModeID?
        if let best = identity.best {
            match = decoded.first { tableName($0.mode) == best.name }?.mode
        } else {
            match = decoded.first?.mode
        }
        guard let match else { return identity }
        let name = tableName(match)
        var best = identity.best ?? ModeMatch(name: name, confidence: 1, evidence: [])
        best.confidence = 1
        best.evidence.append("decoded by the \(match.label) decoder")
        out.best = best
        out.alternatives.removeAll { $0.name == name }
        out.confirmedByDecode = true
        out.needsLongerRead = false   // a decode settles what a longer read would
        return out
    }

    /// A decoder's mode as the mode table names it.
    static func tableName(_ mode: ModeID) -> String {
        switch mode {
        case .cw: "CW"
        case .psk31: "PSK31 / PSK63"
        case .rtty: "RTTY"
        case .ft8: "FT8 / FT4"
        case .wspr: "WSPR"
        }
    }

    // MARK: Hover

    /// The pointer rests at `point` (view points) over `hz` (display Hz).
    func hover(at point: CGPoint, hz: Double) {
        if let anchor = hoverAnchor, hypot(point.x - anchor.x, point.y - anchor.y) <= Self.moveTolerance { return }
        endHover()
        hoverAnchor = point
        hoverTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.dwellSeconds))
            guard !Task.isCancelled, let self else { return }
            hoverPending = true
            let identity = await identify(atHz: hz)
            guard !Task.isCancelled else { return }
            hoverPending = false
            hoverIdentity = identity
        }
    }

    /// The pointer left (or the spectrum moved under it): cancels any identification and clears the answer.
    func endHover() {
        hoverTask?.cancel()
        hoverTask = nil
        hoverAnchor = nil
        hoverPending = false
        hoverIdentity = nil
    }

    // MARK: Tuning

    /// The radio is about to retune (or start) and its IQ history to clear.
    func retuneBegins() { tuning.begin() }

    /// The retune is done: the ring's IQ is now at `displayCenterHz` (nil: the retune failed, still the old
    /// centre). Forgets the answers and the pointer's.
    func retuned(displayCenterHz: Double?) {
        tuning.end(centerHz: displayCenterHz)
        cache.removeAll()
        endHover()
    }
}
