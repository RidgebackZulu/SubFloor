import CoreGraphics
import DSPCore
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

/// Signal ID's own serial executor: a task that prefers it (`Task.detached(executorPreference:)`) runs its jobs on
/// one dispatch queue, in the order they come. An identification's work is one synchronous job (its reads and its
/// analysis never suspend), so identifications run one at a time, never side by side, and never on the cooperative
/// pool's few threads.
final class SignalIDExecutor: TaskExecutor {
    private let queue = DispatchQueue(label: "app.subfloor.signal-id", qos: .userInitiated)

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job), executor = asUnownedTaskExecutor()
        queue.async { job.runSynchronously(on: executor) }
    }
}

/// Signal ID in the app: names the signal at a display frequency from the newest IQ in the recorder's pre-roll ring
/// (`StreamRecorder.snapshot`), with `SignalIdentifier.identify`.
///
/// **Off the main actor, one at a time.** The reads and the analysis run in a task given only Sendable values, on
/// the service's own serial executor (`SignalIDExecutor`), never the cooperative pool: identifications queue behind
/// each other in the order asked for (the hover's, the card's, `get_cursor`'s, a scan's), so at most one holds IQ
/// and works at a time, and none starves the app's other async work. Awaiting `identify` from a task that is then
/// cancelled cancels it, queued or running: one still queued returns at once when its turn comes, a running one
/// stops between the identifier's stages or the read's pieces, and the answer is dropped. The main actor reads the
/// model (the spectrum, the decode log) and the cache only. With the radio stopped the ring still holds what it
/// heard last: that is read, and nil comes only when it holds nothing.
///
/// **The IQ and its centre.** Everything is in display Hz: the mode table's band hints are, and with HamItUp on the
/// radio is tuned `Upconverter.loHz` above. `AppModel` brackets every clear of the IQ history (a hardware retune, an
/// engine start) with the `tuning` barrier, which carries the display centre the ring's IQ is at; a read is
/// retried while the barrier is moving, and the whole identification is dropped (nil) when the radio retuned
/// before it finished. A read that reaches back to the barrier (shorter than asked for) loses its oldest
/// `settleSeconds`: the pipeline carries old-centre samples past it. Under a second left gives the identifier's
/// "Too soon after tuning — try again"; between that and the 3 s asked for, the answer's note says how much was
/// read ("Read 1.4 s of the 3 s asked for").
///
/// **The first read** (I1). A millisecond of the ring says its rate first. At or under `channelAboveRate` the read is
/// 3 s of the whole capture (`snapshotProvider`). Above it, it is read off the ring a piece at a time
/// and cut as it comes to a channel around the point (`firstChannelHz` wide: 4 × the identifier's 48 kHz local view,
/// so the measurement window of anything that view finds fits; wider for an extent the app's spectrum shows there,
/// or an agent's bandwidth), as the longer read is: 3 s at 10 MS/s is 30 MB at the channel's 1.25 MS/s instead of
/// 240 MB of floats and 120 MB of the ring's int16 at the radio's. The identifier runs on the channel at its own rate
/// and centre, with the app's spectrum cut to the channel's span, and its measurement is put back in the capture's
/// frame. A point too near the capture's edge for the channel, or a signal the answer shows was wider than it was
/// sized for, is read whole (as at a lower rate). When the IQ is another capture's than the model shows (a hardware
/// tune that failed leaves it at the old centre), a point it holds is identified there, in display Hz as ever, and
/// one it doesn't is "Too soon after tuning — try again" (never a signal from elsewhere, mixed past Nyquist).
///
/// **The longer read** (ruling R26). The first pass is 3 s. When it asks for more
/// (`needsLongerRead`), up to `longSeconds` are read off the ring a piece at a time (`chunkProvider`, at most
/// `chunkSeconds` or `maxChunkFrames` each) and each piece cut down as it comes (`ChannelExtractor`) to a channel
/// around the signal, `minimumChannelHz` or `channelWidths` × its width if wider: the read is never held at the
/// radio's rate (16 s at 2 MS/s would be 256 MB; the channel's is 32 MB, `longReadBudgetBytes` at most, a wider
/// channel's read shortened to fit). The identifier then runs again on the channel, at its own rate and centre,
/// with the channel as its longer read; its measurement is put back in the capture's frame. A ring holding less
/// gives what it holds (its oldest `settleSeconds` dropped when it reaches back to a retune), which the identifier
/// says in `note`; a read that fails, or a channel too wide for one, is said in `note` too, and the first read's
/// answer stands.
///
/// **Cache.** An answer with an extent that had every read it asked for (or that a decode confirmed) is kept
/// `cacheSeconds`, over the extent it found (and the point asked about): a point on the same signal reuses it. "No
/// signal" and "Too weak" are kept as long for the point alone. A retune empties it.
///
/// **Decode confirmation.** A running decoder's row within ±half the signal's width (at least `minimumMatchHz`) —
/// a live row with text, or a slot row whose slot ended in the last `decodeSeconds` — whose mode is consistent with
/// the answer (ruling R28: the one named; when none was, one offered or one whose family was measured) confirms it:
/// `confirmedByDecode`, at 1.0. Never an answer with no extent. Applied to every answer, cached or new.
///
/// **Hover.** `AppModel.hover(at:viewSize:)` feeds the pointer: resting `dwellSeconds` starts `identify` there
/// (`hoverPending` while it runs, then `hoverIdentity`; the first pass's answer is up with `hoverMeasuring` while a
/// longer read runs); moving more than `moveTolerance` points from where it
/// came to rest, leaving, the spectrum moving under it (zoom, pan) or a retune cancels it and clears the answer.
///
/// **Card.** A right click (`openCard`) identifies the signal there the same way and fills `card` in as it comes;
/// the UI shows it as a popover at the click. A retune that drops its longer read leaves the first answer, saying so
/// (`longerReadCutNote`).
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
    /// Above this capture rate the first read is cut to a channel as it comes off the ring.
    nonisolated static let channelAboveRate = 1_000_000.0
    /// The first read's channel at least: 4 × the identifier's 48 kHz local view.
    nonisolated static let firstChannelHz = 4 * 48_000.0
    /// The first read's channel spans this many times a known extent's width either side of it (the measurer's
    /// window is 3 × the extent: 1.5 either side, and a margin).
    nonisolated static let extentReach = 1.75
    /// What the ring's rate is read from: this much of its newest IQ.
    nonisolated static let probeSeconds = 0.001
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
    /// `hoverIdentity` is the first pass's answer and the longer read it asked for is running.
    private(set) var hoverMeasuring = false

    /// The right-click card: where it opened, what it is for, and the answer as it comes.
    struct Card: Equatable {
        /// Each opening has its own: a popover for one card is never taken for another's.
        var id: Int
        /// Where it was clicked, in view points from the top left.
        var point: CGPoint
        /// The frequency clicked (display Hz).
        var hz: Double
        /// The signal's centre (display Hz) when it has an extent, else `hz`.
        var signalHz: Double
        /// Nil while pending, and when there was no data (the radio stopped, or retuned meanwhile).
        var identity: SignalIdentity?
        var pending = true
        /// `identity` is the first pass's answer and the longer read it asked for is running.
        var measuring = false
    }

    /// The open card (nil: none). Shown as a popover at its point.
    private(set) var card: Card?

    /// Test hook: where the IQ comes from (`AppModel` points it at its IQ recorder).
    @ObservationIgnored var snapshotProvider: SnapshotProvider = { _ in nil }
    /// Test hook: where the longer read comes from.
    @ObservationIgnored var chunkProvider: ChunkProvider = { _, _, _ in nil }
    /// Test hook: the analysis (the identifier).
    @ObservationIgnored var analysis: Analysis = { iq, rate, centre, at, width, spectrum, longer in
        SignalIdentifier.identify(iq: iq, sampleRate: rate, captureCenterHz: centre, atHz: at, bandwidthHz: width,
                                  spectrumDb: spectrum, longer: longer)
    }
    /// Test hook: the clock decodes are confirmed and answers cached by.
    @ObservationIgnored var now: @Sendable () -> Date = { Date() }
    /// Test hook: the hover's dwell (returns early when cancelled).
    @ObservationIgnored var dwell: @MainActor @Sendable () async -> Void = {
        try? await Task.sleep(for: .seconds(SignalIDService.dwellSeconds))
    }
    @ObservationIgnored let tuning = TuneBarrier()
    /// Where every identification runs, one at a time.
    @ObservationIgnored let executor = SignalIDExecutor()
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
    /// Counts the hovers ended, so a first answer arriving late is known for stale.
    @ObservationIgnored private var hoverGeneration = 0
    @ObservationIgnored private var cardTask: Task<Void, Never>?
    @ObservationIgnored private var cardGeneration = 0

    /// Reads `model`'s radio, spectrum and decodes, and its IQ recorder's ring.
    func attach(to model: AppModel, recorder: StreamRecorder) {
        self.model = model
        snapshotProvider = { [recorder] in recorder.snapshot(lastSeconds: $0) }
        chunkProvider = { [recorder] in recorder.snapshot(lastSeconds: $0, chunkFrames: $1, $2) }
    }

    // MARK: Identify

    /// The signal at `atHz` (display Hz), or over `bandwidthHz` around it when given (an agent's); nil when there is
    /// no data (an empty ring), when the radio retuned before it finished, or when cancelled.
    ///
    /// When the first pass asks for a longer read, `firstAnswer` is called with that pass's answer as soon as it is
    /// made (on the main actor, not after this call returned): the one to show while the longer read runs. With
    /// `longerRead` false none is made (a stepped scan's ring holds only the first read): the first answer is
    /// returned, still wanting it.
    func identify(atHz: Double, bandwidthHz: Double? = nil, longerRead: Bool = true,
                  firstAnswer: (@MainActor (SignalIdentity) -> Void)? = nil) async -> SignalIdentity? {
        guard let model else { return nil }
        let now = self.now()
        let sequence = tuning.current.sequence
        cache.removeAll { $0.sequence != sequence || now.timeIntervalSince($0.at) > Self.cacheSeconds }
        if let hit = cache.first(where: { $0.range.contains(atHz) && $0.bandwidthHz == bandwidthHz }) {
            return confirmed(hit.identity, centerHz: hit.centerHz, bandwidthHz: bandwidthHz, now: now)
        }

        let spectrum = model.spectrumSnapshot(), modelCentre = model.centerHz
        let provider = snapshotProvider, chunks = chunkProvider, analysis = self.analysis, barrier = tuning
        // The first answer reaches the main actor in a task of its own: dropped once this call has returned.
        let finished = Finished()
        defer { finished.value = true }
        var onFirst: (@Sendable (SignalIdentity, TuneBarrier.State) -> Void)?
        if let give = firstAnswer {
            onFirst = { [weak self] first, state in
                Task { @MainActor in
                    guard let self, !finished.value, state == self.tuning.current else { return }
                    give(self.confirmed(first, centerHz: state.centerHz, bandwidthHz: bandwidthHz, now: self.now()))
                }
            }
        }
        let onFirstAnswer = onFirst
        let task = Task.detached(executorPreference: executor, priority: .userInitiated) {
            Self.run(atHz: atHz, bandwidthHz: bandwidthHz, spectrum: spectrum, longer: longerRead,
                     modelCenterHz: modelCentre, provider: provider, chunks: chunks, analysis: analysis,
                     barrier: barrier, onFirst: onFirstAnswer)
        }
        let result = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        guard !Task.isCancelled, let result, result.state == tuning.current else { return nil }

        let identity = result.identity, state = result.state
        let answer = confirmed(identity, centerHz: state.centerHz, bandwidthHz: bandwidthHz, now: self.now())
        // Kept when it found an extent and had every read it asked for (a short ring's answer improves as it
        // fills), or when a decode settled it; over the extent. "No signal" and "Too weak" with every read, for the
        // point alone (a poll of empty spectrum doesn't read it again); never "Too soon", which the ring outgrows.
        let m = identity.measurement
        if m.occupiedBandwidthHz > 0 && (result.complete || answer.confirmedByDecode) {
            let centre = state.centerHz + m.offsetHz, half = max(m.occupiedBandwidthHz, m.bandwidth6dBHz) / 2
            cache.append(CacheEntry(range: min(centre - half, atHz)...max(centre + half, atHz),
                                    bandwidthHz: bandwidthHz, sequence: state.sequence, centerHz: state.centerHz,
                                    at: self.now(), identity: identity))
        } else if m.occupiedBandwidthHz == 0 && result.complete && identity.note != SignalIdentifier.tooSoonNote
                    && identity.note != SignalIdentifier.cancelledNote {
            cache.append(CacheEntry(range: atHz...atHz, bandwidthHz: bandwidthHz, sequence: state.sequence,
                                    centerHz: state.centerHz, at: self.now(), identity: identity))
        }
        return answer
    }

    /// Forgets every answer.
    func invalidateCache() { cache.removeAll() }

    /// Whether an `identify` call has returned (read on the main actor).
    @MainActor private final class Finished { var value = false }

    /// What `run` made of it: the answer, the tuning its IQ was heard in, and whether it had every read it asked
    /// for (the first pass's 3 s, and the longer read when wanted).
    struct Outcome: Sendable {
        var identity: SignalIdentity
        var state: TuneBarrier.State
        var complete: Bool
    }

    /// The first read, the analysis and (on request, when `longer`) the longer read: on the service's executor. Nil
    /// when there is no IQ, the radio retuned meanwhile, or the task was cancelled. `modelCenterHz`: the display
    /// centre the model shows (see `firstRead`). `whole`: the first read is the whole capture whatever its rate
    /// (tests compare the two).
    nonisolated static func run(atHz: Double, bandwidthHz: Double?, spectrum: SpectrumSnapshot?, longer: Bool,
                                modelCenterHz: Double? = nil, provider: SnapshotProvider, chunks: ChunkProvider,
                                analysis: Analysis, barrier: TuneBarrier, whole wholeFirst: Bool = false,
                                onFirst: (@Sendable (SignalIdentity, TuneBarrier.State) -> Void)? = nil) -> Outcome? {
        var whole = wholeFirst
        var identity: SignalIdentity
        var read: FirstRead
        while true {
            // Held only here: a channel read again whole is let go first.
            guard !Task.isCancelled,
                  let first = firstRead(atHz: atHz, bandwidthHz: bandwidthHz, spectrum: spectrum, whole: whole,
                                        modelCenterHz: modelCenterHz, provider: provider, chunks: chunks,
                                        barrier: barrier) else { return nil }
            // A point outside the capture the IQ holds (a failed tune left it at the old centre): nothing to read.
            guard !first.iq.isEmpty || abs(atHz - first.state.centerHz) <= first.captureRate / 2 else {
                let tooSoon = SignalIdentity(measurement: SignalMeasurement(offsetHz: atHz - first.state.centerHz,
                                                                            family: .noise),
                                             note: SignalIdentifier.tooSoonNote)
                return Outcome(identity: tooSoon, state: first.state, complete: false)
            }
            identity = analysis(first.iq, first.sampleRate, first.state.centerHz + first.offsetHz, atHz, bandwidthHz,
                                first.spectrumDb, nil)
            guard !Task.isCancelled else { return nil }
            identity.measurement.offsetHz += first.offsetHz   // back in the capture's frame
            // A signal wider than the channel was cut for is read again whole.
            if let window = first.channelHz, wider(identity, than: window) {
                whole = true
                continue
            }
            read = first
            break
        }
        let state = read.state, rate = read.sampleRate
        // Less than the 3 s asked for (but enough to measure): said in the note.
        let readSeconds = Double(read.frames) / rate
        if read.short && readSeconds >= SignalIdentifier.minimumSeconds {
            add(String(format: "Read %.1f s of the %.0f s asked for", readSeconds, firstSeconds), to: &identity)
        }
        guard identity.needsLongerRead, longer else {
            return Outcome(identity: identity, state: state, complete: !read.short && !identity.needsLongerRead)
        }

        // The longer read, on the channel around what the first pass measured; the first answer is out meanwhile.
        onFirst?(identity, state)
        read.iq = []   // not held through the longer read
        let m = identity.measurement
        switch longerRead(offsetHz: m.offsetHz, widthHz: max(m.occupiedBandwidthHz, bandwidthHz ?? 0),
                          tuning: state, sampleRate: read.captureRate, chunks: chunks, barrier: barrier) {
        case .dropped:
            return nil
        case .unavailable(let why):
            add(why, to: &identity)
            return Outcome(identity: identity, state: state, complete: false)
        case .read(let long):
            var refined = analysis(long.iq, long.sampleRate, state.centerHz + long.offsetHz, atHz, bandwidthHz, nil,
                                   { (long.iq, long.seconds) })
            guard !Task.isCancelled else { return nil }
            refined.measurement.offsetHz += long.offsetHz   // back in the capture's frame
            return Outcome(identity: refined, state: state, complete: !refined.needsLongerRead)
        }
    }

    /// The answer measured a signal the first read's channel (`windowHz` wide) wasn't cut wide enough for: the
    /// measurer's window (3 × its width) would reach past it, or it says it is wider than the view.
    nonisolated static func wider(_ identity: SignalIdentity, than windowHz: Double) -> Bool {
        let m = identity.measurement
        return 2 * extentReach * max(m.occupiedBandwidthHz, m.bandwidth6dBHz) > windowHz
            || m.notes.contains { $0.contains("wider than the view") }
    }

    /// The first read: IQ ending at the ring's newest, at `sampleRate` and centred `offsetHz` from the capture's
    /// centre (a channel), or the whole capture (`offsetHz` 0, `channelHz` nil).
    struct FirstRead: Sendable {
        var iq: [Float]
        var sampleRate: Double
        var offsetHz: Double
        /// The channel's clean width; nil for the whole capture.
        var channelHz: Double?
        /// The capture's rate.
        var captureRate: Double
        /// The app's spectrum over what was read, when it is of this capture.
        var spectrumDb: [Float]?
        /// Shorter than the 3 s asked for: it reached back to a retune.
        var short: Bool
        var state: TuneBarrier.State
        var frames: Int { iq.count / 2 }
    }

    /// The first read (see the type's notes): a channel around the point above `channelAboveRate`, unless `whole`.
    /// A read shorter than asked for reaches back to the last barrier, and loses its oldest `settleSeconds`. Retried
    /// while the barrier moves; a channel read that fails (the ring overwrote it) is tried again, then read whole.
    /// Nil when there is no IQ; empty for a point outside the capture the IQ holds when that capture isn't the one
    /// the model shows (`modelCenterHz`, its display centre).
    nonisolated static func firstRead(atHz: Double, bandwidthHz: Double?, spectrum: SpectrumSnapshot?, whole: Bool,
                                      modelCenterHz: Double?, provider: SnapshotProvider, chunks: ChunkProvider,
                                      barrier: TuneBarrier) -> FirstRead? {
        var failures = 0
        for _ in 0..<100 {
            if Task.isCancelled { return nil }
            let state = barrier.current
            guard state.sequence % 2 == 0 else {
                Thread.sleep(forTimeInterval: 0.002)
                continue
            }
            // The ring's rate, from a few milliseconds of it (and nothing there: no data).
            guard let probe = provider(probeSeconds) else { return nil }
            let rate = probe.sampleRate
            guard barrier.current == state, rate > 0 else { continue }
            // The app's spectrum, when it is of this capture (the identifier works out its own otherwise).
            let appDb = spectrum.flatMap { s in
                abs(s.centerHz - state.centerHz) < 0.5 && abs(s.spanHz - rate) < 0.5 && s.average.count >= 8
                    ? s.average : nil
            }
            let pointHz = atHz - state.centerHz
            // A point the IQ doesn't hold, while the IQ is another capture's than the model shows (a tune that
            // failed): nothing read (`run` answers it).
            guard abs(pointHz) <= rate / 2 || modelCenterHz.map({ abs($0 - state.centerHz) < 1 }) ?? true else {
                return FirstRead(iq: [], sampleRate: rate, offsetHz: 0, channelHz: nil, captureRate: rate,
                                 spectrumDb: nil, short: true, state: state)
            }
            if !whole, failures < 2,
               let plan = firstChannel(pointHz: pointHz, bandwidthHz: bandwidthHz, spectrumDb: appDb, rate: rate) {
                switch channelRead(seconds: firstSeconds, offsetHz: plan.offsetHz, windowHz: plan.windowHz,
                                   tuning: state, sampleRate: rate, chunks: chunks, barrier: barrier) {
                case .read(let channel):
                    let asked = Int((firstSeconds * channel.sampleRate).rounded())
                    return FirstRead(iq: channel.iq, sampleRate: channel.sampleRate, offsetHz: channel.offsetHz,
                                     channelHz: plan.windowHz, captureRate: rate,
                                     spectrumDb: appDb.flatMap { crop($0, rate: rate, offsetHz: channel.offsetHz,
                                                                      channelRate: channel.sampleRate) },
                                     short: channel.iq.count / 2 < asked, state: state)
                case .dropped:
                    continue
                case .failed:
                    failures += 1
                    continue
                }
            }
            guard var snapshot = provider(firstSeconds + settleSeconds) else { return nil }
            guard barrier.current == state, snapshot.sampleRate == rate else { continue }
            let asked = Int(((firstSeconds + settleSeconds) * rate).rounded())
            let settle = snapshot.frames < asked ? Int((settleSeconds * rate).rounded()) : 0
            let keep = max(0, min(snapshot.frames - settle, Int((firstSeconds * rate).rounded())))
            snapshot.samples.removeFirst(2 * (snapshot.frames - keep))
            return FirstRead(iq: snapshot.samples, sampleRate: rate, offsetHz: 0, channelHz: nil, captureRate: rate,
                             spectrumDb: appDb, short: keep < Int((firstSeconds * rate).rounded()), state: state)
        }
        return nil
    }

    /// The first read's channel for the point `pointHz` from the centre of a capture at `rate`: centred on it (on the
    /// nearest of the app spectrum's bins, so that spectrum cuts to it exactly), `firstChannelHz` wide or wider to
    /// take in `extentReach` × an extent either side (an agent's bandwidth, else the app spectrum's there). Nil to
    /// read the whole capture: at or under `channelAboveRate`, a channel that would reach past the capture's edge,
    /// or one the capture's rate wouldn't decimate for.
    nonisolated static func firstChannel(pointHz: Double, bandwidthHz: Double?, spectrumDb: [Float]?,
                                         rate: Double) -> (offsetHz: Double, windowHz: Double)? {
        guard rate > channelAboveRate else { return nil }
        var centre = pointHz
        if let db = spectrumDb { centre = (pointHz / (rate / Double(db.count))).rounded() * rate / Double(db.count) }
        let extent = bandwidthHz.map { (offsetHz: pointHz, widthHz: $0) }
            ?? spectrumDb.flatMap { SignalIdentifier.extent($0, sampleRate: rate, pointHz: pointHz) }
        var window = firstChannelHz
        if let e = extent { window = max(window, 2 * (abs(e.offsetHz - centre) + extentReach * e.widthHz)) }
        guard abs(centre) + window / 2 <= rate / 2,
              !DecimationPlan.stages(inputRate: rate, minimumRate: max(4 * window, Channel.minimumRate)).isEmpty
        else { return nil }
        return (centre, window)
    }

    /// The app's spectrum of the whole capture (`db`, at `rate`, FFT-shifted) over a channel at `channelRate`
    /// centred `offsetHz` from the capture's centre: its bins there, the channel's centre in the middle, taken round
    /// the ends past the capture's edge. Nil when the channel's span isn't a whole, even number of its bins, or the
    /// centre isn't on one.
    nonisolated static func crop(_ db: [Float], rate: Double, offsetHz: Double, channelRate: Double) -> [Float]? {
        let n = db.count, binHz = rate / Double(n)
        let bins = Double(n) * channelRate / rate, shift = offsetHz / binHz
        let count = Int(bins.rounded()), centre = Int(shift.rounded())
        guard count >= 8, count % 2 == 0, abs(bins - Double(count)) < 1e-6, abs(shift - Double(centre)) < 1e-3
        else { return nil }
        let start = n / 2 + centre - count / 2
        return (0..<count).map { db[((start + $0) % n + n) % n] }
    }

    /// `note` added after any the answer has.
    private nonisolated static func add(_ note: String, to identity: inout SignalIdentity) {
        identity.note = [identity.note, note].compactMap { $0 }.joined(separator: "; ")
    }

    /// How the longer read went.
    enum LongReadOutcome: Sendable {
        case read(LongRead)
        /// None to be had: why, for the answer's note.
        case unavailable(String)
        /// Cancelled, or the radio retuned: the answer is dropped.
        case dropped
    }

    /// A channel read off the ring (the longer read's; the first read's above `channelAboveRate`): interleaved IQ at
    /// `sampleRate`, centred `offsetHz` from the capture centre.
    struct LongRead: Sendable {
        var iq: [Float]
        var sampleRate: Double
        var offsetHz: Double
        var seconds: Double
        /// The output's size as reserved before the read, in floats, and whether it outgrew that (it never
        /// should: the read's peak is this plus one piece).
        var reservedFloats: Int
        var grew: Bool
    }

    /// Up to `longSeconds` (fewer for a channel too wide for `longReadBudgetBytes`) of the ring, read a piece at a
    /// time and cut to the channel around `offsetHz` (`widthHz` wide, the signal's) as it comes, in the tuning
    /// `tuning`. A read that reaches back to the barrier loses its oldest `settleSeconds`; a shorter read than
    /// asked for is the identifier's to say. The output is sized once, for what was asked: never grown by doubling.
    nonisolated static func longerRead(offsetHz: Double, widthHz: Double, tuning: TuneBarrier.State,
                                       sampleRate: Double, chunks: ChunkProvider,
                                       barrier: TuneBarrier) -> LongReadOutcome {
        guard barrier.current == tuning, sampleRate > 0 else { return .dropped }
        let windowHz = max(minimumChannelHz, channelWidths * widthHz)
        let rate = Channel.outputRate(sampleRate: sampleRate, bandwidthHz: windowHz)
        let seconds = min(longSeconds, Double(longReadBudgetBytes / 8) / rate)
        guard seconds > firstSeconds else {
            return .unavailable(String(format: "No longer read: a %.0f kHz channel is too wide for one",
                                       windowHz / 1000))
        }
        switch channelRead(seconds: seconds, offsetHz: offsetHz, windowHz: windowHz, tuning: tuning,
                           sampleRate: sampleRate, chunks: chunks, barrier: barrier) {
        case .read(let long): return .read(long)
        case .dropped: return .dropped
        case .failed: return .unavailable("The longer read failed; this is the first read's answer")
        }
    }

    /// How a channel read went.
    enum ChannelReadOutcome: Sendable {
        case read(LongRead)
        /// The ring overwrote what was being read, was reconfigured, or held nothing.
        case failed
        /// Cancelled, or the radio retuned meanwhile.
        case dropped
    }

    /// `seconds` (and `settleSeconds`) of the ring's newest IQ, read a piece at a time and cut as it comes to a channel
    /// `windowHz` wide around `offsetHz` (`ChannelExtractor`, not sharp: the window's middle is what is read), in the
    /// tuning `tuning`. A capture the channel wouldn't decimate (no wider than 4 × it) is kept whole. A read that
    /// reaches back to the barrier loses its oldest `settleSeconds`; anything over `seconds` is dropped. The output
    /// is sized once, for what was asked: never grown by doubling; the peak is it and one piece.
    nonisolated static func channelRead(seconds: Double, offsetHz: Double, windowHz: Double,
                                        tuning: TuneBarrier.State, sampleRate: Double, chunks: ChunkProvider,
                                        barrier: TuneBarrier) -> ChannelReadOutcome {
        guard barrier.current == tuning, sampleRate > 0 else { return .dropped }
        let decimates = !DecimationPlan.stages(inputRate: sampleRate,
                                               minimumRate: max(4 * windowHz, Channel.minimumRate)).isEmpty
        let extractor = decimates ? ChannelExtractor(sampleRate: sampleRate, offsetHz: offsetHz,
                                                     bandwidthHz: windowHz, sharp: false) : nil
        let whole = extractor == nil
        let rate = extractor?.rate ?? sampleRate
        let asked = seconds + settleSeconds
        let askedFrames = Int((asked * sampleRate).rounded())
        var copied: [Float] = []
        if let extractor { extractor.reserve(inputFrames: askedFrames) } else { copied.reserveCapacity(2 * askedFrames) }
        let read = chunks(asked, min(Int(chunkSeconds * sampleRate), maxChunkFrames)) { piece in
            guard !Task.isCancelled else { return false }
            if let extractor { extractor.feed(piece) } else { copied.append(contentsOf: piece) }
            return true
        }
        guard !Task.isCancelled, barrier.current == tuning else { return .dropped }
        guard let read, read.sampleRate == sampleRate else { return .failed }
        let reserved = extractor?.reservedFloats ?? 2 * askedFrames
        let grew = extractor?.outgrewReservation ?? (copied.count > reserved)
        var iq = extractor?.finish().samples ?? copied
        // The oldest `settleSeconds` of a read reaching back to the barrier, and anything over `seconds`.
        let settle = read.frames < askedFrames ? Int((settleSeconds * rate).rounded()) : 0
        let keep = max(0, min(iq.count / 2 - settle, Int((seconds * rate).rounded())))
        iq.removeFirst(iq.count - 2 * keep)
        return .read(LongRead(iq: iq, sampleRate: rate, offsetHz: whole ? 0 : offsetHz, seconds: Double(keep) / rate,
                              reservedFloats: reserved, grew: grew))
    }

    // MARK: Decode confirmation

    /// `identity` with any decode confirming it (see the type's notes).
    private func confirmed(_ identity: SignalIdentity, centerHz: Double, bandwidthHz: Double?,
                           now: Date) -> SignalIdentity {
        guard let model else { return identity }
        let m = identity.measurement
        let signalHz = centerHz + m.offsetHz
        let halfWidth = max(max(m.occupiedBandwidthHz, bandwidthHz ?? 0) / 2, Self.minimumMatchHz)
        let log = model.decodeLog
        return Self.confirm(identity, signalHz: signalHz, halfWidthHz: halfWidth, rows: log.slotRows + log.liveRows,
                            box: model.modemBox, now: now)
    }

    /// `identity` confirmed by the nearest of `rows` (audio frequencies in `box`) within `halfWidthHz` of
    /// `signalHz` whose mode is consistent with it (ruling R28): the one named; when none was, one offered among
    /// the alternatives, or one whose table row the measured family fits. Never an answer with no extent ("No
    /// signal", "Too weak", "Too soon"): there is nothing measured for a decode to agree with.
    static func confirm(_ identity: SignalIdentity, signalHz: Double, halfWidthHz: Double, rows: [DecodeRow],
                        box: ModemBox, now: Date) -> SignalIdentity {
        let m = identity.measurement
        guard m.occupiedBandwidthHz > 0, m.family != .noise else { return identity }
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
            let offered = Set(identity.alternatives.map(\.name))
            match = decoded.first {
                let name = tableName($0.mode)
                return offered.contains(name) || ModeTable.row(name)?.families.contains(m.family) == true
            }?.mode
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
        let generation = hoverGeneration
        hoverTask = Task { [weak self] in
            guard let dwell = self?.dwell else { return }
            await dwell()
            guard !Task.isCancelled, let self else { return }
            hoverPending = true
            let identity = await identify(atHz: hz) { [weak self] first in
                // The first pass is up while the longer read runs.
                guard let self, hoverGeneration == generation else { return }
                hoverPending = false
                hoverMeasuring = true
                hoverIdentity = first
            }
            guard !Task.isCancelled else { return }
            hoverPending = false
            hoverMeasuring = false
            hoverIdentity = identity
        }
    }

    /// The pointer left (or the spectrum moved under it): cancels any identification and clears the answer.
    func endHover() {
        hoverTask?.cancel()
        hoverTask = nil
        hoverAnchor = nil
        hoverGeneration += 1
        // Observed: written only when they change (this runs at mouse-move rate).
        if hoverPending { hoverPending = false }
        if hoverMeasuring { hoverMeasuring = false }
        if hoverIdentity != nil { hoverIdentity = nil }
    }

    // MARK: Card

    /// Opens the card for the signal at `hz` (display Hz), clicked at `point` (view points): identifies it (the cache
    /// answers at once for a signal the hover just read) and fills the card in, the first pass's answer first when
    /// a longer read follows. Replaces any open card; the hover's answer is cleared (the card is the answer now).
    func openCard(at point: CGPoint, hz: Double) {
        closeCard()
        endHover()
        let generation = cardGeneration
        card = Card(id: generation, point: point, hz: hz, signalHz: hz)
        cardTask = Task { [weak self] in
            guard let self else { return }
            let identity = await identify(atHz: hz) { [weak self] first in
                guard let self, cardGeneration == generation else { return }
                fill(first, measuring: true)
            }
            guard !Task.isCancelled, cardGeneration == generation else { return }
            fill(identity, measuring: false)
        }
    }

    /// Closes the card and cancels its identification; with `id`, only if that is the open card (a popover
    /// dismissed late must not close the card that replaced it).
    func closeCard(id: Int? = nil) {
        if let id, card?.id != id { return }
        cardTask?.cancel()
        cardTask = nil
        cardGeneration += 1
        if card != nil { card = nil }
    }

    /// The card's note when a retune cut its longer read short and the first answer stays.
    static let longerReadCutNote = "The longer read was cut short by a retune"

    /// `identity` into the card; nil (no data, or a retune during the longer read) keeps any first answer, said
    /// in its note when a longer read was running.
    private func fill(_ identity: SignalIdentity?, measuring: Bool) {
        guard var shown = card else { return }
        if identity == nil, shown.measuring, var first = shown.identity {
            first.note = [first.note, Self.longerReadCutNote].compactMap { $0 }.joined(separator: "; ")
            shown.identity = first
        }
        shown.pending = false
        shown.measuring = measuring
        if let identity {
            shown.identity = identity
            let m = identity.measurement
            shown.signalHz = m.occupiedBandwidthHz > 0 ? tuning.current.centerHz + m.offsetHz : shown.hz
        }
        card = shown
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
