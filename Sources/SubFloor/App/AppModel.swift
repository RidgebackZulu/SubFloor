import AppKit
import DSPCore
import Modems
import Observation
import Recording
import SDRplayKit
import SubFloorCore
import SwiftUI
import Transcription
import UniformTypeIdentifiers

enum BannerAction: Equatable { case retry, reduceGain, copyServiceRestart }

struct Banner: Identifiable, Equatable {
    enum Kind { case info, warning, error }
    let id = UUID()
    var kind: Kind
    var message: String
    var action: BannerAction?
}

enum SourceKind: String, CaseIterable, Identifiable, Codable {
    case sdrplay = "RSP1B", synthetic = "Demo", file = "IQ File"
    var id: String { rawValue }
}

struct HoverReadout: Equatable {
    var point: CGPoint     // unit coordinates, y = 0 at top of the spectrum+waterfall area
    var hz: Double
    var db: Float?
}

private struct SessionState: Codable {
    var vfoHz: Double
    var centerHz: Double
    var mode: DemodMode
    var bandwidthHz: Double
    var upconverter: Upconverter
    var hardware: SDRplaySettings
    var spectrum: SpectrumSettings
    var dbMin: Float
    var dbMax: Float
    var colormap: Colormap
    var showBookmarks: Bool
    var volume: Float
    var agcSpeed: AGCSpeed
    var cwPitchHz: Double
    var preferredSource: SourceKind
    /// No longer applied (the box follows the receiver's passband); optional so that sessions saved
    /// before and after it decode.
    var modemBox: ModemBox?
    var modemSettings: ModemSettings?
    var recording: RecordingSettings?
    // Optional so that sessions saved before auto-record decode.
    var autoRecord: Bool?
    var squelchEnabled: Bool?
    var squelchDb: Float?
    // Optional so that sessions saved before noise reduction decode.
    var noiseReduction: NoiseReductionSettings?
    // Optional so that sessions saved before Skip silence decode.
    var skipSilence: Bool?
    // Optional so that sessions saved before transcripts decode.
    var transcription: TranscriptionSettings?
}

@MainActor @Observable
final class AppModel {
    // MARK: Radio (display frequencies)
    private(set) var isRunning = false
    private(set) var sourceKind: SourceKind = .synthetic
    private(set) var preferredSource: SourceKind = .sdrplay
    private(set) var deviceName = "Not started"
    private(set) var centerHz: Double = 14_100_000
    private(set) var vfoHz: Double = 14_200_000
    private(set) var mode: DemodMode = .usb
    private(set) var bandwidthHz: Double = 2_700
    private(set) var upconverter = Upconverter()
    private(set) var hardware = SDRplaySettings()
    var cwPitchHz: Double = 700 { didSet { pushReceiver() } }
    /// Turning it off disables auto-record before the receiver opens the gate, so the DSP thread never
    /// runs a block with the gate open and the trigger still on (it would commit the whole silent gap).
    var squelchEnabled = false {
        didSet {
            if squelchEnabled {
                pushReceiver()
                pushAutoRecord()
            } else {
                pushAutoRecord()
                pushReceiver()
            }
        }
    }
    var squelchDb: Float = -80 { didSet { pushReceiver() } }
    /// Noise reduction on the speakers (not the recordings), persisted. It keeps its setting in the
    /// modes where it does not apply (`noiseReductionAvailable`). The engine is sent the setting as it
    /// is and applies it only where the mode allows, on every mode change however it happens (the
    /// mode picker, a bookmark, a restored session).
    var noiseReduction = NoiseReductionSettings() {
        didSet {
            engine.update(noiseReduction: noiseReduction)
            player?.noiseReduction = noiseReduction
            saveSessionIfChanged()
        }
    }
    /// The Recordings player jumps over silent stretches while playing, persisted.
    var skipSilence = true {
        didSet {
            player?.skipSilence = skipSilence
            saveSessionIfChanged()
        }
    }
    /// Speech-transcript settings, persisted. Turning `enabled` on stamps `enabledSince` with now, however
    /// it happens; changing the model or language leaves it. A first launch (no saved settings) starts
    /// enabled, since the launch time.
    var transcriptionSettings = TranscriptionSettings(enabledSince: Date()) {
        didSet {
            if transcriptionSettings.enabled && !oldValue.enabled {
                transcriptionSettings.enabledSince = Date()
            }
            saveSessionIfChanged()
        }
    }
    func toggleTranscription() { transcriptionSettings.enabled.toggle() }
    /// The OpenRouter key, read from the key store at launch. Never logged, printed or saved in the session.
    private(set) var apiKey: String?
    var hasAPIKey: Bool { !(apiKey ?? "").isEmpty }
    /// Stores `key` (trimmed) in the key store; an empty or blank key removes it instead.
    func saveAPIKey(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { try removeAPIKey(); return }
        try apiKeyStore.save(trimmed)
        apiKey = trimmed
    }
    func removeAPIKey() throws {
        try apiKeyStore.remove()
        apiKey = nil
    }
    /// Saves the key from the `.env` file at `url`. Throws `APIKeyImportError.noKey` when the file has
    /// none (the stored key is left alone), or the read error when the file cannot be read.
    func importAPIKey(fromEnvFileAt url: URL) throws {
        let contents = try String(contentsOf: url, encoding: .utf8)
        guard let key = EnvFile.openRouterKey(in: contents) else { throw APIKeyImportError.noKey }
        try saveAPIKey(key)
    }
    var noiseReductionAvailable: Bool { NoiseReductionSettings.isAvailable(for: mode) }
    func toggleNoiseReduction() {
        guard noiseReductionAvailable else { return }
        noiseReduction.enabled.toggle()
    }
    var agcSpeed: AGCSpeed = .medium { didSet { pushReceiver() } }
    var volume: Float = 0.5 {
        didSet {
            engine.update(volume: effectiveVolume)
            player?.volume = volume
        }
    }
    /// The live radio is silent while a recording plays (`RecordingPlayer`). The volume knob keeps its place
    /// and the session keeps saving `volume`; only what the engine is told changes.
    var liveAudioMuted = false { didSet { engine.update(volume: effectiveVolume) } }
    /// The live radio is also silent the whole time the Recordings window is open, playing or not, so
    /// listening back is never talked over; it returns when the window closes.
    var recordingsWindowOpen = false { didSet { engine.update(volume: effectiveVolume) } }
    /// What the engine plays the live radio at.
    var effectiveVolume: Float { liveAudioMuted || recordingsWindowOpen ? 0 : volume }

    // MARK: Recording
    /// Recording preferences (Settings). Kept valid; a change to a sample format starts the pre-roll
    /// over and ends a recording in progress, and so does a pre-roll change for IQ
    /// (`StreamRecorder.configure`). The audio ring is planned for the longest pre-roll, so a pre-roll
    /// change never ends an audio recording.
    var recording = RecordingSettings() {
        didSet {
            let valid = recording.normalized()
            if valid != recording { recording = valid }
            if recording != oldValue {
                pushRecording()
                pushAutoRecord()
                library.setFolder(recording.folder)
            }
        }
    }
    /// Each recorder's state, polled at 5 Hz (`refreshStats`); set at once on start.
    private(set) var recordingStatus: [StreamKind: RecordingStatus] = [:]

    /// Auto-record (the Auto button), persisted. It records only while the radio runs on a real
    /// source with the squelch on; otherwise it waits (`autoRecordState`).
    var autoRecordEnabled = false {
        didSet {
            guard autoRecordEnabled != oldValue else { return }
            if autoRecordEnabled { lastDiskCheck = nil }   // check the disk at the next refresh
            pushAutoRecord()
        }
    }

