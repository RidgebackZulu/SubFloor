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
    private(set) var activeModem: (any Modem)?
    var activeModemID: String? { activeModem.map { type(of: $0).info.id } }
    var banner: Banner?
    var quickTuneVisible = false
    private(set) var signalDb: Float = -200
    private(set) var underruns = 0
    private(set) var cpuPercent: Double = 0
    private(set) var overloaded = false
    private var didAutoStart = false

    let engine = DSPEngine()
    private var sdrplay: SDRplayDevice?
    private let synthetic = SyntheticSource()
    private var fileSource: IQFileSource?
    private let bookmarkStore: BookmarkStore
    private let defaults: UserDefaults
    private var bookmarksSaveBlocked = false
    private var statsTimer: Timer?
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
            show(Banner(kind: .warning, message: "The bookmarks file was unreadable. It was backed up as bookmarks.corrupt-<timestamp>.json and the defaults were restored."))
        case .corruptNotPreserved:
            show(Banner(kind: .error, message: Self.bookmarksBlockedMessage))
            bookmarksSaveBlocked = true
        case .loaded, .createdDefaults:
            break
        }
        restoreSession()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
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
        if kind == .sdrplay && sdrplay == nil {
            do {
                let device = try SDRplayDevice.open()
                device.onEvent = { [weak self, weak device] event in
                    guard let self, let device else { return }
                    Task { @MainActor in self.handle(event, from: device) }
                }
                sdrplay = device
            } catch {
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
        do {
            try engine.start(source: activeSource, receiver: receiverConfig, spectrum: spectrum, volume: volume)
            isRunning = true
            deviceName = activeSource.name
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

    func retry() {
        banner = nil
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

    // MARK: Modems

    func activateModem(id: String?) {
        guard let id, let type = ModemRegistry.type(withID: id) else {
            activeModem = nil
            engine.modems.set(nil)
            return
        }
        let modem = type.init()
        activeModem = modem
        engine.modems.set(modem)
        if let preferred = type.info.preferredMode {
            setMode(preferred)
            if let bw = type.info.preferredBandwidth { setBandwidth(bw) }
        }
    }

    // MARK: Stats & persistence

    private func refreshStats() {
        signalDb = engine.stats.withLock { $0.signalDb }
        underruns = engine.audio.underruns.load(ordering: .relaxed)
        cpuPercent = cpu.sample()
        saveSessionIfChanged()
    }

    private func saveSessionIfChanged() {
        let state = SessionState(vfoHz: vfoHz, centerHz: centerHz, mode: mode, bandwidthHz: bandwidthHz, upconverter: upconverter,
                                 hardware: hardware, spectrum: spectrum, dbMin: dbMin, dbMax: dbMax, colormap: colormap,
                                 showBookmarks: showBookmarks, volume: volume, agcSpeed: agcSpeed, cwPitchHz: cwPitchHz,
                                 preferredSource: preferredSource == .file ? .sdrplay : preferredSource)
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
        lastSavedSession = data
    }
}
