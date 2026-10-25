import CoreBluetooth
import Foundation

/// The dial over Bluetooth LE. SubFloor remembers the dial it last talked to and reconnects to it
/// whenever it is in range; with none remembered (or after "Pair New Dial") it takes the first dial
/// that is pairing. The dial asks the Mac to bond when it connects, so macOS may ask to confirm.
@MainActor
final class DialBluetoothLink: NSObject {
    enum State: Equatable { case off, unauthorized, scanning, connecting, ready }

    static let service = CBUUID(string: "7b6f0001-5d3c-4a8e-9d2b-53554246444c")
    static let rxUUID = CBUUID(string: "7b6f0002-5d3c-4a8e-9d2b-53554246444c")
    static let txUUID = CBUUID(string: "7b6f0003-5d3c-4a8e-9d2b-53554246444c")
    private static let knownKey = "dialPeripheralID"

    private(set) var state: State = .off { didSet { if state != oldValue { onState(state) } } }
    /// True while taking a new dial (one advertising that it is pairing), not only the known one.
    private(set) var acceptingNewDial = false

    private let onLine: (String) -> Void
    private let onState: (State) -> Void
    private let defaults: UserDefaults
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var rx: CBCharacteristic?
    private var splitter = LineSplitter()
    private var pending: [Data] = []
    private var connectedAt: Date?
    private var heardFromDial = false
    /// Dials that dropped us straight after connecting (paired to another Mac): left alone a while.
    private var backoff: [UUID: Date] = [:]
    private var acceptUntil: Date?

    init(defaults: UserDefaults = .standard, onLine: @escaping (String) -> Void, onState: @escaping (State) -> Void) {
        self.defaults = defaults
        self.onLine = onLine
        self.onState = onState
    }

    var knownDial: UUID? {
        get { defaults.string(forKey: Self.knownKey).flatMap(UUID.init(uuidString:)) }
        set { defaults.set(newValue?.uuidString, forKey: Self.knownKey) }
    }

    var peripheralName: String? { peripheral?.name }

    func start() {
        guard central == nil else { return }
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func stop() {
        if let p = peripheral { central?.cancelPeripheralConnection(p) }
        central?.stopScan()
        central = nil
        peripheral = nil
        rx = nil
        state = .off
    }

    /// Take the next dial that is pairing (the dial's Bluetooth › Pair new Mac), for two minutes.
    func pairNewDial() {
        knownDial = nil
        acceptingNewDial = true
        acceptUntil = Date().addingTimeInterval(120)
        backoff.removeAll()
        if let p = peripheral { central?.cancelPeripheralConnection(p) } else { discover() }
    }

    func forgetDial() {
        knownDial = nil
        acceptingNewDial = false
        if let p = peripheral { central?.cancelPeripheralConnection(p) }
    }

    /// The dial answered HELLO on this link: it is the dial SubFloor reconnects to from now on.
    func confirmDial() {
        heardFromDial = true
        guard let p = peripheral else { return }
        knownDial = p.identifier
        acceptingNewDial = false
    }

    func send(_ line: String) {
        guard state == .ready, let p = peripheral, let rx else { return }
        let data = Data((line + "\n").utf8)
        let max = Swift.max(20, p.maximumWriteValueLength(for: .withoutResponse))
        var i = data.startIndex
        while i < data.endIndex {
            let end = data.index(i, offsetBy: max, limitedBy: data.endIndex) ?? data.endIndex
            pending.append(data[i..<end])
            i = end
        }
        flush(p, rx)
    }

    private func flush(_ p: CBPeripheral, _ rx: CBCharacteristic) {
        while !pending.isEmpty && p.canSendWriteWithoutResponse {
            p.writeValue(pending.removeFirst(), for: rx, type: .withoutResponse)
        }
        if pending.count > 64 { pending.removeFirst(pending.count - 64) }  // stale state; newer lines follow
    }

    private func discover() {
        guard let central, central.state == .poweredOn, peripheral == nil else { return }
        if let until = acceptUntil, until < Date() {
            acceptingNewDial = false
            acceptUntil = nil
        }
        if let id = knownDial, !acceptingNewDial, let p = central.retrievePeripherals(withIdentifiers: [id]).first {
            // A pending connect: it completes whenever the dial is in range, no scanning needed.
            connect(p)
            return
        }
        state = .scanning
        central.scanForPeripherals(withServices: [Self.service], options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    private func connect(_ p: CBPeripheral) {
        central?.stopScan()
        peripheral = p
        p.delegate = self
        state = .connecting
        heardFromDial = false
        connectedAt = nil
        central?.connect(p)
    }

    private func dropped(_ p: CBPeripheral) {
        if let at = connectedAt, Date().timeIntervalSince(at) < 6, !heardFromDial {
            backoff[p.identifier] = Date().addingTimeInterval(20)
        }
        peripheral = nil
        rx = nil
        pending.removeAll()
        splitter = LineSplitter()
        state = .scanning
        discover()
    }
}

// CoreBluetooth calls these on the main queue (the manager's queue).
extension DialBluetoothLink: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn: discover()
        case .unauthorized: state = .unauthorized
        default:
            peripheral = nil
            rx = nil
            state = .off
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let mfr = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        // 0xFFFF, "SF", then 1 while the dial is pairing.
        let pairing = mfr.map { $0.count >= 5 && $0[$0.startIndex + 2] == 0x53 && $0[$0.startIndex + 4] == 1 } ?? false
        guard self.peripheral == nil else { return }
        if let until = backoff[peripheral.identifier], until > Date() { return }
        let known = knownDial
        let take = peripheral.identifier == known || (acceptingNewDial ? pairing : known == nil)
        if take { connect(peripheral) }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectedAt = Date()
        peripheral.discoverServices([Self.service])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        dropped(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        dropped(peripheral)
    }
}

extension DialBluetoothLink: @preconcurrency CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let svc = peripheral.services?.first(where: { $0.uuid == Self.service }) else {
            central?.cancelPeripheralConnection(peripheral)
            return
        }
        peripheral.discoverCharacteristics([Self.rxUUID, Self.txUUID], for: svc)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        let chars = service.characteristics ?? []
        guard let rx = chars.first(where: { $0.uuid == Self.rxUUID }),
              let tx = chars.first(where: { $0.uuid == Self.txUUID }) else {
            central?.cancelPeripheralConnection(peripheral)
            return
        }
        self.rx = rx
        peripheral.setNotifyValue(true, for: tx)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                error: Error?) {
        if characteristic.isNotifying { state = .ready }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value else { return }
        for line in splitter.append(data) { onLine(line) }
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        if let rx { flush(peripheral, rx) }
    }
}
