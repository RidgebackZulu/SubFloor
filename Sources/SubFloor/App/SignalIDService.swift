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
        let job = UnownedJob(job)
        // Held by the job until it has run: a service let go meanwhile doesn't take its executor with it.
        queue.async { [self] in job.runSynchronously(on: asUnownedTaskExecutor()) }
    }
}

/// Whose an identification is (`SignalIDService.identify`): the owner's hover and card go ahead of agents' and
/// background work (`get_cursor`, its longer read, scans).
enum SignalIDPriority: Sendable { case owner, background }

/// Who runs next on the service's executor (`SignalIDService.identify`), on the main actor: one identification at a
/// time, the owner's queued ones before any background one, in the order asked within each. A newer hover replaces any
/// older one still queued (it gets nil). The owner asking stops a running background one (`preempted`, its task
/// cancelled: it stops at its next cancellation check); its caller, still waiting, asks again.
@MainActor
final class SignalIDQueue {
    @MainActor final class Ticket {
        let priority: SignalIDPriority
        /// A hover's: a newer hover replaces it while it is queued.
        let hover: Bool
        /// Asked again after the owner stopped it: first among the background ones.
        let again: Bool
        fileprivate var continuation: CheckedContinuation<Bool, Never>?
        /// Cancels its identification while it runs.
        var cancel: (() -> Void)?
        /// The owner stopped it while it ran.
        fileprivate(set) var preempted = false

        init(priority: SignalIDPriority, hover: Bool, again: Bool = false) {
            self.priority = priority
            self.hover = hover
            self.again = again
        }
    }

    private var queued: [Ticket] = []
    private var running: Ticket?

    /// How many are waiting (tests).
    var waiting: Int { queued.count }

    /// Waits for `ticket`'s turn: true when it has it (it runs until `finished`), false when a newer hover replaced it
    /// or its task was cancelled while it waited.
    func turn(_ ticket: Ticket) async -> Bool {
        if ticket.hover {
            for old in queued where old.hover { resume(old, false) }
        }
        if ticket.priority == .owner, let now = running, now.priority == .background, !now.preempted {
            now.preempted = true
            now.cancel?()
        }
        if running == nil && queued.isEmpty {
            running = ticket
            return true
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                ticket.continuation = continuation
                let index: Int
                switch (ticket.priority, ticket.again) {
                case (.owner, _): index = queued.firstIndex { $0.priority == .background } ?? queued.endIndex
                case (.background, true):
                    index = queued.firstIndex { $0.priority == .background && !$0.again } ?? queued.endIndex
                case (.background, false): index = queued.endIndex
                }
                queued.insert(ticket, at: index)
            }
        } onCancel: {
            Task { @MainActor in self.resume(ticket, false) }
        }
    }

    /// `ticket` has run: the next queued one gets its turn.
    func finished(_ ticket: Ticket) {
        guard running === ticket else { return }
        running = nil
        guard !queued.isEmpty else { return }
        let next = queued.removeFirst()
        running = next
        next.continuation?.resume(returning: true)
        next.continuation = nil
    }

    /// A queued `ticket` taken out, told `turn`.
    private func resume(_ ticket: Ticket, _ turn: Bool) {
        guard let index = queued.firstIndex(where: { $0 === ticket }) else { return }
        queued.remove(at: index)
        ticket.continuation?.resume(returning: turn)
        ticket.continuation = nil
    }
}

/// Signal ID in the app: names the signal at a display frequency from the newest IQ in the recorder's pre-roll ring
/// (`StreamRecorder.snapshot`), with `SignalIdentifier.identify`.
///
/// **Off the main actor, one at a time, the owner's first.** The reads and the analysis run in a task given only
/// Sendable values, on the service's own serial executor (`SignalIDExecutor`), never the cooperative pool, and the
/// queue (`SignalIDQueue`) gives that executor one identification at a time: at most one holds IQ and works, and none
/// starves the app's other async work. The owner's (`SignalIDPriority.owner`: the hover's and the card's) go ahead of
/// queued background ones (`get_cursor`'s and its longer read, `identify_signal`'s, a scan's); a newer hover replaces an
/// older one still queued (nil); and the owner asking stops a running background one at its next cancellation check,
/// which is then asked again while its caller waits (a scan's point is so read again). Awaiting `identify` from a task
/// that is then cancelled cancels it, queued or running: one queued returns nil at once, a running one stops between the
/// identifier's stages or the read's pieces, and the answer is dropped. The main actor reads the model (the spectrum,
/// the decode log) and the caches only. With the radio stopped the ring still holds what it heard last: that is read,
/// and nil comes only when it holds nothing.
///
/// **Time, radius and the comb.** The analysis gets when its IQ's last sample was on the air (`IQSnapshot.endTime`,
/// `IQRead.endTime`: the read's own, the longer read's its own, the look-back's each window's) only from the RSP
/// (`sourceKind`): the demo source and IQ files have no true time, so no slot evidence. Hover and card ask within
/// `radiusPixels` of the pointer at the current zoom (`radiusHz`); agents get the identifier's default. The capture's
/// interference comb is found once (`CaptureComb.find`, `findComb`, before the first read) on the app's spectrum of this
/// capture, or with none on `combReadSeconds` of the ring's newest IQ (never on a read that reaches the retune barrier);
/// it is kept `combSeconds`, only when the first read had its 3 s, and forgotten on a retune, and given only to analyses
/// of IQ heard in the tuning it was found in.
///
/// **A silent moment isn't an empty frequency** (`lookBack`). When the first read finds nothing at the point ("No
/// signal"), and a longer read may be made, the `longSeconds` before it (as far as the ring and the retune barrier go)
/// are analysed `firstSeconds` at a time going back, read off the ring in turn as a channel around the point, each read
/// within `longReadBudgetBytes` (one at 10 MS/s, two at 6) and trimmed in place, until a window measures a signal:
/// that answer, saying how long nothing was there to identify; "No signal" once none does. The first answer is out
/// meanwhile, as measuring. "No signal" is kept for the point once the look-back covered the 16 s or all the ring held
/// since the retune; a ring holding less says so ("Looked back 5.0 s of the 16 s asked for").
///
/// **Frames.** Every answer comes back in the capture's frame: its `measurement.offsetHz`, its `signals`' and its
/// `groupSpanHz` are all relative to the capture centre the ring's IQ was heard at (display Hz), which a group answer's
/// `captureCenterHz` says, whatever channel it was measured on (`recentred`).
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
/// longer read or a look-back runs), as the owner's, within `radiusPixels` at the zoom; moving more than
/// `moveTolerance` points from where it
/// came to rest, leaving, the spectrum moving under it (zoom, pan) or a retune cancels it and clears the answer.
///
/// **Trial decodes** (`SignalIDDecoding`). The card's and agents' identifications (`tryDecode`), never hover's, then
/// try a private decode where one applies (FT8's latest complete slot; RTTY, PSK31): a queued job of its own in the same
/// lane, after the answer is out (`firstAnswer`). A checked FT8 message names the signal it lies on at 1.0; readable
/// text is evidence for RTTY or PSK31. Its decoders are its own: the decoder panel, its settings and the decode history
/// never see it. An FT8 slot's messages are kept per slot and box (`slotDecodes`, forgotten on a retune): a scan decodes
/// a slot once.
///
/// **Card.** A right click (`openCard`) identifies the signal there the same way, with a trial decode, and fills `card`
/// in as it comes; the UI shows it as a popover at the click. A retune that drops its longer read leaves the first answer, saying so
/// (`longerReadCutNote`).
@MainActor @Observable
final class SignalIDService {
    /// Up to `lastSeconds` of the ring's newest IQ (`StreamRecorder.snapshot`), any thread.
    typealias SnapshotProvider = @Sendable (_ lastSeconds: Double) -> IQSnapshot?
    /// The same span handed over a piece of at most `chunkFrames` at a time
    /// (`StreamRecorder.snapshot(lastSeconds:chunkFrames:_:)`), any thread.
    typealias ChunkProvider = @Sendable (_ lastSeconds: Double, _ chunkFrames: Int,
                                         _ visit: (UnsafeBufferPointer<Float>) -> Bool) -> IQRead?
    /// `SignalIdentifier.identify(iq:…)` on what one analysis is given (`identifier`).
    typealias Analysis = @Sendable (AnalysisInput) -> SignalIdentity
    /// `CaptureComb.find(spectrumDb:sampleRate:centerHz:)`, any thread.
    typealias CombFinder = @Sendable (_ spectrumDb: [Float], _ sampleRate: Double, _ centerHz: Double) -> CaptureComb?

