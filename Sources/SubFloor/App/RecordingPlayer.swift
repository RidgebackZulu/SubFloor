import AVFoundation
import DSPCore
import Foundation
import Observation
import Recording

/// Plays one recording from the Recordings window, and keeps the live radio quiet while it does, so the two
/// are never heard together. The library's recordings are the only thing it opens, and it never changes one;
/// the only write is the library's `heard` line.
///
/// Playback is an `AVAudioEngine`: an `AVAudioPlayerNode` over the file (so WAV, FLAC and M4A all play), a
/// mixer that turns it into 48 kHz mono, the noise reducer (`NoiseReductionAudioUnit`), and the main mixer,
/// whose volume is the main knob. The position is read from the player node at 30 Hz while it plays; nothing
/// runs when it is paused. The end comes from the segment's completion handler, or from that poll if the
/// engine stops without saying so.
@MainActor @Observable
final class RecordingPlayer {
    /// The seconds one step of the position control moves: the arrow keys now, a hardware dial later.
    static let jumpSizes: [Double] = [0.1, 0.5, 1, 5, 30, 300]

    /// One of `jumpSizes`.
    var jump: Double = 1
    /// 0...1, the main volume knob: `AppModel` sets it when the knob moves.
    var volume: Float = 0.5 { didSet { if graph != nil { engine.mainMixerNode.outputVolume = volume } } }
    /// The user's noise-reduction setting, from `AppModel`. It applies only where the loaded recording's mode
    /// allows (`noiseReductionAvailable`).
    var noiseReduction = NoiseReductionSettings() { didSet { pushNoiseReduction() } }

    private(set) var file: String?
    /// The loaded recording's first sample.
    private(set) var start: Date?
    /// 0 when nothing is loaded, or the file could not be opened.
    private(set) var duration: Double = 0
    /// Seconds into the file.
    private(set) var position: Double = 0
    private(set) var isPlaying = false
    /// "Can't play this file" when the loaded file could not be opened or played.
    private(set) var loadError: String?
    /// Whether noise reduction can apply to what is loaded: a file that opened, recorded in a known mode that
    /// is not WFM.
    private(set) var noiseReductionAvailable = false

    /// The moment in the recording's own time that is playing: when it started, plus the position.
    var playheadTime: Date? { start.map { $0.addingTimeInterval(position) } }

    /// Internal for tests, which stop it behind the player's back or render it offline.
    let engine = AVAudioEngine()
    /// Internal for tests: the effect, once the first file has been opened.
    var noiseReductionUnit: NoiseReductionAudioUnit? { graph?.unit }

    private let library: RecordingsLibrary
    private let setLiveMuted: (Bool) -> Void

    /// The nodes, built when the first file opens, so a player that is never used never touches audio.
    private struct Graph {
        let player: AVAudioPlayerNode
        /// To 48 kHz mono, the only format the reducer takes.
        let converter: AVAudioMixerNode
        let effect: AVAudioUnitEffect
        let unit: NoiseReductionAudioUnit
    }

    @ObservationIgnored private var graph: Graph?
    @ObservationIgnored private var audioFile: AVAudioFile?
    /// The file frame the scheduled segment starts at: the player node counts from 0 at each `play()`.
    @ObservationIgnored private var segmentStartFrame: AVAudioFramePosition = 0
    /// Bumped whenever the scheduled segment stops counting (a seek, pause, load or unload), so the
    /// completion handler of a segment that was stopped does nothing.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var nrAllowed = false
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var configurationObserver: NotificationObserver?
    /// The folder the file was opened from, so another recordings folder (which may hold a file of the same
    /// name) does not leave the old one loaded.
    @ObservationIgnored private var loadedFolder: URL?
    @ObservationIgnored private var liveIsMuted = false

    init(library: RecordingsLibrary, setLiveMuted: @escaping (Bool) -> Void) {
        self.library = library
        self.setLiveMuted = setLiveMuted
    }

