import DSPCore
import Foundation
import Observation
import SystemConfiguration

/// The SubFloor Dial: finds it on USB and Bluetooth, applies its knob to the radio and keeps its
/// display in step with SubFloor. USB wins when both links are up (the dial sends its events only
/// on the link SubFloor last greeted, so it is never heard twice).
@MainActor @Observable
final class DialController {
    enum Transport: String { case usb = "USB", bluetooth = "Bluetooth" }

    enum Status: Equatable {
        case off, searching, pairing
        case connected(Transport)
    }

    /// What the dial did last, for the HUD.
    enum Action: Equatable { case tune, step, mode, bandwidth }

    private(set) var status: Status = .off
    private(set) var firmware = ""
    /// The dial's tuning step: SubFloor underlines that digit of the readout.
    private(set) var stepHz: Double = 100
    private(set) var knob: DialProtocol.Knob = .tune
    private(set) var toastVisible = false
    private(set) var bluetoothState: DialBluetoothLink.State = .off

    // The HUD reads these; nothing else should (they change with every detent).
    private(set) var hudVisible = false
    private(set) var hudRotation: Double = 0
    private(set) var lastAction: Action = .tune
    private(set) var activity = 0

    var useBluetooth: Bool { didSet { defaults.set(useBluetooth, forKey: "dialUseBluetooth"); applyLinkSettings() } }
    var useUSB: Bool {
        didSet {
            defaults.set(useUSB, forKey: "dialUseUSB")
            ignoredPorts.removeAll()
            applyLinkSettings()
        }
    }

    var isConnected: Bool { if case .connected = status { true } else { false } }
    var transport: Transport? { if case .connected(let t) = status { t } else { nil } }
    /// The power of ten of the step (the readout digit it tunes).
    var stepPower: Int { max(0, min(9, Int(log10(stepHz).rounded()))) }

    @ObservationIgnored private let model: AppModel
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var bluetooth: DialBluetoothLink?
    @ObservationIgnored private var serial: DialSerialLink?
    @ObservationIgnored private var serialOpenedAt: Date?
    @ObservationIgnored private var confirmed: Set<Transport> = []
    @ObservationIgnored private var active: Transport?
    @ObservationIgnored private var lastHeard: [Transport: Date] = [:]
    @ObservationIgnored private var ignoredPorts: [String: Date] = [:]
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var ticks = 0
    @ObservationIgnored private var sent = SentState()
    @ObservationIgnored private var hudTask: Task<Void, Never>?
    @ObservationIgnored private var toastTask: Task<Void, Never>?

    /// What the dial was last told, so only changes are sent.
    private struct SentState {
        var vfoHz: Double?
        var mode: DemodMode?
        var bandwidthHz: Double?
        var running: Bool?
        var signalDb: Float?
    }

    init(model: AppModel, defaults: UserDefaults = .standard) {
        self.model = model
        self.defaults = defaults
        useBluetooth = defaults.object(forKey: "dialUseBluetooth") as? Bool ?? true
        useUSB = defaults.object(forKey: "dialUseUSB") as? Bool ?? true
    }