    /// What one analysis is given: `SignalIdentifier.identify(iq:…)`'s parameters.
    struct AnalysisInput {
        var iq: [Float]
        var sampleRate: Double
        /// `iq`'s centre (display Hz): a channel's, or the capture's.
        var captureCenterHz: Double
        var atHz: Double
        var bandwidthHz: Double?
        var spectrumDb: [Float]?
        var longer: (() -> (iq: [Float], seconds: Double)?)?
        /// Nil: the identifier's own (`SignalIdentifier.defaultRadiusHz`).
        var pointRadiusHz: Double?
        /// When `iq`'s last sample was on the air; nil without a true time (the demo source, an IQ file).
        var endTime: Date?
        /// The capture's interference comb, found once for its spectrum.
        var comb: CaptureComb?
    }

    /// The identifier itself.
    nonisolated static let identifier: Analysis = { a in
        SignalIdentifier.identify(iq: a.iq, sampleRate: a.sampleRate, captureCenterHz: a.captureCenterHz, atHz: a.atHz,
                                  bandwidthHz: a.bandwidthHz, spectrumDb: a.spectrumDb, longer: a.longer,
                                  pointRadiusHz: a.pointRadiusHz ?? SignalIdentifier.defaultRadiusHz,
                                  endTime: a.endTime, comb: a.comb)
    }

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
    /// Hover and card: the radius is this many view points' worth of Hz at the current zoom.
    static let radiusPixels = 4.0
    /// The comb found on a capture's spectrum is kept this long; with no app spectrum, it is found on this much of the
    /// ring's newest IQ (`combFrames` at most).
    nonisolated static let combSeconds = 5.0
    nonisolated static let combReadSeconds = 0.5
    nonisolated static let combFrames = 1 << 20
    /// A failed tune leaves the IQ at the old centre: for this long a point it doesn't hold is "Too soon", then
    /// `notAtFrequencyNote`.
    static let notAtFrequencyGraceSeconds = 1.0
    nonisolated static let notAtFrequencyNote = "The radio isn't at this frequency: the last tune failed"

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
    @ObservationIgnored var analysis: Analysis = SignalIDService.identifier
    /// Test hook: what finds the capture's comb.
    @ObservationIgnored var combFinder: CombFinder = { CaptureComb.find(spectrumDb: $0, sampleRate: $1, centerHz: $2) }
    /// Test hook: the most reads a look-back makes.
    @ObservationIgnored var lookBackReads = SignalIDService.lookBackMaxReads
    /// Test hook: the decoders a trial decode runs (`SignalIDDecoding`), fresh ones each time: never the panel's.
    @ObservationIgnored var decoders = SignalIDDecoding.Decoders.standard
    /// Test hook: where the IQ comes from (`AppModel.sourceKind`): only the RSP's samples carry a true time.
    @ObservationIgnored var sourceKind: @MainActor () -> SourceKind? = { nil }
    /// Test hook: the clock decodes are confirmed and answers cached by.
    @ObservationIgnored var now: @Sendable () -> Date = { Date() }
    /// Test hook: the hover's dwell (returns early when cancelled).
    @ObservationIgnored var dwell: @MainActor @Sendable () async -> Void = {
        try? await Task.sleep(for: .seconds(SignalIDService.dwellSeconds))
    }
    @ObservationIgnored let tuning = TuneBarrier()
    /// Where every identification runs, one at a time.
    @ObservationIgnored let executor = SignalIDExecutor()
    /// Who runs on it next.
    @ObservationIgnored let queue = SignalIDQueue()
    @ObservationIgnored private weak var model: AppModel?

    private struct CacheEntry {
        var range: ClosedRange<Double>
        var bandwidthHz: Double?
        var radiusHz: Double?
        var sequence: Int
        var centerHz: Double
        var at: Date
        var identity: SignalIdentity
    }

    @ObservationIgnored private var cache: [CacheEntry] = []
    /// FT8 slots a trial decoded, each box's messages: a scan's other points in that slot and box use them.
    @ObservationIgnored private var slotDecodes: [SignalIDDecoding.SlotDecodes] = []
    /// The capture's comb as last found, for the tuning it was found in, and when.
    @ObservationIgnored private var combCache: (state: TuneBarrier.State, at: Date, comb: CombReading)?
    /// When the last tune failed (nil: it didn't), by `now`.
    @ObservationIgnored private var tuneFailedAt: Date?
    @ObservationIgnored private var hoverAnchor: CGPoint?
    @ObservationIgnored private var hoverTask: Task<Void, Never>?
    /// Counts the hovers ended, so a first answer arriving late is known for stale.
    @ObservationIgnored private var hoverGeneration = 0
    @ObservationIgnored private var cardTask: Task<Void, Never>?
    @ObservationIgnored private var cardGeneration = 0