    /// Stops what was loaded and opens `recording` at 0. A recording in progress is still being written, so it
    /// is not loaded at all. A file that cannot be opened stays loaded, with `loadError` set, so the window
    /// can say which one it was.
    func load(_ recording: CatalogRecording) {
        unload()
        guard !recording.inProgress else { return }
        file = recording.file
        start = recording.start
        loadedFolder = library.folder
        do {
            let audioFile = try AVAudioFile(forReading: library.url(for: recording.file))
            let rate = audioFile.processingFormat.sampleRate
            guard audioFile.length > 0, rate > 0 else { throw CocoaError(.fileReadCorruptFile) }
            let graph = try self.graph ?? makeGraph()
            self.graph = graph
            // The engine is stopped (`unload`): the connection and the fresh reducer cannot race the render thread.
            engine.disconnectNodeOutput(graph.player)
            engine.connect(graph.player, to: graph.converter, fromBus: 0, toBus: 0, format: audioFile.processingFormat)
            graph.unit.resetReducer()
            self.audioFile = audioFile
            duration = Double(audioFile.length) / rate
            nrAllowed = DemodMode(rawValue: recording.mode.lowercased()).map(NoiseReductionSettings.isAvailable(for:)) ?? false
            noiseReductionAvailable = nrAllowed
            pushNoiseReduction()
        } catch {
            loadError = Self.cannotPlay
        }
    }

    /// Nothing loaded, nothing playing, live audio back.
    func unload() {
        stopTimer()
        generation += 1
        if let graph {
            graph.player.stop()
            engine.stop()
        }
        audioFile = nil
        file = nil
        start = nil
        loadedFolder = nil
        duration = 0
        position = 0
        isPlaying = false
        loadError = nil
        nrAllowed = false
        noiseReductionAvailable = false
        pushNoiseReduction()
        muteLive(false)
    }

    /// Marks the recording heard, silences the live radio and plays from the position. From the end it starts
    /// over, as a player does.
    func play() {
        guard let graph, audioFile != nil, let file, !isPlaying else { return }
        if position >= duration { position = 0 }
        do {
            // Before the node plays: a player node started in an engine that is not running throws.
            if !engine.isRunning { try engine.start() }
        } catch {
            loadError = Self.cannotPlay
            return
        }
        schedule(from: position)
        graph.player.play()
        isPlaying = true
        muteLive(true)
        library.markHeard(file)
        startTimer()
    }

    func pause() {
        guard let graph, isPlaying else { return }
        if let at = playedSeconds() { position = min(at, duration) }
        // The engine first, so the reducer sees no silence and keeps its noise estimate for the resume.
        engine.pause()
        generation += 1
        graph.player.stop()
        isPlaying = false
        stopTimer()
        muteLive(false)
    }

    func togglePlay() { isPlaying ? pause() : play() }

    /// To `seconds`, kept within the file. Playing carries on from there; the reducer keeps its noise estimate.
    func seek(to seconds: Double) {
        guard let graph, audioFile != nil, seconds.isFinite else { return }
        position = min(max(seconds, 0), duration)
        guard isPlaying else { return }
        // Stopped by itself, and not yet noticed: a node played in a stopped engine throws.
        guard engine.isRunning else { return stoppedBehindOurBack() }
        guard position < duration else { return finishedAtTheEnd() }
        schedule(from: position)
        graph.player.play()
    }

    func move(jumps n: Int) { seek(to: position + Double(n) * jump) }

    /// Called whenever the library changes: the file it was playing may be gone (deleted in Finder), or the
    /// recordings folder may be another one.
    func reconcile(with catalog: RecordingsCatalog) {
        guard let file else { return }
        if !catalog.files.contains(file) || library.folder != loadedFolder { unload() }
    }

    // MARK: Private

    /// Also what the window says for a file whose peaks cannot be read: to the listener it is the same file.
    nonisolated static let cannotPlay = "Can't play this file"

