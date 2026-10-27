import AVFoundation
import Foundation
import Observation
import Recording

/// Plays one recording from the Recordings window, and keeps the live radio quiet while it does, so the two
/// are never heard together. The library's recordings are the only thing it opens, and it never changes one;
/// the only write is the library's `heard` line.
///
/// Playback is `AVAudioPlayer` over the file, so WAV, FLAC and M4A all play. The position is read from the
/// player at 30 Hz while it plays; nothing runs when it is paused.
@MainActor @Observable
final class RecordingPlayer {
    /// The seconds one step of the position control moves: the arrow keys now, a hardware dial later.
    static let jumpSizes: [Double] = [0.1, 0.5, 1, 5, 30, 300]

    /// One of `jumpSizes`.
    var jump: Double = 1
    /// 0...1, the main volume knob: `AppModel` sets it when the knob moves.
    var volume: Float = 0.5 { didSet { audio?.volume = volume } }

    private(set) var file: String?
    /// The loaded recording's first sample.
    private(set) var start: Date?
    /// 0 when nothing is loaded, or the file could not be opened.
    private(set) var duration: Double = 0
    /// Seconds into the file.
    private(set) var position: Double = 0
    private(set) var isPlaying = false
    /// "Can't play this file" when the loaded file could not be opened or stopped decoding.
    private(set) var loadError: String?

    /// The moment in the recording's own time that is playing: when it started, plus the position.
    var playheadTime: Date? { start.map { $0.addingTimeInterval(position) } }

    private let library: RecordingsLibrary
    private let setLiveMuted: (Bool) -> Void

    @ObservationIgnored private var audio: AVAudioPlayer?
    @ObservationIgnored private var listener: Listener?
    @ObservationIgnored private var timer: Timer?
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
            let player = try AVAudioPlayer(contentsOf: library.url(for: recording.file))
            let listener = Listener { [weak self] player, successfully in self?.finished(player, successfully: successfully) }
            player.delegate = listener
            player.volume = volume
            guard player.prepareToPlay(), player.duration > 0 else { throw CocoaError(.fileReadCorruptFile) }
            audio = player
            self.listener = listener
            duration = player.duration
        } catch {
            loadError = Self.cannotPlay
        }
    }

    /// Nothing loaded, nothing playing, live audio back.
    func unload() {
        stopTimer()
        audio?.stop()
        audio = nil
        listener = nil
        file = nil
        start = nil
        loadedFolder = nil
        duration = 0
        position = 0
        isPlaying = false
        loadError = nil
        muteLive(false)
    }

    /// Marks the recording heard, silences the live radio and plays from the position. From the end it starts
    /// over, as a player does.
    func play() {
        guard let audio, let file, !isPlaying else { return }
        if position >= duration { position = 0 }
        audio.currentTime = position
        guard audio.play() else {
            loadError = Self.cannotPlay
            return
        }
        isPlaying = true
        muteLive(true)
        library.markHeard(file)
        startTimer()
    }

    func pause() {
        guard let audio, isPlaying else { return }
        audio.pause()
        position = audio.currentTime
        isPlaying = false
        stopTimer()
        muteLive(false)
    }

    func togglePlay() { isPlaying ? pause() : play() }

    /// To `seconds`, kept within the file. Playing carries on from there.
    func seek(to seconds: Double) {
        guard let audio, seconds.isFinite else { return }
        position = min(max(seconds, 0), duration)
        audio.currentTime = position
    }

    func move(jumps n: Int) { seek(to: position + Double(n) * jump) }

    /// Called whenever the library changes: the file it was playing may be gone (deleted in Finder), or the
    /// recordings folder may be another one.
    func reconcile(with catalog: RecordingsCatalog) {
        guard let file else { return }
        if !catalog.files.contains(file) || library.folder != loadedFolder { unload() }
    }

    // MARK: Private

    private static let cannotPlay = "Can't play this file"

    private func muteLive(_ muted: Bool) {
        guard muted != liveIsMuted else { return }
        liveIsMuted = muted
        setLiveMuted(muted)
    }

    /// The player reached the end of the file, or stopped decoding it.
    private func finished(_ player: AVAudioPlayer, successfully: Bool) {
        guard player === audio else { return }   // a callback from a file that has since been replaced
        stopTimer()
        isPlaying = false
        position = successfully ? duration : player.currentTime
        if !successfully { loadError = Self.cannotPlay }
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
        guard isPlaying, let audio else { return }
        position = min(audio.currentTime, duration)
    }

    /// `AVAudioPlayer`'s delegate must be an `NSObject`; this forwards the end of playback to the player on
    /// the main actor. The callbacks arrive on the main thread, and they are handled in place rather than
    /// through a task, so the position is final as soon as the player says it has finished.
    private final class Listener: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {
        private let onFinish: @MainActor (AVAudioPlayer, Bool) -> Void
        init(onFinish: @escaping @MainActor (AVAudioPlayer, Bool) -> Void) { self.onFinish = onFinish }

        nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) { forward(player, flag) }

        nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) { forward(player, false) }

        nonisolated private func forward(_ player: AVAudioPlayer, _ successfully: Bool) {
            nonisolated(unsafe) let player = player
            if Thread.isMainThread {
                MainActor.assumeIsolated { onFinish(player, successfully) }
            } else {
                Task { @MainActor in onFinish(player, successfully) }
            }
        }
    }
}