    /// Reads `model`'s radio, spectrum and decodes, and its IQ recorder's ring.
    func attach(to model: AppModel, recorder: StreamRecorder) {
        self.model = model
        sourceKind = { [weak model] in model?.sourceKind }
        snapshotProvider = { [recorder] in recorder.snapshot(lastSeconds: $0) }
        chunkProvider = { [recorder] in recorder.snapshot(lastSeconds: $0, chunkFrames: $1, $2) }
    }

    // MARK: Identify

    /// The signal at `atHz` (display Hz), or over `bandwidthHz` around it when given (an agent's), with traces within
    /// `radiusHz` of it under the point (nil: the identifier's default); nil when there is no data (an empty ring), when
    /// the radio retuned before it finished, when cancelled, or when a newer hover replaced it in the queue. `priority`:
    /// whose it is (see the type's notes).
    ///
    /// When the first pass asks for a longer read (or a look-back), `firstAnswer` is called with that pass's answer as
    /// soon as it is made (on the main actor, not after this call returned): the one to show, as measuring, while the
    /// rest runs. With `longerRead` false none is made (a stepped scan's ring holds only the first read): the first
    /// answer is returned, still wanting it.
    ///
    /// `tryDecode` (the card's and agents', never hover's, and not with `longerRead` false): when a trial decode
    /// applies (`SignalIDDecoding.plan`), the answer is given to `firstAnswer` and then decoded, a queued job of its own
    /// in the same lane, and the answer returned is the decoded one (`SignalIDDecoding.applied`); nil when the radio
    /// retuned or it was cancelled meanwhile. FT8 slots decoded are kept (`slotDecodes`): another point in the same slot
    /// and box uses them.
    func identify(atHz: Double, bandwidthHz: Double? = nil, radiusHz: Double? = nil, longerRead: Bool = true,
                  priority: SignalIDPriority = .background, tryDecode: Bool = false,
                  firstAnswer: (@MainActor (SignalIdentity) -> Void)? = nil) async -> SignalIdentity? {
        await identify(atHz: atHz, bandwidthHz: bandwidthHz, radiusHz: radiusHz, longerRead: longerRead,
                       priority: priority, hover: false, tryDecode: tryDecode, firstAnswer: firstAnswer)
    }

    /// `identify`, as a hover's when `hover` (a newer hover replaces it while it is queued).
    func identify(atHz: Double, bandwidthHz: Double? = nil, radiusHz: Double? = nil, longerRead: Bool = true,
                  priority: SignalIDPriority, hover: Bool, tryDecode: Bool = false,
                  firstAnswer: (@MainActor (SignalIdentity) -> Void)? = nil) async -> SignalIdentity? {
        guard let answer = await analysed(atHz: atHz, bandwidthHz: bandwidthHz, radiusHz: radiusHz,
                                          longerRead: longerRead, priority: priority, hover: hover,
                                          firstAnswer: firstAnswer) else { return nil }
        let state = tuning.current
        guard tryDecode, longerRead, !hover,
              let plan = SignalIDDecoding.plan(for: answer, centerHz: state.centerHz) else { return answer }
        // Out while the decode runs: nothing waits on it.
        firstAnswer?(answer)
        return await decoded(answer, plan: plan, state: state, priority: priority)
    }

    /// `answer`, measured in the tuning `state`, with its trial decode (`plan`): run on the executor in `priority`'s
    /// lane as an identification is (stopped for the owner and asked again, when a background one). Nil when the radio
    /// retuned or the caller was cancelled.
    private func decoded(_ answer: SignalIdentity, plan: SignalIDDecoding.Plan, state: TuneBarrier.State,
                         priority: SignalIDPriority) async -> SignalIdentity? {
        var again = false
        while true {
            let ticket = SignalIDQueue.Ticket(priority: priority, hover: false, again: again)
            guard await queue.turn(ticket) else { return nil }
            guard !Task.isCancelled, state == tuning.current else {
                queue.finished(ticket)
                return nil
            }
            let known = slotDecodes.filter { $0.state == state }
            let trueTime = sourceKind() == .sdrplay
            let chunks = chunkProvider, barrier = tuning, decoders = self.decoders
            let task = Task.detached(executorPreference: executor, priority: .userInitiated) {
                SignalIDDecoding.attempt(for: answer, plan: plan, state: state, trueTime: trueTime, known: known,
                                         chunks: chunks, barrier: barrier, decoders: decoders,
                                         cancelled: { Task.isCancelled })
            }
            ticket.cancel = { task.cancel() }
            if ticket.preempted { task.cancel() }
            let made = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
            queue.finished(ticket)
            if ticket.preempted, made == nil, !Task.isCancelled {
                again = true
                continue
            }
            guard !Task.isCancelled, let made, state == tuning.current else { return nil }
            if let slot = made.slot {
                let now = self.now()
                slotDecodes.removeAll {
                    $0.state != state
                        || now.timeIntervalSince($0.slotStart) > FT8Modem.slotSeconds + SignalIDDecoding.slotKeepSeconds
                        || ($0.slotStart == slot.slotStart && $0.dialHz == slot.dialHz)
                }
                slotDecodes.append(slot)
            }
            return SignalIDDecoding.applied(made, to: answer, centerHz: state.centerHz)
        }
    }

    /// The identification itself (`identify` without the trial decode).
    private func analysed(atHz: Double, bandwidthHz: Double?, radiusHz: Double?, longerRead: Bool,
                          priority: SignalIDPriority, hover: Bool,
                          firstAnswer: (@MainActor (SignalIdentity) -> Void)?) async -> SignalIdentity? {
        guard model != nil else { return nil }
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
        var again = false
        while true {
            if let hit = cached(atHz: atHz, bandwidthHz: bandwidthHz, radiusHz: radiusHz) { return hit }
            let ticket = SignalIDQueue.Ticket(priority: priority, hover: hover, again: again)
            guard await queue.turn(ticket) else { return nil }
            guard !Task.isCancelled, let model else {
                queue.finished(ticket)
                return nil
            }
            let request = Request(
                atHz: atHz, bandwidthHz: bandwidthHz, radiusHz: radiusHz, spectrum: model.spectrumSnapshot(),
                longer: longerRead, modelCenterHz: model.centerHz, trueTime: sourceKind() == .sdrplay,
                notAtFrequency: tuneFailedAt.map { now().timeIntervalSince($0) >= Self.notAtFrequencyGraceSeconds } ?? false,
                comb: knownComb(), lookBackReads: lookBackReads)
            let provider = snapshotProvider, chunks = chunkProvider, analysis = self.analysis, barrier = tuning
            let finder = combFinder
            let task = Task.detached(executorPreference: executor, priority: .userInitiated) {
                Self.run(request, provider: provider, chunks: chunks, analysis: analysis, combFinder: finder,
                         barrier: barrier, onFirst: onFirstAnswer)
            }
            ticket.cancel = { task.cancel() }
            if ticket.preempted { task.cancel() }   // the owner asked between its turn and its start
            let result = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
            queue.finished(ticket)
            // Stopped for the owner (it gave nothing): asked again while its caller waits.
            if ticket.preempted, result == nil, !Task.isCancelled {
                again = true
                continue
            }
            guard !Task.isCancelled, let result, result.state == tuning.current else { return nil }
            if let found = result.comb { combCache = (result.state, now(), found.reading) }
            return keep(result, atHz: atHz, bandwidthHz: bandwidthHz, radiusHz: radiusHz)
        }
    }

