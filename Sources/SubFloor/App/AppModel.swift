import AppKit
import DSPCore
import Modems
import Observation
import SDRplayKit
import SubFloorCore
import SwiftUI
import UniformTypeIdentifiers

enum BannerAction: Equatable { case retry, reduceGain }

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
    /// Optional so that sessions saved before the modem box still decode.
    var modemBox: ModemBox?
    var modemSettings: ModemSettings?
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
    var squelchEnabled = false { didSet { pushReceiver() } }
    var squelchDb: Float = -80 { didSet { pushReceiver() } }
    var agcSpeed: AGCSpeed = .medium { didSet { pushReceiver() } }
    var volume: Float = 0.5 { didSet { engine.update(volume: volume) } }

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

    let engine = DSPEngine()
    private var sdrplay: SDRplayDevice?
    private let synthetic = SyntheticSource()
    private var fileSource: IQFileSource?
    private let bookmarkStore: BookmarkStore
    private let defaults: UserDefaults
    private var bookmarksSaveBlocked = false
    private var statsTimer: Timer?
    private var statsTicks = 0
    private var cpu = CPUUsage()
    private var lastSavedSession: Data?

    convenience init() { self.init(bookmarkStore: BookmarkStore(url: BookmarkStore.defaultURL), defaults: .standard) }

    init(bookmarkStore: BookmarkStore, defaults: UserDefaults) {
        self.bookmarkStore = bookmarkStore
        self.defaults = defaults
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
        syncModem()
        engine.audio.onError = { [weak self] message in
            Task { @MainActor in self?.show(Banner(kind: .error, message: message, action: .retry)) }
        }
        // 10 Hz: the modem drain every tick, the other stats every other one.
        statsTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshStats() }
        }
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

    private func pushReceiver() { engine.update(receiver: receiverConfig) }

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

    func start() {
        stop()
        var kind = preferredSource
        if kind == .sdrplay && sdrplay == nil && rspOpenFailed {
            kind = .synthetic
        } else if kind == .sdrplay && sdrplay == nil {
            do {
                let device = try SDRplayDevice.open()
                device.onEvent = { [weak self, weak device] event in
                    guard let self, let device else { return }
                    Task { @MainActor in self.handle(event, from: device) }
                }
                sdrplay = device
            } catch {
                rspOpenFailed = true
                show(Banner(kind: .warning, message: "No RSP found — demo signal. \(error)", action: .retry))
                kind = .synthetic
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
        do {
            try engine.start(source: activeSource, receiver: receiverConfig, spectrum: spectrum, volume: volume)
            isRunning = true
            deviceName = activeSource.name
            startClockCheckIfNeeded()
        } catch {
            show(Banner(kind: .error, message: "Could not start: \(error)", action: .retry))
        }
    }

    func stop() {
        guard isRunning else { return }
        engine.stop()
        isRunning = false
        overloaded = false
    }

    /// Orderly shutdown (app quit): stop the engine, release the RSP, persist the session. Idempotent.
    func shutdown() {
        engine.stop()
        isRunning = false
        sdrplay?.close()
        sdrplay = nil
        saveSessionIfChanged()
        statsTimer?.invalidate()
        statsTimer = nil
    }

    func retry() {
        banner = nil
        rspOpenFailed = false
        if preferredSource == .sdrplay, let device = sdrplay {
            stop()
            device.close()
            sdrplay = nil
        }
        start()
    }

    func perform(_ action: BannerAction) {
        switch action {
        case .retry: retry()
        case .reduceGain:
            updateHardware { $0.ifGainReductionDb = min($0.ifGainReductionDb + 6, RSP1B.ifGainReductionRange.upperBound) }
            banner = nil
        }
    }

    func useSource(_ kind: SourceKind) {
        if kind == .file && fileSource == nil {
            openIQFile()
            return
        }
        preferredSource = kind
        if kind == .sdrplay {
            rspOpenFailed = false
        } else if sdrplay != nil {
            // Free the RSP for other apps while a different source is in use.
            stop()
            sdrplay?.close()
            sdrplay = nil
        }
        if isRunning || kind != .sdrplay { start() }
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

    /// Direct tune (typed frequency, quick-tune, bookmark): retunes hardware and resets the view.
    func tune(to displayHz: Double) {
        let hz = clampedDisplay(displayHz)
        vfoHz = hz
        if sourceKind == .file {
            vfoHz = min(max(hz, centerHz - sampleRate * 0.45), centerHz + sampleRate * 0.45)
        } else {
            centerHz = clampedCenter(TuningPlanner.center(forVFO: hz, sampleRate: sampleRate))
            retuneHardware()
        }
        viewport.setCapture(centerHz: centerHz, spanHz: sampleRate)
        viewport.reset()
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

    func select(_ bookmark: Bookmark) {
        setUpconverter(bookmark.upconverter)
        mode = bookmark.mode
        bandwidthHz = bookmark.bandwidthHz
        tune(to: bookmark.frequencyHz)
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

    // MARK: Multi-signal modem

    /// As sent to the engine: FT8/WSPR (`slotModesEnabled`) are off for file sources.
    var modemSettings: ModemSettings {
        ModemControl(settings: modemUserSettings).engineSettings(isFileSource: sourceKind == .file)
    }
    /// False when the box is outside the capture span (the engine gets no box; decoding stops).
    var modemBoxActive: Bool { modemBox.isInside(captureCenter: centerHz, captureSpan: sampleRate) }
    /// ←/→ nudge the modem cursor and Esc unlocks it (`KeyCommand`).
    var modemKeysActive: Bool { modemUserSettings.mode != nil && modemBoxActive }
    var modemGrabTabLabel: String { ModemControl(settings: modemUserSettings).grabTabLabel }

    /// The modem panel's control-strip state (`ModemPanelStatus`).
    var modemPanelStatus: ModemPanelStatus {
        ModemPanelStatus(mode: modemUserSettings.mode, autoDetect: modemUserSettings.autoDetect,
                         isFileSource: sourceKind == .file, boxActive: modemBoxActive, clockOffset: clockOffset,
                         box: modemBox)
    }

    /// "3 signals": the live rows (read by its own small view, so the log's 10 Hz changes don't
    /// re-render the control strip).
    var modemSignalCountText: String { ModemPanelFormat.signalCount(decodeLog.liveRows.count) }

    /// The box body in view fractions, while the modem is on and the box active (clicks inside
    /// it lock the cursor; elsewhere they tune the VFO).
    var modemBoxFractions: (lower: Double, upper: Double)? {
        guard modemUserSettings.mode != nil, modemBoxActive else { return nil }
        return (viewport.fraction(ofHz: modemBox.lowerHz), viewport.fraction(ofHz: modemBox.upperHz))
    }

    /// The grab tab's horizontal extent in view fractions, while the modem is on (an inactive box
    /// can still be dragged back). The spectrum view widens it to `SpectrumHitTest.minTabWidth`.
    var modemGrabTabFractions: (lower: Double, upper: Double)? {
        guard modemUserSettings.mode != nil else { return nil }
        return (viewport.fraction(ofHz: modemBox.lowerHz), viewport.fraction(ofHz: modemBox.upperHz))
    }

    func setModemMode(_ m: ModeID?) {
        changeModem { $0.setMode(m) }
        if m != nil { startClockCheckIfNeeded() }
    }

    func setAutoDetect(_ on: Bool) { changeModem { $0.setAutoDetect(on) } }
    func setAudioWide(_ on: Bool) { changeModem { $0.setAudioWide(on) } }

    /// Drags the box (never retunes); a box inside the capture span stays inside it.
    func moveModemBox(byHz hz: Double) {
        let center = centerHz, span = sampleRate
        changeModem { $0.moveBox(byHz: hz, captureCenter: center, captureSpan: span) }
    }

    func dragModemBox(byFraction f: Double) { moveModemBox(byHz: f * viewport.spanHz) }

    /// Centres the box on the view, clamped to the capture span.
    func recenterModemBox() {
        let view = viewport.centerHz, center = centerHz, span = sampleRate
        changeModem { $0.recenter(on: view, captureCenter: center, captureSpan: span) }
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
        saveSessionIfChanged()
    }

    private func saveSessionIfChanged() {
        let state = SessionState(vfoHz: vfoHz, centerHz: centerHz, mode: mode, bandwidthHz: bandwidthHz, upconverter: upconverter,
                                 hardware: hardware, spectrum: spectrum, dbMin: dbMin, dbMax: dbMax, colormap: colormap,
                                 showBookmarks: showBookmarks, volume: volume, agcSpeed: agcSpeed, cwPitchHz: cwPitchHz,
                                 preferredSource: preferredSource == .file ? .sdrplay : preferredSource,
                                 modemBox: modem.box, modemSettings: modem.settings)
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
        setModem(ModemControl(box: s.modemBox ?? modem.box, settings: s.modemSettings ?? modem.settings))
        lastSavedSession = data
    }
}