    func start() {
        guard timer == nil else { return }
        applyLinkSettings()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func shutdown() {
        send(DialProtocol.bye)
        serial?.close()
        bluetooth?.stop()
    }

    /// Take the next dial that is pairing over Bluetooth.
    func pairNewDial() {
        if !useBluetooth { useBluetooth = true }
        bluetooth?.pairNewDial()
        updateStatus()
    }

    func forgetDial() {
        bluetooth?.forgetDial()
        updateStatus()
    }

    var bluetoothDialName: String? { bluetooth?.peripheralName }
    var hasKnownBluetoothDial: Bool { bluetooth?.knownDial != nil }

    // MARK: Links

    private func applyLinkSettings() {
        if useBluetooth, bluetooth == nil {
            let link = DialBluetoothLink(
                defaults: defaults,
                onLine: { [weak self] in self?.received($0, on: .bluetooth) },
                onState: { [weak self] in self?.bluetoothChanged($0) })
            bluetooth = link
            link.start()
        } else if !useBluetooth, let link = bluetooth {
            link.stop()
            bluetooth = nil
            linkLost(.bluetooth)
        }
        if !useUSB, let s = serial {
            s.close()
            serial = nil
            linkLost(.usb)
        }
        updateStatus()
    }

    private func bluetoothChanged(_ state: DialBluetoothLink.State) {
        bluetoothState = state
        if state == .ready {
            // Greet over Bluetooth only when USB isn't carrying the dial.
            if active != .usb { bluetooth?.send(DialProtocol.hello(host: Self.hostName)) }
        } else {
            linkLost(.bluetooth)
        }
        updateStatus()
    }

    private func openSerialIfNeeded() {
        guard useUSB, serial == nil else { return }
        let now = Date()
        let ports = DialSerialLink.candidatePorts()
        // A port stays ignored until it expires or is unplugged.
        ignoredPorts = ignoredPorts.filter { $0.value > now && ports.contains($0.key) }
        guard let path = ports.first(where: { ignoredPorts[$0] == nil }) else { return }
        let link = DialSerialLink(path: path,
                                  onLine: { [weak self] in self?.received($0, on: .usb) },
                                  onClose: { [weak self] in self?.serialClosed(path) })
        guard link.open() else {
            ignoredPorts[path] = now.addingTimeInterval(10)
            return
        }
        serial = link
        serialOpenedAt = now
        link.send(DialProtocol.hello(host: Self.hostName))
    }

    private func serialClosed(_ path: String) {
        guard serial?.path == path else { return }
        serial = nil
        linkLost(.usb)
    }

    private func linkLost(_ t: Transport) {
        confirmed.remove(t)
        lastHeard[t] = nil
        guard active == t else { return }
        active = nil
        // Fall back to the other link if it is up.
        if t == .usb, bluetoothState == .ready { bluetooth?.send(DialProtocol.hello(host: Self.hostName)) }
        updateStatus()
    }

    private func sendOn(_ t: Transport, _ line: String) {
        switch t {
        case .usb: serial?.send(line)
        case .bluetooth: bluetooth?.send(line)
        }
    }

    private func send(_ line: String) {
        if let active { sendOn(active, line) }
    }

    private func updateStatus() {
        let new: Status
        if let active { new = .connected(active) }
        else if bluetooth?.acceptingNewDial == true { new = .pairing }
        else if useBluetooth || useUSB { new = .searching }
        else { new = .off }
        guard new != status else { return }
        let wasConnected = isConnected
        status = new
        if isConnected && !wasConnected { showToast() }
    }

    private func showToast() {
        toastVisible = true
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.8))
            guard !Task.isCancelled else { return }
            self?.toastVisible = false
        }
    }

    // MARK: Dial → SubFloor

    private func received(_ line: String, on t: Transport) {
        lastHeard[t] = Date()
        guard let event = DialProtocol.parse(line) else { return }
        if case .hello(let fw, let step, let knob) = event {
            confirmed.insert(t)
            if t == .bluetooth { bluetooth?.confirmDial() }
            // USB is preferred: Bluetooth only becomes active while USB isn't.
            guard t == .usb || active != .usb else { return }
            firmware = fw
            stepHz = step
            self.knob = knob
            active = t
            sent = SentState()
            sendState()
            updateStatus()
            return
        }
        guard t == active else { return }
        apply(event)
    }

    private func apply(_ event: DialProtocol.Event) {
        switch event {
        case .tune(let seq, let steps, let step):
            model.stepVFO(steps, stepHz: step)
            if step != stepHz { stepHz = step }
            send(DialProtocol.frequency(model.vfoHz, seq: seq))
            sent.vfoHz = model.vfoHz
            noteActivity(.tune, rotation: Double(steps))
        case .bandwidth(let steps):
            model.stepBandwidth(steps)
            send(DialProtocol.bandwidth(model.bandwidthHz))
            sent.bandwidthHz = model.bandwidthHz
            noteActivity(.bandwidth, rotation: Double(steps))
        case .step(let hz):
            stepHz = hz
            noteActivity(.step)
        case .mode(let m):
            model.setMode(m)
            noteActivity(.mode)
        case .knob(let k):
            knob = k
            noteActivity(k == .bandwidth ? .bandwidth : .tune)
        case .hello, .pong:
            break
        }
    }

    private func noteActivity(_ action: Action, rotation detents: Double = 0) {
        if lastAction != action { lastAction = action }
        // The HUD's ring turns the way the dial's scale does: against the knob.
        if detents != 0 { hudRotation -= 6 * max(-20, min(20, detents)) }
        activity &+= 1
        if !hudVisible { hudVisible = true }
        hudTask?.cancel()
        hudTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.8))
            guard !Task.isCancelled else { return }
            self?.hudVisible = false
        }
    }

    // MARK: SubFloor → dial

    private func sendState() {
        send(DialProtocol.state(vfoHz: model.vfoHz, mode: model.mode, bandwidthHz: model.bandwidthHz, running: model.isRunning))
        send(DialProtocol.signal(model.signalDb))
        sent = SentState(vfoHz: model.vfoHz, mode: model.mode, bandwidthHz: model.bandwidthHz,
                         running: model.isRunning, signalDb: model.signalDb)
    }

    private func tick() {
        ticks += 1
        let now = Date()
        if serial == nil, ticks % 15 == 0 { openSerialIfNeeded() }
        // A port that never answered HELLO isn't a dial (another Espressif board, say): it is left
        // alone until it is plugged in again.
        if let s = serial, !confirmed.contains(.usb), let opened = serialOpenedAt, now.timeIntervalSince(opened) > 3 {
            s.close()
            serial = nil
            ignoredPorts[s.path] = .distantFuture
        }
        guard let active else { return }
        if let heard = lastHeard[active], now.timeIntervalSince(heard) > 5 {
            // Silent for too long (PING is answered every 1.5 s): start over on that link.
            if active == .usb { serial?.close(); serial = nil }
            linkLost(active)
            return
        }
        if ticks % 15 == 0 { send(DialProtocol.ping) }

        if model.vfoHz != sent.vfoHz {
            send(DialProtocol.frequency(model.vfoHz))
            sent.vfoHz = model.vfoHz
        }
        if model.mode != sent.mode {
            send(DialProtocol.mode(model.mode))
            sent.mode = model.mode
        }
        if model.bandwidthHz != sent.bandwidthHz {
            send(DialProtocol.bandwidth(model.bandwidthHz))
            sent.bandwidthHz = model.bandwidthHz
        }
        if model.isRunning != sent.running {
            send(DialProtocol.state(vfoHz: model.vfoHz, mode: model.mode, bandwidthHz: model.bandwidthHz, running: model.isRunning))
            sent.running = model.isRunning
        }
        if let db = sent.signalDb, abs(db - model.signalDb) < 0.5 {} else {
            send(DialProtocol.signal(model.signalDb))
            sent.signalDb = model.signalDb
        }
    }

    private static let hostName: String = {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? Host.current().localizedName ?? "Mac"
    }()
}