    /// A cached answer for the point, confirmed by any decode now (see the type's notes).
    private func cached(atHz: Double, bandwidthHz: Double?, radiusHz: Double?) -> SignalIdentity? {
        let now = self.now()
        let sequence = tuning.current.sequence
        cache.removeAll { $0.sequence != sequence || now.timeIntervalSince($0.at) > Self.cacheSeconds }
        guard let hit = cache.first(where: {
            $0.range.contains(atHz) && $0.bandwidthHz == bandwidthHz && $0.radiusHz == radiusHz
        }) else { return nil }
        return confirmed(hit.identity, centerHz: hit.centerHz, bandwidthHz: bandwidthHz, now: now)
    }

    /// The comb found for this tuning within `combSeconds`, if any was looked for, with the tuning it was found in.
    private func knownComb() -> KnownComb? {
        guard let known = combCache, known.state == tuning.current,
              now().timeIntervalSince(known.at) <= Self.combSeconds else { return nil }
        return KnownComb(state: known.state, reading: known.comb)
    }

    /// `result`'s answer, confirmed, and cached when it should be.
    private func keep(_ result: Outcome, atHz: Double, bandwidthHz: Double?, radiusHz: Double?) -> SignalIdentity {
        let identity = result.identity, state = result.state
        let answer = confirmed(identity, centerHz: state.centerHz, bandwidthHz: bandwidthHz, now: self.now())
        // Kept when it found an extent and had every read it asked for (a short ring's answer improves as it
        // fills), or when a decode settled it; over the extent. "No signal" and "Too weak" with every read (the
        // look-back's too), for the point alone (a poll of empty spectrum doesn't read it again); never "Too soon",
        // which the ring outgrows (nor the failed tune's note: neither had every read).
        let m = identity.measurement
        if m.occupiedBandwidthHz > 0 && (result.complete || answer.confirmedByDecode) {
            let centre = state.centerHz + m.offsetHz, half = max(m.occupiedBandwidthHz, m.bandwidth6dBHz) / 2
            cache.append(CacheEntry(range: min(centre - half, atHz)...max(centre + half, atHz),
                                    bandwidthHz: bandwidthHz, radiusHz: radiusHz, sequence: state.sequence,
                                    centerHz: state.centerHz, at: self.now(), identity: identity))
        } else if m.occupiedBandwidthHz == 0 && result.complete && identity.note != SignalIdentifier.tooSoonNote
                    && identity.note != SignalIdentifier.cancelledNote {
            cache.append(CacheEntry(range: atHz...atHz, bandwidthHz: bandwidthHz, radiusHz: radiusHz,
                                    sequence: state.sequence, centerHz: state.centerHz, at: self.now(),
                                    identity: identity))
        }
        return answer
    }

    /// Forgets every answer.
    func invalidateCache() { cache.removeAll() }

    /// Whether an `identify` call has returned (read on the main actor).
    @MainActor private final class Finished { var value = false }

    /// What `run` made of it: the answer, the tuning its IQ was heard in, whether it had every read it asked for (the
    /// first pass's 3 s, and the longer read or look-back when wanted), and the comb when it had to find it and it may
    /// be kept (found in that tuning, with 3 s and more of it in the ring).
    struct Outcome: Sendable {
        var identity: SignalIdentity
        var state: TuneBarrier.State
        var complete: Bool
        var comb: KnownComb? = nil
    }

    /// Whether the capture has a comb, once looked for (`comb` nil: none).
    struct CombReading: Sendable, Equatable {
        var comb: CaptureComb?
    }

    /// The comb as found in the tuning `state`: given to an analysis of IQ heard in that tuning only.
    struct KnownComb: Sendable, Equatable {
        var state: TuneBarrier.State
        var reading: CombReading
    }

    /// What `run` is asked, from the main actor.
    struct Request: Sendable {
        var atHz: Double
        var bandwidthHz: Double?
        var radiusHz: Double? = nil
        var spectrum: SpectrumSnapshot?
        var longer: Bool
        /// The display centre the model shows (see `firstRead`).
        var modelCenterHz: Double? = nil
        /// The ring's samples carry the time they were heard (the RSP's): the analysis gets it.
        var trueTime = false
        /// A tune failed over `notAtFrequencyGraceSeconds` ago: a point the IQ doesn't hold is `notAtFrequencyNote`.
        var notAtFrequency = false
        /// The capture's comb as already found, and the tuning it was found in; nil: find it.
        var comb: KnownComb? = nil
        /// The most reads a look-back makes (`lookBackMaxReads`).
        var lookBackReads = SignalIDService.lookBackMaxReads
    }

    /// `run` (the tests' form).
    nonisolated static func run(atHz: Double, bandwidthHz: Double?, spectrum: SpectrumSnapshot?, longer: Bool,
                                modelCenterHz: Double? = nil, provider: SnapshotProvider, chunks: ChunkProvider,
                                analysis: Analysis, barrier: TuneBarrier, whole: Bool = false,
                                onFirst: (@Sendable (SignalIdentity, TuneBarrier.State) -> Void)? = nil) -> Outcome? {
        run(Request(atHz: atHz, bandwidthHz: bandwidthHz, spectrum: spectrum, longer: longer, modelCenterHz: modelCenterHz),
            provider: provider, chunks: chunks, analysis: analysis,
            combFinder: { CaptureComb.find(spectrumDb: $0, sampleRate: $1, centerHz: $2) }, barrier: barrier,
            whole: whole, onFirst: onFirst)
    }