    private func makeGraph() throws -> Graph {
        NoiseReductionAudioUnit.registered
        let effect = AVAudioUnitEffect(audioComponentDescription: NoiseReductionAudioUnit.componentDescription)
        guard let unit = effect.auAudioUnit as? NoiseReductionAudioUnit else { throw CocoaError(.featureUnsupported) }
        let player = AVAudioPlayerNode(), converter = AVAudioMixerNode()
        for node in [player, converter, effect] { engine.attach(node) }
        engine.connect(converter, to: effect, format: NoiseReductionAudioUnit.format)
        engine.connect(effect, to: engine.mainMixerNode, format: NoiseReductionAudioUnit.format)
        engine.mainMixerNode.outputVolume = volume
        // The engine stops itself when the output device changes (or goes away), and says so here.
        configurationObserver = NotificationObserver(name: .AVAudioEngineConfigurationChange, object: engine) { [weak self] in
            guard let self, !self.engine.isRunning else { return }
            self.stoppedBehindOurBack()
        }
        return Graph(player: player, converter: converter, effect: effect, unit: unit)
    }

    /// What the effect applies: the setting where the loaded recording's mode allows it, else off (keeping the
    /// strength, so a later file in another mode comes back at the same one).
    private func pushNoiseReduction() {
        var effective = noiseReduction
        effective.enabled = noiseReduction.enabled && nrAllowed
        graph?.unit.requested = effective
    }

    /// Stops the node, and queues the rest of the file from `seconds`; the caller plays it.
    private func schedule(from seconds: Double) {
        guard let graph, let audioFile else { return }
        generation += 1
        graph.player.stop()
        let rate = audioFile.processingFormat.sampleRate
        let first = min(max(AVAudioFramePosition(seconds * rate), 0), audioFile.length)
        segmentStartFrame = first
        let frames = AVAudioFrameCount(clamping: audioFile.length - first)
        guard frames > 0 else { return }
        let generation = generation
        graph.player.scheduleSegment(audioFile, startingFrame: first, frameCount: frames, at: nil,
                                     completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.generation == generation, self.isPlaying else { return }
                    self.finishedAtTheEnd()
                }
            }
        }
    }

    /// Seconds into the file the node has played, or nil when it is not rendering.
    private func playedSeconds() -> Double? {
        guard let graph, let audioFile, let now = graph.player.lastRenderTime, now.isSampleTimeValid,
              let played = graph.player.playerTime(forNodeTime: now) else { return nil }
        return Double(segmentStartFrame + max(played.sampleTime, 0)) / audioFile.processingFormat.sampleRate
    }

    private func muteLive(_ muted: Bool) {
        guard muted != liveIsMuted else { return }
        liveIsMuted = muted
        setLiveMuted(muted)
    }

    /// The segment played to the end of the file.
    private func finishedAtTheEnd() {
        generation += 1
        // Paused rather than left running on silence: the reducer keeps its noise estimate for a replay.
        engine.pause()
        graph?.player.stop()
        stopTimer()
        isPlaying = false
        position = duration
        muteLive(false)
    }

    /// The engine stopped without the player asking (an output device that went away can do that): paused
    /// where it was, so the live radio is not left muted.
    private func stoppedBehindOurBack() {
        guard isPlaying else { return }
        generation += 1
        graph?.player.stop()
        stopTimer()
        isPlaying = false
        muteLive(false)
    }

    /// 30 Hz, in the common run loop modes so the position keeps moving during menu tracking or a live resize.
    private func startTimer() {
        stopTimer()
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard isPlaying else { return }
        guard engine.isRunning else { return stoppedBehindOurBack() }
        guard let at = playedSeconds() else { return }
        // The completion handler ends playback; a second past the end without it, the poll does.
        if at >= duration + 1 { return finishedAtTheEnd() }
        position = min(at, duration)
    }

    /// A block observer that is removed with its owner.
    private final class NotificationObserver {
        private let token: NSObjectProtocol

        init(name: Notification.Name, object: AnyObject, onMain handler: @escaping @MainActor () -> Void) {
            token = NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { _ in
                MainActor.assumeIsolated { handler() }
            }
        }

        deinit { NotificationCenter.default.removeObserver(token) }
    }
}