    /// `paused`: Auto is on but a manual audio recording owns the recorder; the trigger resumes after it.
    enum AutoRecordState: Equatable { case off, armed, recording, needsSquelch, needsRadio, demoSource, paused }

    /// What the Auto button shows: why it is waiting, if it is.
    var autoRecordState: AutoRecordState {
        if !autoRecordEnabled { return .off }
        if !isRunning { return .needsRadio }
        if sourceKind == .synthetic { return .demoSource }
        if !squelchEnabled { return .needsSquelch }
        if isRecording(.audio) { return .paused }
        return isAutoRecording ? .recording : .armed
    }

    /// Reads the recordings folder for the unheard badge, and lists it again whenever the app comes to the
    /// front: only the Recordings window lists it otherwise, so a file deleted in Finder while the window is
    /// closed would stay counted. Internal for tests, which start it on a model pointed at a temp folder.
    func startLibrary() {
        guard libraryActivation == nil else { return }
        libraryActivation = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let library = self?.library else { return }
                Task { await library.refreshFiles() }
            }
        }
        Task { [library] in await library.reload() }
    }

    @ObservationIgnored private var libraryActivation: (any NSObjectProtocol)?

    /// The log of finished recordings and ignored pops, in the recordings folder.
    var recordingLog: RecordingLog { RecordingLog(folder: recording.folder) }

    /// The recordings in the folder, with when they were made and whether they have been heard. It follows
    /// the folder setting, the log writes below and the recording in progress.
    let library: RecordingsLibrary

    /// Plays a recording from the library and mutes the live radio while it does. Set once in `init`, which
    /// is why it is not a `let`: its mute closure needs `self`.
    @ObservationIgnored private(set) var player: RecordingPlayer!

    /// Whether the Recordings window is the key window: the dial scrubs the player only while it is.
    @ObservationIgnored var recordingsWindowIsKey = false
    /// The file the Recordings window found unplayable (its peaks could not be read), so the dial does not scrub it.
    @ObservationIgnored var recordingsUnplayableFile: String?

    /// Test hook: the free bytes on the volume recordings go to (nil: unknown).
    @ObservationIgnored var freeSpaceProbe: (URL) -> Int64? = { AppModel.freeSpace(at: $0) }
    @ObservationIgnored private var lastDiskCheck: ContinuousClock.Instant?
    /// Under 500 MB at the last check, so the warning is shown once per crossing.
    @ObservationIgnored private var diskLow = false
    /// The VFO and mode the audio recorder was last told: a change cuts an auto recording.
    @ObservationIgnored private var audioTuning: (hz: Double, mode: String)?
    /// The VFO and mode when the current audio recording started, for its log entry.
    @ObservationIgnored private var recordingTuning: (hz: Double, mode: String)?
    /// The first-sample time of the last audio recording logged, so none is logged twice.
    @ObservationIgnored private var loggedRecordingStart: Date?
    /// The first-sample time of the last auto recording whose start was logged.
    @ObservationIgnored private var loggedAutoStart: Date?
    /// The last log write failed (its banner has been shown).
    @ObservationIgnored private var logWriteFailed = false
    /// Held while Auto is on and the radio runs: the Mac does not idle to sleep, and App Nap does not
    /// throttle the timer that logs recordings and checks the disk while the window is hidden.
    @ObservationIgnored private var sleepActivity: (any NSObjectProtocol)?

    // MARK: Display
    var spectrum = SpectrumSettings() { didSet { engine.update(spectrum: spectrum) } }
    private(set) var viewport = SpectrumViewport(captureCenterHz: 14_100_000, captureSpanHz: 2_000_000)
    var dbMin: Float = -130
    var dbMax: Float = -20
    var colormap: Colormap = .turbo
    var showPeak = false
    var spectrumFraction: CGFloat = 0.4
    private(set) var hover: HoverReadout?

    // MARK: Bookmarks, modems, UI
    private(set) var bookmarks: [Bookmark] = []
    var showBookmarks = true
    /// The multi-signal modem's box, settings and cursor (see `ModemControl`). Not observed: it also
    /// changes with the cursor's tracking and the engine bookkeeping several times a second, which
    /// would re-render every view reading any part of it (the modem strip's segmented pickers among
    /// them, which SwiftUI re-measures slowly). Views read the parts below instead, which `setModem`
    /// assigns only when they change.
    @ObservationIgnored private var modem = ModemControl()
    private(set) var modemBox = ModemBox(dialHz: ModemControl.defaultDialHz)
    /// The user's modem settings, as persisted (`modemSettings` is what the engine gets).
    private var modemUserSettings = ModemSettings()
    private(set) var modemCursorAudioHz: Double?
    /// The audio band decoded (the passband's part of the box); nil when none of it can be.
    private(set) var modemAudioBand: ClosedRange<Double>? = ModemSettings.fullBand
    /// The last slot of each slot mode: decoded (how many messages) or skipped for a gap. Cleared
    /// when the modem resets.
    private(set) var slotOutcomes: [ModeID: SlotOutcome] = [:]
    /// The rows as shown: `liveLog`, published at 5 Hz with the other stats (and at once after a user
    /// action on the rows). Each publish re-renders the rows, the signal count and the ruler; at
    /// 10 Hz those SwiftUI passes cost about a sixth of a core on the Mac.
    private(set) var decodeLog = DecodeLog()
    /// The rows as the engine's output arrives (10 Hz); not observed.
    @ObservationIgnored private var liveLog = DecodeLog()
    @ObservationIgnored private var liveLogChanged = false
    /// The live rows' audio frequencies, for the ruler's ticks: assigned only when a tick would move
    /// (to the nearest hertz), so the rows' text doesn't redraw the ruler.
    private(set) var modemTrackAudioHz: [Double] = []
    /// The system clock's offset from network time (`ClockCheck`), once measured.
    private(set) var clockOffset: Double?
    private var clockCheckStarted = false
    /// Test hook: every update made to the engine's modem, in order.
    @ObservationIgnored var onModemEngineUpdate: ((ModemEngineUpdate) -> Void)?
    var banner: Banner?
    var quickTuneVisible = false
    private(set) var signalDb: Float = -200
    private(set) var underruns = 0
    private(set) var cpuPercent: Double = 0
    private(set) var overloaded = false
    private var didAutoStart = false
    /// Set when opening the RSP failed; later start() calls fall back to demo without retrying until retry()/useSource(.sdrplay).
    private(set) var rspOpenFailed = false

    /// The RSP is opened on a background thread (`openRSPInBackground`): the SDRplay API blocks for
    /// ever when its service is stuck (a client died holding the API's cross-process lock), and on
    /// the main thread that left the app without a window. `.opening`: an open is in flight and the
    /// radio waits for it. `.stalled`: it has not returned within `rspOpenTimeout`; the demo signal
    /// runs, and since that thread is still inside the API no other open is tried until relaunch.
    enum RSPConnection: Equatable { case idle, opening, stalled }
    private(set) var rspConnection: RSPConnection = .idle
    private var rspOpenAttempt = 0
    private let openRSP: @Sendable () throws -> SDRplayDevice
    private let rspOpenTimeout: Duration
    private var isShutDown = false
    static let serviceRestartCommand = "sudo launchctl kickstart -k system/com.sdrplay.service"
    static let serviceStalledMessage = "The SDRplay service is not responding, so the demo signal is running. Restart the service in Terminal, then reopen SubFloor."

    let engine = DSPEngine()
    private var sdrplay: SDRplayDevice?
    private let synthetic = SyntheticSource()
    private var fileSource: IQFileSource?
    private let bookmarkStore: BookmarkStore
    private let defaults: UserDefaults
    private let apiKeyStore: any APIKeyStore
    private var bookmarksSaveBlocked = false
    private var statsTimer: Timer?
    private var statsTicks = 0
    private var cpu = CPUUsage()
    private var lastSavedSession: Data?

    /// The app's model. Only this one reads the recordings folder at launch: a test's model, made with the
    /// init below, points the library at its own folder (or none) rather than at the owner's recordings.
    convenience init() {
        self.init(bookmarkStore: BookmarkStore(url: BookmarkStore.defaultURL), defaults: .standard,
                  apiKeyStore: KeychainAPIKeyStore())
        startLibrary()
    }

    /// `openRSP` and `rspOpenTimeout`: tests replace the device and the wait.
    init(bookmarkStore: BookmarkStore, defaults: UserDefaults,
         apiKeyStore: any APIKeyStore = MemoryAPIKeyStore(),
         openRSP: @escaping @Sendable () throws -> SDRplayDevice = { try SDRplayDevice.open() },
         rspOpenTimeout: Duration = .seconds(10)) {
        self.bookmarkStore = bookmarkStore
        self.defaults = defaults
        self.apiKeyStore = apiKeyStore
        apiKey = apiKeyStore.load()
        self.openRSP = openRSP
        self.rspOpenTimeout = rspOpenTimeout
        library = RecordingsLibrary(folder: RecordingSettings().folder)   // the folder `restoreSession` may replace
        player = RecordingPlayer(library: library, setLiveMuted: { [weak self] muted in self?.liveAudioMuted = muted })
        let (loaded, result) = bookmarkStore.load()
        bookmarks = loaded
        switch result {
        case .recoveredFromCorrupt:
            show(Banner(kind: .warning, message: "The bookmarks file was unreadable. It was backed up as \(bookmarkStore.lastBackupURL?.lastPathComponent ?? "bookmarks.corrupt-<timestamp>.json") and the defaults were restored."))
        case .corruptNotPreserved:
            show(Banner(kind: .error, message: Self.bookmarksBlockedMessage))
            bookmarksSaveBlocked = true
        case .loaded, .createdDefaults:
            break
        }
        restoreSession()
        player.volume = volume
        player.noiseReduction = noiseReduction
        player.skipSilence = skipSilence
        pushRecording()
        pushRecordingContexts()
        pushAutoRecord()
        followPassband()
        engine.audio.onError = { [weak self] message in
            Task { @MainActor in self?.show(Banner(kind: .error, message: message, action: .retry)) }
        }
        library.onError = { [weak self] message in self?.show(Banner(kind: .error, message: message)) }
        library.onChange = { [weak self] in
            guard let self else { return }
            player.reconcile(with: library.catalog)
        }
        // 10 Hz: the modem drain every tick, the other stats every other one.
        // In the common modes, so it also runs during menu tracking, a modal panel or a live resize:
        // auto-record keeps recording through those, and its log and disk checks ride on this timer.
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshStats() }
        }
        RunLoop.main.add(timer, forMode: .common)
        statsTimer = timer
    }

    // MARK: Derived

    private var activeSource: any IQSource {
        switch sourceKind {
        case .sdrplay: sdrplay ?? synthetic
        case .synthetic: synthetic
        case .file: fileSource ?? synthetic
        }
    }

    var sampleRate: Double { sourceKind == .file ? (fileSource?.sampleRate ?? hardware.outputRate) : hardware.outputRate }

    var lnaStateCount: Int { RSP1B.lnaStateCount(forHz: upconverter.hardware(fromDisplay: centerHz)) }

    var passbandRange: ClosedRange<Double> {
        let c = vfoHz + mode.passbandOffset(bandwidth: bandwidthHz)
        return (c - bandwidthHz / 2)...(c + bandwidthHz / 2)
    }

    var passbandEdgeFractions: (lower: Double, upper: Double)? {
        (viewport.fraction(ofHz: passbandRange.lowerBound), viewport.fraction(ofHz: passbandRange.upperBound))
    }

    var displayState: DisplayState {
        DisplayState(startFraction: viewport.startFractionOfCapture, widthFraction: viewport.widthFractionOfCapture,
                     dbMin: dbMin, dbMax: dbMax, spectrumFraction: Float(spectrumFraction),
                     showPeak: showPeak, colormap: colormap)
    }

    var visibleBookmarks: [Bookmark] {
        guard showBookmarks else { return [] }
        return bookmarks.filter { $0.frequencyHz >= viewport.lowerHz && $0.frequencyHz <= viewport.upperHz }
    }

    private var receiverConfig: Receiver.Config {
        Receiver.Config(inputRate: sampleRate, offsetHz: vfoHz - centerHz, mode: mode, bandwidthHz: bandwidthHz,
                        cwPitchHz: cwPitchHz, squelchDb: squelchEnabled ? squelchDb : nil, agc: agcSpeed)
    }

    private func pushReceiver() {
        engine.update(receiver: receiverConfig)
        followPassband()
        pushRecordingContexts()
    }

    /// The modem decodes what the receiver is tuned to: its box follows the passband.
    private func followPassband() {
        let passband = passbandRange, vfo = vfoHz, usb = mode == .usb
        changeModem { $0.follow(passband: passband, vfoHz: vfo, upperSideband: usb) }
    }

    /// Shows `new` unless it would hide a more severe banner that is already up (error > warning > info).
    private func show(_ new: Banner) {
        func rank(_ k: Banner.Kind) -> Int { switch k { case .info: 0; case .warning: 1; case .error: 2 } }
        if let current = banner, rank(new.kind) < rank(current.kind) { return }
        banner = new
    }

    // MARK: Run control

    func startIfNeeded() {
        guard !didAutoStart else { return }
        didAutoStart = true
        start()
    }

    func resetPeak() { engine.resetPeak() }

    func stepDigit(power: Int, ticks: Int) {
        setVFO(vfoHz + Double(ticks) * pow(10, Double(power)))
    }

    func toggleRun() { isRunning ? stop() : start() }

    /// Starts the preferred source. Without an open RSP this first opens one in the background and
    /// returns; the open's outcome starts the radio (`finishRSPOpen`, `rspOpenTimedOut`).
    func start() {
        stop()
        defer { pushAutoRecord() }
        var kind = preferredSource
        if kind == .sdrplay && sdrplay == nil {
            switch rspConnection {
            case .opening:
                return
            case .stalled:
                kind = .synthetic
            case .idle:
                if rspOpenFailed {
                    kind = .synthetic
                } else {
                    openRSPInBackground()
                    return
                }
            }
        }
        if kind == .file && fileSource == nil { kind = .synthetic }
        sourceKind = kind

        switch kind {
        case .sdrplay:
            do { try sdrplay?.apply(hardware) } catch { show(Banner(kind: .error, message: "\(error)")) }
        case .synthetic:
            synthetic.setSampleRate(hardware.outputRate)
        case .file:
            if let fileSource { centerHz = fileSource.centerFrequency }
        }
        if kind != .file {
            centerHz = clampedCenter(centerHz)
            retuneHardware()
        }
        if abs(vfoHz - centerHz) > sampleRate * TuningPlanner.usableFraction { vfoHz = centerHz + TuningPlanner.dcOffset(sampleRate: sampleRate) }
        viewport.setCapture(centerHz: centerHz, spanHz: sampleRate)
        syncModem()
        pushRecording()
        pushRecordingContexts()
        do {
            try engine.start(source: activeSource, receiver: receiverConfig, spectrum: spectrum, volume: effectiveVolume)
            isRunning = true
            deviceName = activeSource.name
            startClockCheckIfNeeded()
        } catch {
            show(Banner(kind: .error, message: "Could not start: \(error)", action: .retry))
        }
    }

    func stop() {
        guard isRunning else { return }
        engine.stop()   // finalises any recording
        isRunning = false
        overloaded = false
        pushAutoRecord()
        refreshRecordingStatus()
    }

    /// Orderly shutdown (app quit): stop the engine, release the RSP, persist the session. Idempotent.
    func shutdown() {
        isShutDown = true
        player.unload()
        engine.stop()
        isRunning = false
        pushAutoRecord()
        refreshRecordingStatus()   // logs a recording the stop ended
        sdrplay?.close()
        sdrplay = nil
        saveSessionIfChanged()
        statsTimer?.invalidate()
        statsTimer = nil
        if let libraryActivation { NotificationCenter.default.removeObserver(libraryActivation) }
        libraryActivation = nil
    }

    func retry() {
        banner = nil
        rspOpenFailed = false
        if preferredSource == .sdrplay, let device = sdrplay {
            stop()
            device.close()
            sdrplay = nil
        }
        if preferredSource == .sdrplay, rspConnection == .stalled { showServiceStalled() }
        start()
    }

    func perform(_ action: BannerAction) {
        switch action {
        case .retry: retry()
        case .reduceGain:
            updateHardware { $0.ifGainReductionDb = min($0.ifGainReductionDb + 6, RSP1B.ifGainReductionRange.upperBound) }
            banner = nil
        case .copyServiceRestart:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(Self.serviceRestartCommand, forType: .string)
            banner = Banner(kind: .info, message: "Copied. Paste it into Terminal, enter your password, then reopen SubFloor.")
        }
    }

    // MARK: Opening the RSP

    /// Opens the RSP on its own thread. The radio stays stopped (the chip says "Connecting") until
    /// the open returns, or for at most `rspOpenTimeout`, after which the demo signal runs.
    private func openRSPInBackground() {
        rspConnection = .opening
        rspOpenAttempt += 1
        let attempt = rspOpenAttempt, open = openRSP
        let thread = Thread { [weak self] in
            let result = Result { try open() }
            Task { @MainActor in
                guard let self else {
                    if case .success(let device) = result { device.close() }
                    return
                }
                self.finishRSPOpen(attempt, result)
            }
        }
        thread.name = "SubFloor RSP open"
        thread.start()
        Task { [weak self, timeout = rspOpenTimeout] in
            try? await Task.sleep(for: timeout)
            self?.rspOpenTimedOut(attempt)
        }
    }

    private func rspOpenTimedOut(_ attempt: Int) {
        guard attempt == rspOpenAttempt, rspConnection == .opening, !isShutDown else { return }
        rspConnection = .stalled
        guard preferredSource == .sdrplay else { return }
        showServiceStalled()
        start()
    }

    private func finishRSPOpen(_ attempt: Int, _ result: Result<SDRplayDevice, any Error>) {
        guard attempt == rspOpenAttempt else {
            if case .success(let device) = result { device.close() }
            return
        }
        let wasStalled = rspConnection == .stalled
        rspConnection = .idle
        switch result {
        case .success(let device):
            // Not wanted any more (another source chosen, or quitting): release it at once.
            guard !isShutDown, preferredSource == .sdrplay, sdrplay == nil else {
                device.close()
                return
            }
            device.onEvent = { [weak self, weak device] event in
                guard let self, let device else { return }
                Task { @MainActor in self.handle(event, from: device) }
            }
            sdrplay = device
            if banner?.action == .copyServiceRestart { banner = nil }
            start()
        case .failure(let error):
            rspOpenFailed = true
            // After a stall the demo is already running and the banner already up.
            guard !isShutDown, preferredSource == .sdrplay, !wasStalled else { return }
            show(Banner(kind: .warning, message: "No RSP found — demo signal. \(error)", action: .retry))
            start()
        }
    }

    private func showServiceStalled() {
        show(Banner(kind: .error, message: Self.serviceStalledMessage, action: .copyServiceRestart))
    }

    func useSource(_ kind: SourceKind) {
        if kind == .file && fileSource == nil {
            openIQFile()
            return
        }
        preferredSource = kind
        if kind == .sdrplay {
            rspOpenFailed = false
            if rspConnection == .stalled { showServiceStalled() }
        } else if sdrplay != nil {
            // Free the RSP for other apps while a different source is in use.
            stop()
            sdrplay?.close()
            sdrplay = nil
        }
        if isRunning || kind != .sdrplay { start() }
        pushAutoRecord()
    }

    func openIQFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.wav]
        panel.message = "Choose a stereo I/Q WAV recording"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let center = Self.centerFrequency(fromFileName: url.lastPathComponent) ?? centerHz
        do {
            fileSource = try IQFileSource(url: url, centerFrequency: center)
            preferredSource = .file
            vfoHz = center
            start()
        } catch {
            show(Banner(kind: .error, message: "Could not open \(url.lastPathComponent): \(error)"))
        }
    }

    /// Picks "…_14074000Hz_…" style centre frequencies out of SDR#/SDRuno file names.
    static func centerFrequency(fromFileName name: String) -> Double? {
        guard let match = name.firstMatch(of: /(\d{4,})Hz/) else { return nil }
        return Double(match.1)
    }

    func handleOverload(_ detected: Bool) {
        overloaded = detected
        if detected {
            show(Banner(kind: .warning, message: "ADC overload — reduce gain.", action: .reduceGain))
        } else if banner?.action == .reduceGain {
            banner = nil
        }
    }

    private func handle(_ event: SDRplayEvent, from device: SDRplayDevice) {
        guard device === sdrplay else { return }
        switch event {
        case .overload(let detected):
            handleOverload(detected)
        case .deviceRemoved, .deviceFailure:
            stop()
            overloaded = false
            sdrplay?.close()
            sdrplay = nil
            show(Banner(kind: .error, message: event == .deviceRemoved ? "RSP1B disconnected." : "RSP1B reported a failure.", action: .retry))
        case .gainChanged:
            break
        }
    }

    // MARK: Tuning

    /// Direct tune (typed frequency, quick-tune): retunes hardware and resets the view, or with
    /// `keepZoom` (a bookmark) keeps the view's span and centres it on the new VFO.
    func tune(to displayHz: Double, keepZoom: Bool = false) {
        let hz = clampedDisplay(displayHz)
        vfoHz = hz
        if sourceKind == .file {
            vfoHz = min(max(hz, centerHz - sampleRate * 0.45), centerHz + sampleRate * 0.45)
        } else {
            centerHz = clampedCenter(TuningPlanner.center(forVFO: hz, sampleRate: sampleRate))
            retuneHardware()
        }
        viewport.setCapture(centerHz: centerHz, spanHz: sampleRate)
        if keepZoom { viewport.center(on: vfoHz) } else { viewport.reset() }
        pushReceiver()
        syncModem()
    }

    /// VFO move inside the spectrum (click, drag, keys). Retunes only if the VFO leaves the usable span.
    func setVFO(_ displayHz: Double) {
        var hz = clampedDisplay(displayHz)
        if sourceKind == .file {
            hz = min(max(hz, centerHz - sampleRate * 0.45), centerHz + sampleRate * 0.45)
        } else if let newCenter = TuningPlanner.retuneIfNeeded(vfo: hz, center: centerHz, sampleRate: sampleRate) {
            centerHz = clampedCenter(newCenter)
            vfoHz = hz
            retuneHardware()
            viewport.setCapture(centerHz: centerHz, spanHz: sampleRate)
            syncModem()
        }
        vfoHz = hz
        viewport.ensureVisible(hz)
        pushReceiver()
    }

    func stepVFO(_ steps: Int) {
        let step = mode.tuningStep
        setVFO(((vfoHz / step).rounded() + Double(steps)) * step)
    }

    /// The dial's knob: `steps` of `stepHz` from that step's grid, as `stepVFO` does with the mode's step.
    func stepVFO(_ steps: Int, stepHz: Double) {
        guard stepHz > 0 else { return }
        setVFO(((vfoHz / stepHz).rounded() + Double(steps)) * stepHz)
    }

    func stepBandwidth(_ steps: Int) {
        setBandwidth(bandwidthHz + Double(steps) * mode.bandwidthStep)
    }

    func setMode(_ newMode: DemodMode) {
        guard newMode != mode else { return }
        mode = newMode
        bandwidthHz = newMode.defaultBandwidth
        pushReceiver()
    }

    func cycleMode(_ delta: Int) {
        let all = DemodMode.allCases
        let i = all.firstIndex(of: mode)!
        setMode(all[(i + delta + all.count) % all.count])
    }

    func setBandwidth(_ hz: Double) {
        bandwidthHz = min(max(hz, mode.bandwidthRange.lowerBound), mode.bandwidthRange.upperBound).rounded()
        pushReceiver()
    }

    func setUpconverter(_ enabled: Bool) {
        guard enabled != upconverter.enabled else { return }
        upconverter.enabled = enabled
        resyncAfterUpconverterChange()
    }

    func setUpconverterLO(_ hz: Double) {
        guard hz.isFinite, (1_000_000...1_900_000_000).contains(hz) else {
            show(Banner(kind: .warning, message: "Upconverter LO must be between 1 MHz and 1.9 GHz."))
            return
        }
        upconverter.loHz = hz
        resyncAfterUpconverterChange()
    }

    private func resyncAfterUpconverterChange() {
        guard sourceKind != .file else { return }
        centerHz = clampedCenter(centerHz)
        vfoHz = clampedDisplay(vfoHz)
        if let newCenter = TuningPlanner.retuneIfNeeded(vfo: vfoHz, center: centerHz, sampleRate: sampleRate) {
            centerHz = clampedCenter(newCenter)
        }
        retuneHardware()
        viewport.setCapture(centerHz: centerHz, spanHz: sampleRate)
        pushReceiver()
        syncModem()
    }

    private func clampedDisplay(_ hz: Double) -> Double {
        let lo = max(upconverter.display(fromHardware: RSP1B.frequencyRange.lowerBound), 1_000)
        let hi = upconverter.display(fromHardware: RSP1B.frequencyRange.upperBound)
        return min(max(hz, lo), hi)
    }

    private func clampedCenter(_ hz: Double) -> Double {
        upconverter.display(fromHardware: RSP1B.clampHardware(upconverter.hardware(fromDisplay: hz)))
    }

    private func retuneHardware() {
        guard sourceKind != .file else { return }
        synthetic.antennaOffset = upconverter.enabled ? upconverter.loHz : 0
        do {
            try activeSource.setCenterFrequency(upconverter.hardware(fromDisplay: centerHz))
        } catch {
            show(Banner(kind: .error, message: "Tune failed: \(error)"))
        }
        pushRecordingContexts()
        if !upconverter.enabled && vfoHz < 50_000 {
            show(Banner(kind: .info, message: "Below 50 kHz the RSP1B is weak — enable HamItUp if it is connected."))
        }
        let maxLNA = lnaStateCount - 1
        if hardware.lnaState > maxLNA { updateHardware { $0.lnaState = maxLNA } }
    }

    // MARK: Hardware settings

    func updateHardware(_ change: (inout SDRplaySettings) -> Void) {
        var s = hardware
        change(&s)
        s.lnaState = min(max(s.lnaState, 0), lnaStateCount - 1)
        s.ifGainReductionDb = min(max(s.ifGainReductionDb, RSP1B.ifGainReductionRange.lowerBound), RSP1B.ifGainReductionRange.upperBound)
        s.ifBandwidthKHz = RSP1B.ifBandwidthKHz(sampleRate: s.sampleRate, decimation: s.decimation)
        let rateChanged = s.outputRate != hardware.outputRate
        hardware = s
        if rateChanged {
            if isRunning { start() } else {
                synthetic.setSampleRate(s.outputRate)
                viewport.setCapture(centerHz: centerHz, spanHz: sampleRate)
                syncModem()
            }
            return
        }
        do { try sdrplay?.apply(s) } catch { show(Banner(kind: .error, message: "\(error)")) }
    }

    // MARK: Spectrum interaction (never retunes except through setVFO)

    func zoom(by factor: Double, anchor: Double) { viewport.zoom(by: factor, anchorFraction: anchor) }
    func pan(byFraction f: Double) { viewport.pan(byFraction: f) }
    func resetView() { viewport.reset() }

    func click(atFraction f: Double) {
        let step = min(mode.tuningStep, mode == .wfm ? 100_000 : 1_000)
        setVFO((viewport.hz(atFraction: f) / step).rounded() * step)
    }

    func dragPassbandEdge(upper: Bool, fraction f: Double) {
        let hz = viewport.hz(atFraction: f)
        switch mode {
        case .usb: setBandwidth(hz - vfoHz - 100)
        case .lsb: setBandwidth(vfoHz - 100 - hz)
        default: setBandwidth(2 * abs(hz - vfoHz))
        }
    }

    func hover(at unit: CGPoint?) {
        guard let unit else { hover = nil; return }
        let sf = Double(spectrumFraction)
        let db: Float? = Double(unit.y) <= sf ? dbMax - Float(Double(unit.y) / sf) * (dbMax - dbMin) : nil
        hover = HoverReadout(point: unit, hz: viewport.hz(atFraction: Double(unit.x)), db: db)
    }

    // MARK: Bookmarks

    /// Tunes to `bookmark`: its HamItUp state, mode, passband width and frequency, at the current zoom.
    func select(_ bookmark: Bookmark) {
        setUpconverter(bookmark.upconverter)
        mode = bookmark.mode
        let range = bookmark.mode.bandwidthRange
        bandwidthHz = min(max(bookmark.bandwidthHz, range.lowerBound), range.upperBound).rounded()
        tune(to: bookmark.frequencyHz, keepZoom: true)
    }

    /// `bookmark` with the current frequency, mode, passband width and HamItUp state.
    func withCurrentTuning(_ bookmark: Bookmark) -> Bookmark {
        var b = bookmark
        b.frequencyHz = vfoHz
        b.mode = mode
        b.bandwidthHz = bandwidthHz
        b.upconverter = upconverter.enabled
        return b
    }

    func addBookmark() {
        bookmarks.append(Bookmark(name: "\(FrequencyFormatter.short(vfoHz)) \(mode.label)", frequencyHz: vfoHz, mode: mode,
                                  bandwidthHz: bandwidthHz, upconverter: upconverter.enabled, group: "Saved"))
        saveBookmarks()
    }

    func deleteBookmark(_ id: Bookmark.ID) {
        bookmarks.removeAll { $0.id == id }
        saveBookmarks()
    }

    /// Replaces the bookmark with `bookmark`'s id (the flag editor saves each change).
    func updateBookmark(_ bookmark: Bookmark) {
        guard let i = bookmarks.firstIndex(where: { $0.id == bookmark.id }), bookmarks[i] != bookmark else { return }
        bookmarks[i] = bookmark
        saveBookmarks()
    }

    func importBookmarks() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let incoming = try BookmarkStore.read(from: url)
            let existing = Set(bookmarks.map(\.id))
            bookmarks += incoming.filter { !existing.contains($0.id) }
            saveBookmarks()
        } catch {
            show(Banner(kind: .error, message: "Import failed: \(error.localizedDescription)"))
        }
    }

    func exportBookmarks() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "SubFloor Bookmarks.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try BookmarkStore.write(bookmarks, to: url) } catch {
            show(Banner(kind: .error, message: "Export failed: \(error.localizedDescription)"))
        }
    }

    private static let bookmarksBlockedMessage = "The bookmarks file is unreadable and could not be backed up. Changes to bookmarks will not be saved until the file is fixed or removed."

    private func saveBookmarks() {
        if bookmarksSaveBlocked {
            show(Banner(kind: .error, message: Self.bookmarksBlockedMessage))
            return
        }
        do { try bookmarkStore.save(bookmarks) } catch {
            show(Banner(kind: .error, message: "Could not save bookmarks: \(error.localizedDescription)"))
        }
    }

    // MARK: Recording

    private func recorder(_ kind: StreamKind) -> StreamRecorder { kind == .iq ? engine.iqRecorder : engine.audioRecorder }

    /// A manual recording of `kind` (the Audio, IQ and Both buttons); an auto recording is not one.
    func isRecording(_ kind: StreamKind) -> Bool { recordingStatus[kind].map { $0.isRecording && !$0.isAuto } ?? false }
    /// Auto-record is writing an audio recording.
    var isAutoRecording: Bool { recordingStatus[.audio].map { $0.isRecording && $0.isAuto } ?? false }
    var isRecordingAny: Bool { StreamKind.allCases.contains { isRecording($0) } }
    var isRecordingAll: Bool { StreamKind.allCases.allSatisfy { isRecording($0) } }
    /// The IQ ring's size and the pre-roll it gives at the current rate (Settings).
    var iqRingPlan: StreamRecorder.RingPlan? { engine.iqRecorder.ringPlan }

    func toggleRecording(_ kind: StreamKind) { isRecording(kind) ? stopRecording(kind) : startRecording(kind) }

    /// Both: stops everything when both are recording, otherwise starts whichever is not.
    func toggleRecordingBoth() {
        if isRecordingAll {
            StreamKind.allCases.forEach(stopRecording)
        } else {
            StreamKind.allCases.filter { !isRecording($0) }.forEach(startRecording)
        }
    }

    /// Starts recording `kind` from up to the pre-roll ago. Needs the radio running. While Auto is
    /// recording audio, starting audio turns that recording into a manual one (the same file).
    func startRecording(_ kind: StreamKind) {
        guard isRunning else {
            show(Banner(kind: .info, message: "Start the radio before recording."))
            return
        }
        guard !isRecording(kind) else { return }
        let folder = recording.folder
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            show(Banner(kind: .error, message: "Cannot use the recordings folder \(folder.path): \(error.localizedDescription)"))
            return
        }
        if let free = freeSpaceProbe(folder), free < Self.lowDiskBytes {
            show(Banner(kind: .warning, message: Self.lowDiskMessage))
        }
        recorder(kind).start()
        refreshRecordingStatus()
    }

    func stopRecording(_ kind: StreamKind) {
        guard isRecording(kind) else { return }
        recorder(kind).stop()
    }

    func revealRecordings() {
        let folder = recording.folder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let latest = StreamKind.allCases.compactMap { recordingStatus[$0]?.url }.filter { FileManager.default.fileExists(atPath: $0.path) }
        if latest.isEmpty { NSWorkspace.shared.open(folder) } else { NSWorkspace.shared.activateFileViewerSelecting(latest) }
    }

    func chooseRecordingsFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = recording.folder
        panel.message = "Choose where recordings are saved"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        recording.folderPath = url.path
    }

    /// Both recorders get the stream rates and the preferences. The audio ring always holds the
    /// longest pre-roll and the longest auto-record holdback, so neither a timing nor a pre-roll change
    /// rebuilds it (which would end a recording); the pre-roll only sets how far a manual start
    /// rewinds. That is (120 + 612 + 12) s of 48 kHz audio: 143 MB of float, inside its 256 MB limit.
    private func pushRecording() {
        let r = recording
        engine.iqRecorder.configure(StreamRecorder.Setup(
            sampleRate: sampleRate, channels: StreamKind.iq.channels, fileFormat: r.iqFormat, sampleFormat: r.iqSampleFormat,
            preRollSeconds: r.preRollSeconds, memoryLimitBytes: r.iqMemoryLimitBytes, folder: r.folder))
        engine.audioRecorder.configure(StreamRecorder.Setup(
            sampleRate: Receiver.audioRate, channels: StreamKind.audio.channels, fileFormat: r.audioFormat, sampleFormat: r.audioSampleFormat,
            preRollSeconds: r.preRollSeconds, holdbackSeconds: AutoRecordTiming.maxHoldbackSeconds,
            ringPreRollSeconds: RecordingSettings.preRollRange.upperBound, memoryLimitBytes: 256 << 20, folder: r.folder))
    }

    /// File names: the IQ file carries the capture centre (a change rolls it), the audio file the VFO
    /// and mode. A new VFO or mode ends an auto recording; a new capture centre alone does not.
    private func pushRecordingContexts() {
        let hardware = activeSource.name
        engine.iqRecorder.setContext(RecordingContext(frequencyHz: centerHz, label: "IQ", hardware: hardware))
        engine.audioRecorder.setContext(RecordingContext(frequencyHz: vfoHz, label: mode.label, hardware: hardware))
        if let last = audioTuning, last.hz != vfoHz || last.mode != mode.label { engine.autoRecorder.cut() }
        audioTuning = (vfoHz, mode.label)
    }

    /// Polls the recorders, logs an audio recording that ended and the pops heard since the last poll.
    /// Internal for tests, which drive the status sequence without the timer.
    func refreshRecordingStatus() {
        var entries: [RecordingLogEntry] = []
        var live: LiveRecording??   // set when the audio status changed: the recording in progress, or none
        for kind in StreamKind.allCases {
            let s = recorder(kind).status
            let previous = recordingStatus[kind]
            guard s != previous else { continue }
            if let error = s.error, error != previous?.error {
                show(Banner(kind: .error, message: "\(kind.label) recording stopped: \(error)"))
            }
            if kind == .audio {
                entries += audioLogEntries(from: previous, to: s)
                live = .some(liveRecording(for: s))
            }
            recordingStatus[kind] = s
        }
        let hz = vfoHz, label = mode.label
        entries += engine.autoRecorder.drainPops().map { .pop(at: $0.at, seconds: $0.seconds, frequencyHz: hz, mode: label) }
        appendToLog(entries)
        // After the log: a recording that ended is then already a finished one when it stops being live.
        if let live { library.setLive(live) }
    }

    /// The audio recording in progress for the library: its file, the tuning it started with (as it is
    /// logged) and its length so far. nil when none is recording or it has no file yet.
    private func liveRecording(for s: RecordingStatus) -> LiveRecording? {
        guard s.isRecording, let url = s.url, let start = s.startedAt else { return nil }
        let tuning = recordingTuning ?? (hz: vfoHz, mode: mode.label)
        return LiveRecording(file: url.lastPathComponent, start: start, seconds: s.duration,
                             frequencyHz: tuning.hz, mode: tuning.mode, auto: s.isAuto)
    }

    /// Notes the tuning when an audio recording is first seen, and logs every recording that has
    /// ended since the last poll, including one replaced by the next between two polls and one that
    /// began and ended between them (the poll can be late: the timer is 5 Hz and the main thread may
    /// be busy). Each is logged once, keyed by its first-sample time.
    private func audioLogEntries(from previous: RecordingStatus?, to s: RecordingStatus) -> [RecordingLogEntry] {
        let now = (hz: vfoHz, mode: mode.label)
        let tuningBefore = recordingTuning
        var entries: [RecordingLogEntry] = []
        let continued = previous.map { $0.isRecording && Self.sameRecording($0, s) } ?? false
        // The recording seen last time has ended, or another has replaced it.
        if let previous, previous.isRecording, !(s.isRecording && continued) {
            // Its own ended status has the final length and url; a replaced one only what was last seen.
            let ended = Self.sameRecording(previous, s) ? s : previous
            if let entry = logEntry(for: ended, tuning: recordingTuning ?? now) { entries.append(entry) }
            recordingTuning = nil
        }
        if s.isRecording && !continued { recordingTuning = now }
        // One that started and ended unseen. Its tuning at the start is unknown: the current VFO and
        // mode are the best there is (a retune would have cut an auto recording anyway).
        if !s.isRecording, let entry = logEntry(for: s, tuning: now) { entries.append(entry) }
        // An auto recording's start, logged once when it is first seen with a file, so a crash or a
        // force-quit mid-recording still leaves a record of it. It goes before this recording's end,
        // if that is logged in the same poll.
        if s.isAuto, let url = s.url, let start = s.startedAt, start != loggedAutoStart {
            loggedAutoStart = start
            let tuning = s.isRecording ? recordingTuning ?? now : continued ? tuningBefore ?? now : now
            let entry = RecordingLogEntry.autoStarted(file: url.lastPathComponent, start: start, frequencyHz: tuning.hz, mode: tuning.mode)
            let end = entries.firstIndex { if case .recording(_, start, _, _, _, _) = $0 { true } else { false } }
            entries.insert(entry, at: end ?? entries.endIndex)
        }
        return entries
    }

    /// The same recording in two statuses: the same first sample. A status not yet begun (no first
    /// sample) after one that had begun is a new recording; before it, the same one.
    private static func sameRecording(_ a: RecordingStatus, _ b: RecordingStatus) -> Bool {
        guard let first = a.startedAt else { return true }
        return b.startedAt == first
    }

    /// The log entry for a recording with a file, unless it has been logged already. Auto or manual
    /// is what the status says when it was last seen (a takeover by the Audio button is manual).
    private func logEntry(for status: RecordingStatus, tuning: (hz: Double, mode: String)) -> RecordingLogEntry? {
        guard let url = status.url, let start = status.startedAt, start != loggedRecordingStart else { return nil }
        loggedRecordingStart = start
        return .recording(file: url.lastPathComponent, start: start, seconds: status.duration,
                          frequencyHz: tuning.hz, mode: tuning.mode, auto: status.isAuto)
    }

    /// A failed write shows one banner until a write succeeds again; recording carries on.
    private func appendToLog(_ entries: [RecordingLogEntry]) {
        guard !entries.isEmpty else { return }
        do {
            try recordingLog.append(entries)
            logWriteFailed = false
            library.didLog(entries)   // only what is on disk
        } catch {
            guard !logWriteFailed else { return }
            logWriteFailed = true
            show(Banner(kind: .error, message: "Could not write the recordings log: \(error.localizedDescription)"))
        }
    }

    // MARK: Auto-record

    /// Turns Auto on or off. On with the squelch off, it says so and waits for the squelch.
    func toggleAutoRecord() {
        autoRecordEnabled.toggle()
        if autoRecordEnabled && !squelchEnabled {
            show(Banner(kind: .info, message: "Auto-record needs the squelch on."))
        }
    }

    /// Test hook: the Mac is kept from idle sleep.
    var isPreventingSleep: Bool { sleepActivity != nil }

    /// Tells the engine whether the squelch may record, and with what timing; holds off idle sleep
    /// while Auto is on and the radio runs.
    private func pushAutoRecord() {
        let config = AutoRecorder.Config(enabled: autoRecordEnabled && isRunning && squelchEnabled && sourceKind != .synthetic,
                                         timing: recording.autoTiming)
        if config != engine.autoRecorder.config { engine.autoRecorder.configure(config) }
        let hold = autoRecordEnabled && isRunning
        if hold, sleepActivity == nil {
            sleepActivity = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "Auto-record is listening")
        } else if !hold, let activity = sleepActivity {
            ProcessInfo.processInfo.endActivity(activity)
            sleepActivity = nil
        }
    }

    static let lowDiskBytes: Int64 = 500_000_000
    static let lowDiskMessage = "Less than 500 MB free where recordings go."
    static let autoOffLowDiskReason = "less than 100 MB free"

    /// Once a minute while Auto is on.
    private func checkRecordingsDiskSpaceIfDue() {
        guard autoRecordEnabled else { return }
        if let last = lastDiskCheck, ContinuousClock.now - last < .seconds(60) { return }
        checkRecordingsDiskSpace()
    }

    /// Under 500 MB free where recordings go: a warning, once per crossing. Under 100 MB: Auto turns
    /// off and ends its recording, rather than fail on every transmission. A manual recording runs on.
    func checkRecordingsDiskSpace() {
        guard autoRecordEnabled else { return }
        lastDiskCheck = .now
        guard let free = freeSpaceProbe(recording.folder) else { return }
        if free < 100_000_000 {
            autoRecordEnabled = false
            if engine.audioRecorder.sessionKind == .auto { engine.audioRecorder.stop() }
            // Logged before the banner, so a failed log write cannot replace it.
            appendToLog([.autoOff(at: Date(), reason: Self.autoOffLowDiskReason)])
            show(Banner(kind: .error, message: "Auto-record is off: less than 100 MB free where recordings go."))
        } else if free < Self.lowDiskBytes {
            if !diskLow { show(Banner(kind: .warning, message: Self.lowDiskMessage)) }
            diskLow = true
        } else {
            diskLow = false
        }
    }

    /// Free bytes for important use on the volume of `folder`, or of its nearest existing parent.
    nonisolated static func freeSpace(at folder: URL) -> Int64? {
        var url = folder.standardizedFileURL
        while !FileManager.default.fileExists(atPath: url.path), url.pathComponents.count > 1 { url.deleteLastPathComponent() }
        return try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
    }

    // MARK: Multi-signal modem

    /// The modem settings as the panel shows them: FT8/WSPR (`slotModesEnabled`) are off for file
    /// sources. (The engine also gets the decode band; see `ModemControl.engineSettings`.)
    var modemSettings: ModemSettings {
        var s = modemUserSettings
        s.slotModesEnabled = sourceKind != .file
        return s
    }
    /// False when none of the passband can be decoded or the box is outside the capture span (the
    /// engine gets no box; decoding stops).
    var modemBoxActive: Bool {
        modemAudioBand != nil && modemBox.isInside(captureCenter: centerHz, captureSpan: sampleRate)
    }
    /// ←/→ nudge the modem cursor and Esc unlocks it (`KeyCommand`).
    var modemKeysActive: Bool { modemUserSettings.mode != nil && modemBoxActive }

    /// The modem panel's control-strip state (`ModemPanelStatus`).
    var modemPanelStatus: ModemPanelStatus {
        ModemPanelStatus(mode: modemUserSettings.mode, autoDetect: modemUserSettings.autoDetect,
                         isFileSource: sourceKind == .file, boxActive: modemBoxActive, clockOffset: clockOffset,
                         audioBand: modemAudioBand, slotOutcomes: slotOutcomes)
    }

    /// "3 signals": the live rows (read by its own small view, so the log's 10 Hz changes don't
    /// re-render the control strip).
    var modemSignalCountText: String { ModemPanelFormat.signalCount(decodeLog.liveRows.count) }

    /// The decode band (inside the passband) in view fractions, while the modem is on and the box
    /// active: clicks inside it lock the cursor; elsewhere they tune the VFO.
    var modemBoxFractions: (lower: Double, upper: Double)? {
        guard modemUserSettings.mode != nil, modemBoxActive, let band = modemAudioBand else { return nil }
        return (viewport.fraction(ofHz: modemBox.rfHz(forAudio: band.lowerBound)),
                viewport.fraction(ofHz: modemBox.rfHz(forAudio: band.upperBound)))
    }

    func setModemMode(_ m: ModeID?) {
        changeModem { $0.setMode(m) }
        if m != nil { startClockCheckIfNeeded() }
    }

    func lockModemCursor(atRF rf: Double) {
        let active = modemBoxActive
        changeModem { $0.lock(atRF: rf, boxActive: active) }
    }

    /// A click inside the box: locks the cursor there, or unlocks it when on the cursor.
    func clickInModemBox(atFraction f: Double) {
        let rf = viewport.hz(atFraction: f), span = viewport.spanHz, active = modemBoxActive
        changeModem { $0.click(atRF: rf, spanHz: span, boxActive: active) }
    }

    func unlockModemCursor() { changeModem { $0.unlock() } }

    func nudgeModemCursor(_ steps: Int) {
        let active = modemBoxActive
        changeModem { $0.nudge(steps, boxActive: active) }
    }

    /// Clicking a row locks the cursor on its signal; clicking the cursor's row unlocks it.
    func selectRow(_ id: Int) {
        guard let row = liveLog.row(forTrack: id) ?? liveLog.slotRows.first(where: { $0.id == id }) else { return }
        let active = modemBoxActive
        changeModem { $0.select(row, boxActive: active) }
    }

    /// Set while the pointer is over the rows: new rows wait (`DecodeLog.holdNew`).
    func setRowHold(_ on: Bool) {
        guard liveLog.holdNew != on else { return }
        liveLog.holdNew = on
        liveLogChanged = true
        publishLog()
    }

    func releaseHeldRows() {
        liveLog.releaseHeld()
        liveLogChanged = true
        publishLog()
    }

    /// Test seam: adopts `kind` as the running source's kind without starting anything.
    func setSourceKindForTesting(_ kind: SourceKind) {
        sourceKind = kind
        syncModem()
        pushAutoRecord()
    }

    /// Applies `change` to the modem state and brings the engine up to date. The state is written
    /// back only when it changed, so observers are not woken for nothing.
    private func changeModem(_ change: (inout ModemControl) -> Void) {
        var m = modem
        change(&m)
        syncModem(&m)
    }

    private func syncModem() {
        var m = modem
        syncModem(&m)
    }

    private func syncModem(_ m: inout ModemControl) {
        let updates = m.sync(engine, captureCenter: centerHz, captureSpan: sampleRate, isFileSource: sourceKind == .file)
        if let hook = onModemEngineUpdate { updates.forEach(hook) }
        setModem(m)
    }

    /// Stores the modem state and publishes the parts views read, each only when it changed.
    private func setModem(_ m: ModemControl) {
        if m != modem { modem = m }
        if m.box != modemBox { modemBox = m.box }
        if m.settings != modemUserSettings { modemUserSettings = m.settings }
        if m.cursorAudioHz != modemCursorAudioHz { modemCursorAudioHz = m.cursorAudioHz }
        if m.audioBand != modemAudioBand { modemAudioBand = m.audioBand }
    }

    /// The 10 Hz drain of the engine's modem output into the rows.
    private func pumpModem() {
        let batch = engine.modemEvents.drain()
        var m = modem
        if batch.isEmpty {
            m.observeEpoch(batch.epoch)
        } else {
            m.take(batch, into: &liveLog, now: engine.modemWorker.utcNow())
            liveLogChanged = true
            var outcomes = batch.clearedAt == nil ? slotOutcomes : [:]
            for o in batch.slotOutcomes where (outcomes[o.mode]?.slotStart ?? .distantPast) <= o.slotStart {
                outcomes[o.mode] = o
            }
            if outcomes != slotOutcomes { slotOutcomes = outcomes }
        }
        setModem(m)
    }

    /// Shows `liveLog` (when it changed since last shown).
    private func publishLog() {
        guard liveLogChanged else { return }
        liveLogChanged = false
        decodeLog = liveLog
        let ticks = liveLog.liveRows.map(\.frequencyHz)
        if ticks.map({ $0.rounded() }) != modemTrackAudioHz.map({ $0.rounded() }) { modemTrackAudioHz = ticks }
    }

    /// Measures the clock offset once, the first time the modem is on with the radio running.
    private func startClockCheckIfNeeded() {
        guard isRunning, modem.settings.mode != nil, !clockCheckStarted else { return }
        clockCheckStarted = true
        Task { [weak self] in
            let offset = await ClockCheck.offsetSeconds()
            self?.clockOffset = offset
        }
    }

    // MARK: Stats & persistence

    /// 10 Hz: the engine's modem output is drained every tick, and everything shown changes together
    /// every other tick (5 Hz), since each tick that assigns an observed property costs a SwiftUI
    /// update pass over the window. Observed properties are assigned only when their shown value
    /// changes: every assignment re-renders the views that read them, even with the same value.
    private func refreshStats() {
        pumpModem()
        statsTicks += 1
        guard statsTicks % 2 == 0 else { return }
        publishLog()
        let db = engine.stats.withLock { $0.signalDb }
        if (db * 2).rounded() != (signalDb * 2).rounded() { signalDb = db }
        let lostBlocks = engine.audio.underruns.load(ordering: .relaxed)
        if lostBlocks != underruns { underruns = lostBlocks }
        let cpuNow = cpu.sample()
        if cpuNow.rounded() != cpuPercent.rounded() { cpuPercent = cpuNow }
        refreshRecordingStatus()
        checkRecordingsDiskSpaceIfDue()
        saveSessionIfChanged()
    }

    private func saveSessionIfChanged() {
        let state = SessionState(vfoHz: vfoHz, centerHz: centerHz, mode: mode, bandwidthHz: bandwidthHz, upconverter: upconverter,
                                 hardware: hardware, spectrum: spectrum, dbMin: dbMin, dbMax: dbMax, colormap: colormap,
                                 showBookmarks: showBookmarks, volume: volume, agcSpeed: agcSpeed, cwPitchHz: cwPitchHz,
                                 preferredSource: preferredSource == .file ? .sdrplay : preferredSource,
                                 modemBox: nil, modemSettings: modem.settings, recording: recording,
                                 autoRecord: autoRecordEnabled, squelchEnabled: squelchEnabled, squelchDb: squelchDb,
                                 noiseReduction: noiseReduction, skipSilence: skipSilence,
                                 transcription: transcriptionSettings)
        guard let data = try? JSONEncoder().encode(state), data != lastSavedSession else { return }
        defaults.set(data, forKey: "session")
        lastSavedSession = data
    }

    private func restoreSession() {
        guard let data = defaults.data(forKey: "session"),
              let s = try? JSONDecoder().decode(SessionState.self, from: data) else { return }
        vfoHz = s.vfoHz; centerHz = s.centerHz; mode = s.mode; bandwidthHz = s.bandwidthHz
        upconverter = s.upconverter; hardware = s.hardware; spectrum = s.spectrum
        dbMin = s.dbMin; dbMax = s.dbMax; colormap = s.colormap; showBookmarks = s.showBookmarks
        volume = s.volume; agcSpeed = s.agcSpeed; cwPitchHz = s.cwPitchHz; preferredSource = s.preferredSource
        // The box follows the passband (`followPassband`, after this); a saved box is not used.
        setModem(ModemControl(box: modem.box, settings: s.modemSettings ?? modem.settings))
        if let r = s.recording { recording = r }
        if let on = s.squelchEnabled { squelchEnabled = on }
        if let db = s.squelchDb { squelchDb = db }
        if let on = s.autoRecord { autoRecordEnabled = on }
        if let on = s.skipSilence { skipSilence = on }
        if let t = s.transcription { transcriptionSettings = t }
        // Last: it saves the session, which must be whole by then.
        if let nr = s.noiseReduction { noiseReduction = nr }
        lastSavedSession = data
    }
}