    /// The first read, the analysis and (on request, when `longer`) the longer read or the look-back: on the service's
    /// executor. Nil when there is no IQ, the radio retuned meanwhile, or the task was cancelled. `whole`: the first read
    /// is the whole capture whatever its rate (tests compare the two).
    nonisolated static func run(_ request: Request, provider: SnapshotProvider, chunks: ChunkProvider,
                                analysis: Analysis, combFinder: CombFinder, barrier: TuneBarrier,
                                whole wholeFirst: Bool = false,
                                onFirst: (@Sendable (SignalIdentity, TuneBarrier.State) -> Void)? = nil) -> Outcome? {
        let atHz = request.atHz, bandwidthHz = request.bandwidthHz
        var whole = wholeFirst
        var identity: SignalIdentity
        var read: FirstRead
        // The capture's comb: as found for this tuning, else found now (before the first read, so that read isn't held
        // meanwhile), on the app's spectrum of it or on the ring.
        var combFound: KnownComb?
        if request.comb == nil {
            combFound = findComb(spectrum: request.spectrum, provider: provider, chunks: chunks, barrier: barrier,
                                 finder: combFinder)
            guard !Task.isCancelled else { return nil }
        }
        // Only for IQ heard in the tuning it was found in.
        func combFor(_ state: TuneBarrier.State) -> CaptureComb? {
            [request.comb, combFound].compactMap { $0 }.first { $0.state == state }?.reading.comb
        }
        while true {
            // Held only here: a channel read again whole is let go first.
            guard !Task.isCancelled,
                  let first = firstRead(atHz: atHz, bandwidthHz: bandwidthHz, spectrum: request.spectrum, whole: whole,
                                        modelCenterHz: request.modelCenterHz, provider: provider, chunks: chunks,
                                        barrier: barrier) else { return nil }
            // A point outside the capture the IQ holds (a failed tune left it at the old centre): nothing to read.
            guard !first.iq.isEmpty || abs(atHz - first.state.centerHz) <= first.captureRate / 2 else {
                let note = request.notAtFrequency ? notAtFrequencyNote : SignalIdentifier.tooSoonNote
                let outside = SignalIdentity(measurement: SignalMeasurement(offsetHz: atHz - first.state.centerHz,
                                                                            family: .noise),
                                             note: note)
                return Outcome(identity: outside, state: first.state, complete: false)
            }
            let comb = combFor(first.state)
            identity = analysis(AnalysisInput(iq: first.iq, sampleRate: first.sampleRate,
                                              captureCenterHz: first.state.centerHz + first.offsetHz, atHz: atHz,
                                              bandwidthHz: bandwidthHz, spectrumDb: first.spectrumDb, longer: nil,
                                              pointRadiusHz: request.radiusHz,
                                              endTime: request.trueTime ? first.endTime : nil, comb: comb))
            guard !Task.isCancelled else { return nil }
            identity = recentred(identity, by: first.offsetHz, captureCenterHz: first.state.centerHz)
            // A signal wider than the channel was cut for is read again whole.
            if let window = first.channelHz, wider(identity, than: window) {
                whole = true
                continue
            }
            read = first
            break
        }
        let state = read.state, rate = read.sampleRate
        let comb = combFor(state)
        // Kept only when found in this tuning with 3 s of it in the ring (never from a read "Too soon" after a retune).
        let keptComb = combFound.flatMap { $0.state == state && !read.short ? $0 : nil }
        func outcome(_ identity: SignalIdentity, complete: Bool) -> Outcome {
            Outcome(identity: identity, state: state, complete: complete, comb: keptComb)
        }
        // Less than the 3 s asked for (but enough to measure): said in the note.
        let readSeconds = Double(read.frames) / rate
        if read.short && readSeconds >= SignalIdentifier.minimumSeconds {
            add(String(format: "Read %.1f s of the %.0f s asked for", readSeconds, firstSeconds), to: &identity)
        }
        let silent = isSilent(identity)
        guard request.longer, wantsLongerRead(identity) || (silent && !read.short) else {
            return outcome(identity, complete: !read.short && !wantsLongerRead(identity))
        }

        // The longer read (or the look-back), on the channel around what the first pass measured (or the point); the
        // first answer is out meanwhile.
        onFirst?(identity, state)
        read.iq = []   // not held through the longer read
        if silent {
            switch lookBack(request: request, state: state, firstEnd: read.endTime, firstEndFrame: read.endFrame,
                            sampleRate: read.captureRate, comb: comb, provider: provider, chunks: chunks,
                            analysis: analysis, barrier: barrier) {
            case .dropped:
                return nil
            case .unavailable(let why):
                add(why, to: &identity)
                return outcome(identity, complete: false)
            case .answer(let found, let complete):
                return outcome(found, complete: complete)
            }
        }
        let m = identity.measurement
        switch longerRead(offsetHz: m.offsetHz, widthHz: max(m.occupiedBandwidthHz, bandwidthHz ?? 0),
                          tuning: state, sampleRate: read.captureRate, chunks: chunks, barrier: barrier) {
        case .dropped:
            return nil
        case .unavailable(let why):
            add(why, to: &identity)
            return outcome(identity, complete: false)
        case .read(let long):
            let refined = analysis(AnalysisInput(iq: long.iq, sampleRate: long.sampleRate,
                                                 captureCenterHz: state.centerHz + long.offsetHz, atHz: atHz,
                                                 bandwidthHz: bandwidthHz, spectrumDb: nil, longer: { (long.iq, long.seconds) },
                                                 pointRadiusHz: request.radiusHz,
                                                 endTime: request.trueTime ? long.endTime : nil, comb: comb))
            guard !Task.isCancelled else { return nil }
            return outcome(recentred(refined, by: long.offsetHz, captureCenterHz: state.centerHz),
                           complete: !refined.needsLongerRead)
        }
    }

    /// The first pass wants the longer read: for its own signal, or for one under the point it measured but couldn't name
    /// on 3 s (an FT8 group's members read `unknown` until their tones are read).
    nonisolated static func wantsLongerRead(_ identity: SignalIdentity) -> Bool {
        identity.needsLongerRead || identity.signals.contains {
            $0.needsLongerRead && $0.best == nil && !$0.nameInherited && $0.measurement.family == .unknown
        }
    }

    /// Nothing at the point: "No signal" (and nothing more said: a short read's adds its note).
    nonisolated static func isSilent(_ identity: SignalIdentity) -> Bool {
        identity.note == SignalIdentifier.noSignalNote
    }

    /// The note when the look-back's read failed: the newest 3 s are all there is.
    nonisolated static let lookBackFailedNote = "The look-back read failed; this is the newest 3 s alone"

    /// The note on what a look-back found, its window ending `seconds` before the first read did.
    nonisolated static func silentFor(_ seconds: Double) -> String {
        String(format: "Nothing to identify in the last %.0f s; this is what was on before then", seconds)
    }

    /// Each look-back read reaches this far past what it is for at its old end (the ring moving on between where it was
    /// last seen to end and the read).
    nonisolated static let lookBackMarginSeconds = 0.25
    /// A look-back reaching back this much short of `longSeconds` covered them (a ring of exactly 16 s, its settle and
    /// the margin taken off).
    nonisolated static let lookBackToleranceSeconds = 0.5
    /// The most reads one look-back makes (one at 10 MS/s, two at 6: a guard).
    nonisolated static let lookBackMaxReads = 6
    /// The channel extractor reserves its output with a frame per stage and one more over the input's share.
    nonisolated static let lookBackSlackFrames = 16

    /// The note when a look-back made `lookBackMaxReads` reads and hadn't covered its span.
    nonisolated static func lookBackStopped(after reads: Int) -> String {
        "The look-back stopped after \(reads) read\(reads == 1 ? "" : "s")"
    }

    #if DEBUG
    /// Test hook: how many times a look-back's read was copied to be trimmed (never, when it is handed over), and the
    /// most floats one of its reads reserved.
    nonisolated static let lookBackStats = Mutex((copies: 0, reads: 0, mostFloats: 0))
    #endif

    /// How a look-back went.
    enum LookBackOutcome: Sendable {
        case answer(SignalIdentity, complete: Bool)
        /// None to be had: why, for the answer's note.
        case unavailable(String)
        /// Cancelled, or the radio retuned: the answer is dropped.
        case dropped
    }

    /// The look-back (see the type's notes): what was at the point in the `longSeconds` before the first read ended
    /// (`firstEnd`, `firstEndFrame`). That span is fixed when it starts, in sample time: by where the reads end in the
    /// ring (`endFrame`), right whether the radio runs or is stopped; by their end times when the ring doesn't say.
    ///
    /// Its windows end `firstSeconds`, 2 × … before the first read's end, each analysed with what came before it in its
    /// read as its longer read, and its own end time. They are read in turn off the ring as a channel around the point
    /// (`channelRead`), each read as much as `longReadBudgetBytes` holds of it (less the margin, the settle and the
    /// extractor's slack): placed against the fixed span from where the ring ends just before it (probed), and handed
    /// over to be trimmed in place, window by window: never copied. A window the ring has moved past part of (or that
    /// reaches its start) is analysed with what it holds, `minimumSeconds` at least.
    ///
    /// The first window whose answer has an extent is the answer, recentred, saying how long nothing was there to
    /// identify; with none, "No signal": complete when its windows covered the span (`lookBackToleranceSeconds` short at
    /// most), or all the ring held since the retune, which it says. `unavailable` after `lookBackReads` reads, or a read
    /// that failed; `dropped` when the radio retuned or it was cancelled.
    nonisolated static func lookBack(request: Request, state: TuneBarrier.State, firstEnd: Date, firstEndFrame: Int?,
                                     sampleRate: Double, comb: CaptureComb?, provider: SnapshotProvider,
                                     chunks: ChunkProvider, analysis: Analysis,
                                     barrier: TuneBarrier) -> LookBackOutcome {
        let pointHz = request.atHz - state.centerHz
        let windowHz = max(minimumChannelHz, channelWidths * (request.bandwidthHz ?? 0))
        let rate = Channel.outputRate(sampleRate: sampleRate, bandwidthHz: windowHz)
        // What one read holds: the budget (less the extractor's few frames of slack: `lookBackSlackFrames`), less the
        // margin and the settle it reads on top.
        let room = Double(longReadBudgetBytes / 8 - lookBackSlackFrames) / rate - lookBackMarginSeconds - settleSeconds
        guard room >= firstSeconds + SignalIdentifier.minimumSeconds else {
            return .unavailable(String(format: "No look-back: a %.0f kHz channel is too wide for one", windowHz / 1000))
        }
        // Positions on the ring, in seconds: sample time when the reads say where they end, else their end times.
        let byFrames = firstEndFrame != nil
        func position(_ frame: Int?, _ time: Date) -> Double? {
            byFrames ? frame.map { Double($0) / sampleRate } : time.timeIntervalSinceReferenceDate
        }
        guard let end0 = position(firstEndFrame, firstEnd) else { return .unavailable(lookBackFailedNote) }
        let oldest = end0 - longSeconds
        var backs = Array(stride(from: firstSeconds, through: longSeconds - SignalIdentifier.minimumSeconds,
                                 by: firstSeconds))
        // Where the ring ends as last seen; where it starts once a read reached that; how far back the windows analysed
        // reached.
        var known = end0
        var start: Double?
        var covered = firstSeconds
        var reads = 0
        pastReads: while let first = backs.first {
            guard reads < request.lookBackReads else { return .unavailable(lookBackStopped(after: reads)) }
            // Where the ring ends now, just before the read.
            if byFrames {
                guard let probe = provider(probeSeconds), probe.sampleRate == sampleRate, let frame = probe.endFrame,
                      barrier.current == state else { return barrier.current == state ? .unavailable(lookBackFailedNote) : .dropped }
                known = max(known, Double(frame) / sampleRate)
            }
            // From the first window not yet analysed back as far as one read holds.
            let newer = end0 - first
            let span = min(newer - oldest, room)
            let older = newer - span
            reads += 1
            switch channelRead(seconds: known - older + lookBackMarginSeconds, offsetHz: pointHz,
                               windowHz: windowHz, tuning: state, sampleRate: sampleRate, chunks: chunks,
                               barrier: barrier, feedSeconds: span + lookBackMarginSeconds) {
            case .dropped:
                return .dropped
            case .failed:
                return .unavailable(lookBackFailedNote)
            case .read(var segment):
                // Handed over: `segment` lets go of it, so trimming it doesn't copy it.
                var iq = segment.iq
                segment.iq = []
                guard let end = position(segment.endFrame, segment.endTime),
                      let readEnd = position(segment.readEndFrame, segment.readEndTime) else {
                    return .unavailable(lookBackFailedNote)
                }
                known = max(known, readEnd)
                let readStart = end - segment.seconds
                if segment.reachedStart { start = readStart }
                #if DEBUG
                lookBackStats.withLock { $0.reads += 1; $0.mostFloats = max($0.mostFloats, segment.reservedFloats) }
                let base = iq.withUnsafeBufferPointer { $0.baseAddress }
                #endif
                while let back = backs.first {
                    let windowEnd = end0 - back
                    let held = windowEnd - readStart   // this window and what came before it, in this read
                    let window = min(firstSeconds, windowEnd - oldest)
                    if held < window - settleSeconds {
                        // A window this read wasn't placed to hold is the next read's.
                        if windowEnd - window < older - settleSeconds, !segment.reachedStart { continue pastReads }
                        // One the ring has moved past part of, or that reaches its start: what it holds, if enough.
                        guard held >= SignalIdentifier.minimumSeconds else {
                            if segment.reachedStart { break pastReads }   // nothing older
                            backs.removeFirst()
                            continue
                        }
                    }
                    let keep = min(iq.count / 2, Int((held * rate).rounded()))
                    iq.removeLast(iq.count - 2 * keep)
                    #if DEBUG
                    if iq.withUnsafeBufferPointer({ $0.baseAddress }) != base { lookBackStats.withLock { $0.copies += 1 } }
                    #endif
                    guard !Task.isCancelled, barrier.current == state else { return .dropped }
                    let before = iq, seconds = Double(keep) / rate
                    let found = analysis(AnalysisInput(iq: before, sampleRate: rate,
                                                       captureCenterHz: state.centerHz + segment.offsetHz,
                                                       atHz: request.atHz, bandwidthHz: request.bandwidthHz,
                                                       spectrumDb: nil, longer: { (before, seconds) },
                                                       pointRadiusHz: request.radiusHz,
                                                       endTime: request.trueTime ? firstEnd.addingTimeInterval(-back) : nil,
                                                       comb: comb))
                    guard !Task.isCancelled, barrier.current == state else { return .dropped }
                    // How far back a window's own data reached (what came before it is read only for a signal).
                    covered = max(covered, back + min(seconds, window))
                    // Only something measured stops it ("Too weak" is no past signal to show).
                    if found.measurement.occupiedBandwidthHz > 0 || !found.signals.isEmpty {
                        var answer = recentred(found, by: segment.offsetHz, captureCenterHz: state.centerHz)
                        // One note: what it found and when, not also what the window's own longer read held.
                        let said = (found.note ?? "").components(separatedBy: "; ").filter {
                            !$0.isEmpty && !($0.hasPrefix("Read ") && $0.hasSuffix(" s asked for"))
                        }
                        answer.note = (said + [silentFor(back)]).joined(separator: "; ")
                        return .answer(answer, complete: !found.needsLongerRead)
                    }
                    backs.removeFirst()
                }
                if segment.reachedStart { break pastReads }
            }
        }
        var none = SignalIdentity(measurement: SignalMeasurement(offsetHz: pointHz, family: .noise),
                                  note: SignalIdentifier.noSignalNote)
        // Covered against the fixed span; short of it, all the ring held since the retune (said), or not complete.
        guard covered < longSeconds - lookBackToleranceSeconds else { return .answer(none, complete: true) }
        let looked = String(format: "Looked back %.1f s of the %.0f s asked for", covered, longSeconds)
        if start != nil {
            none.note = SignalIdentifier.noSignalNote + "; " + looked
            return .answer(none, complete: true)
        }
        none.note = SignalIdentifier.noSignalNote + "; " + looked + ": the ring moved on"
        return .answer(none, complete: false)
    }

    /// `identity`, from a read centred `offsetHz` from the capture's centre `captureCenterHz`, in the capture's frame:
    /// its measurement, and each of its signals' and its group's span, moved by `offsetHz`, so that all of them are
    /// relative to `captureCenterHz`, which a group answer then says (`captureCenterHz`).
    nonisolated static func recentred(_ identity: SignalIdentity, by offsetHz: Double,
                                      captureCenterHz: Double) -> SignalIdentity {
        var out = identity
        out.measurement.offsetHz += offsetHz
        guard !out.signals.isEmpty || out.groupSpanHz != nil || out.captureCenterHz != nil else { return out }
        for k in out.signals.indices { out.signals[k].measurement.offsetHz += offsetHz }
        out.groupSpanHz = out.groupSpanHz.map { ($0.lowerBound + offsetHz)...($0.upperBound + offsetHz) }
        out.captureCenterHz = captureCenterHz
        return out
    }

    /// The capture's comb, found in the tuning it returns: on the app's spectrum of the capture (`appSpectrum`) when it
    /// has one, else on `combReadSeconds` (`combFrames` at most) of the ring's newest IQ, read a piece at a time. A read
    /// that reaches back to the retune barrier (shorter than asked for, with its `settleSeconds`) finds none and is
    /// looked for again next time (nil), as is one cut by a retune or failed.
    nonisolated static func findComb(spectrum: SpectrumSnapshot?, provider: SnapshotProvider, chunks: ChunkProvider,
                                     barrier: TuneBarrier, finder: CombFinder) -> KnownComb? {
        let state = barrier.current
        guard state.sequence % 2 == 0, let probe = provider(probeSeconds), probe.sampleRate > 0,
              barrier.current == state else { return nil }
        let rate = probe.sampleRate, centre = state.centerHz
        if let db = appSpectrum(spectrum, state: state, rate: rate) {
            return KnownComb(state: state, reading: CombReading(comb: finder(db, rate, centre)))
        }
        let frames = min(combFrames, Int((combReadSeconds * rate).rounded()))
        guard frames >= CaptureComb.spectrumSize else { return KnownComb(state: state, reading: CombReading(comb: nil)) }
        let asked = frames + Int((settleSeconds * rate).rounded())
        var iq: [Float] = []
        iq.reserveCapacity(2 * asked)
        let read = chunks(Double(asked) / rate, min(Int(chunkSeconds * rate), maxChunkFrames)) { piece in
            guard !Task.isCancelled else { return false }
            iq.append(contentsOf: piece.prefix(2 * asked - iq.count))
            return true
        }
        guard !Task.isCancelled, barrier.current == state, let read, read.sampleRate == rate, read.frames >= asked,
              iq.count == 2 * asked else { return nil }
        iq.removeFirst(iq.count - 2 * frames)   // the newest `frames`
        return KnownComb(state: state, reading: CombReading(comb: finder(CaptureComb.spectrum(iq: iq), rate, centre)))
    }

    /// The app's averaged spectrum when it is of the capture the ring holds in `state` at `rate`.
    nonisolated static func appSpectrum(_ spectrum: SpectrumSnapshot?, state: TuneBarrier.State, rate: Double) -> [Float]? {
        spectrum.flatMap { s in
            abs(s.centerHz - state.centerHz) < 0.5 && abs(s.spanHz - rate) < 0.5 && s.average.count >= 8 ? s.average : nil
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
        /// When its last sample was heard.
        var endTime: Date
        /// Where it ends in the ring (`IQSnapshot.endFrame`), when known.
        var endFrame: Int? = nil
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
            let appDb = appSpectrum(spectrum, state: state, rate: rate)
            let pointHz = atHz - state.centerHz
            // A point the IQ doesn't hold, while the IQ is another capture's than the model shows (a tune that
            // failed): nothing read (`run` answers it).
            guard abs(pointHz) <= rate / 2 || modelCenterHz.map({ abs($0 - state.centerHz) < 1 }) ?? true else {
                return FirstRead(iq: [], sampleRate: rate, offsetHz: 0, channelHz: nil, captureRate: rate,
                                 spectrumDb: nil, short: true, state: state, endTime: probe.endTime)
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
                                     short: channel.iq.count / 2 < asked, state: state,
                                     endTime: channel.endTime, endFrame: channel.endFrame)
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
                             spectrumDb: appDb, short: keep < Int((firstSeconds * rate).rounded()),
                             state: state, endTime: snapshot.endTime, endFrame: snapshot.endFrame)
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
        /// When its last sample was heard (the read's `IQRead.endTime`, less what it skipped: `channelRead`'s
        /// `feedSeconds`).
        var endTime: Date
        /// When the ring's newest sample was heard as it was read (`IQRead.endTime`).
        var readEndTime: Date
        /// Where its last sample, and the ring's newest as it was read, lie in the ring (`IQRead.endFrame`), when known.
        var endFrame: Int? = nil
        var readEndFrame: Int? = nil
        /// It reached back to the ring's start or the retune barrier: the ring held less than asked for.
        var reachedStart = false
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
                                        barrier: TuneBarrier, feedSeconds: Double? = nil) -> ChannelReadOutcome {
        guard barrier.current == tuning, sampleRate > 0 else { return .dropped }
        let decimates = !DecimationPlan.stages(inputRate: sampleRate,
                                               minimumRate: max(4 * windowHz, Channel.minimumRate)).isEmpty
        let extractor = decimates ? ChannelExtractor(sampleRate: sampleRate, offsetHz: offsetHz,
                                                     bandwidthHz: windowHz, sharp: false) : nil
        let whole = extractor == nil
        let rate = extractor?.rate ?? sampleRate
        let asked = seconds + settleSeconds
        let askedFrames = Int((asked * sampleRate).rounded())
        // Only the oldest `feedSeconds` of what is read are kept (the rest is visited, not held).
        let feedFrames = feedSeconds.map { min(askedFrames, Int((($0 + settleSeconds) * sampleRate).rounded())) }
            ?? askedFrames
        var copied: [Float] = []
        if let extractor { extractor.reserve(inputFrames: feedFrames) } else { copied.reserveCapacity(2 * feedFrames) }
        var fed = 0
        let read = chunks(asked, min(Int(chunkSeconds * sampleRate), maxChunkFrames)) { piece in
            guard !Task.isCancelled else { return false }
            let room = 2 * (feedFrames - fed)
            guard room > 0 else { return true }
            let part = piece.count <= room ? piece : UnsafeBufferPointer(rebasing: piece[0..<room])
            if let extractor { extractor.feed(part) } else { copied.append(contentsOf: part) }
            fed += part.count / 2
            return true
        }
        guard !Task.isCancelled, barrier.current == tuning else { return .dropped }
        guard let read, read.sampleRate == sampleRate else { return .failed }
        let reserved = extractor?.reservedFloats ?? 2 * feedFrames
        let grew = extractor?.outgrewReservation ?? (copied.count > reserved)
        var iq = extractor?.finish().samples ?? copied
        // The oldest `settleSeconds` of a read reaching back to the barrier, and anything over what was asked.
        let reachedStart = read.frames < askedFrames
        let settle = reachedStart ? Int((settleSeconds * rate).rounded()) : 0
        let keep = max(0, min(iq.count / 2 - settle, Int(((feedSeconds ?? seconds) * rate).rounded())))
        iq.removeFirst(iq.count - 2 * keep)
        let skipped = Double(read.frames - fed) / sampleRate
        return .read(LongRead(iq: iq, sampleRate: rate, offsetHz: whole ? 0 : offsetHz, seconds: Double(keep) / rate,
                              endTime: read.endTime.addingTimeInterval(-skipped), readEndTime: read.endTime,
                              endFrame: read.endFrame.map { $0 - (read.frames - fed) }, readEndFrame: read.endFrame,
                              reachedStart: reachedStart, reservedFloats: reserved, grew: grew))
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
        case .ft8: "FT8"
        case .wspr: "WSPR"
        }
    }

    // MARK: Hover

    /// The radius hover and card ask within at a zoom of `hzPerPoint` (nil: the identifier's default).
    static func radiusHz(hzPerPoint: Double?) -> Double? {
        hzPerPoint.flatMap { $0 > 0 && $0.isFinite ? radiusPixels * $0 : nil }
    }

    /// The pointer rests at `point` (view points) over `hz` (display Hz), the view showing `hzPerPoint` (nil: not
    /// known) a point: the owner's, within `radiusPixels` of it.
    func hover(at point: CGPoint, hz: Double, hzPerPoint: Double? = nil) {
        if let anchor = hoverAnchor, hypot(point.x - anchor.x, point.y - anchor.y) <= Self.moveTolerance { return }
        endHover()
        hoverAnchor = point
        let generation = hoverGeneration
        hoverTask = Task { [weak self] in
            guard let dwell = self?.dwell else { return }
            await dwell()
            guard !Task.isCancelled, let self else { return }
            hoverPending = true
            let identity = await identify(atHz: hz, radiusHz: Self.radiusHz(hzPerPoint: hzPerPoint), priority: .owner,
                                          hover: true) { [weak self] first in
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
    /// a longer read follows: the owner's, within `radiusPixels` of it at `hzPerPoint` (nil: not known). Replaces any
    /// open card; the hover's answer is cleared (the card is the answer now).
    func openCard(at point: CGPoint, hz: Double, hzPerPoint: Double? = nil) {
        closeCard()
        endHover()
        let generation = cardGeneration
        card = Card(id: generation, point: point, hz: hz, signalHz: hz)
        cardTask = Task { [weak self] in
            guard let self else { return }
            let identity = await identify(atHz: hz, radiusHz: Self.radiusHz(hzPerPoint: hzPerPoint),
                                          priority: .owner, tryDecode: true) { [weak self] first in
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
    /// centre, which `notAtFrequencyNote` says after its grace). Forgets the answers and the pointer's.
    func retuned(displayCenterHz: Double?) {
        tuning.end(centerHz: displayCenterHz)
        tuneFailedAt = displayCenterHz == nil ? now() : nil
        cache.removeAll()
        combCache = nil
        slotDecodes.removeAll()
        endHover()
    }
}
