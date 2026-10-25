import Foundation
import IOKit
import IOKit.serial

/// The dial on USB: an Espressif USB serial port (vendor 0x303A), read on its own queue. Lines and
/// the close arrive on the main queue, in order.
final class DialSerialLink: @unchecked Sendable {
    static let espressifVendorID = 0x303A

    let path: String
    private let queue = DispatchQueue(label: "SubFloor.dial.serial")
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private var splitter = LineSplitter()
    private let onLine: @MainActor (String) -> Void
    private let onClose: @MainActor () -> Void

    init(path: String, onLine: @escaping @MainActor (String) -> Void, onClose: @escaping @MainActor () -> Void) {
        self.path = path
        self.onLine = onLine
        self.onClose = onClose
    }

    /// Callout devices (`/dev/cu.*`) of every Espressif USB serial port.
    static func candidatePorts() -> [String] {
        guard let matching = IOServiceMatching(kIOSerialBSDServiceValue) else { return [] }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var ports: [String] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let path = IORegistryEntryCreateCFProperty(service, kIOCalloutDeviceKey as CFString,
                                                             kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
            else { continue }
            let vendor = IORegistryEntrySearchCFProperty(service, kIOServicePlane, "idVendor" as CFString, kCFAllocatorDefault,
                                                         IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents))
            if (vendor as? Int) == espressifVendorID { ports.append(path) }
        }
        return ports.sorted()
    }

    func open() -> Bool {
        let fd = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { return false }
        var t = termios()
        tcgetattr(fd, &t)
        cfmakeraw(&t)
        cfsetspeed(&t, speed_t(B115200))
        t.c_cflag |= tcflag_t(CLOCAL | CREAD)
        tcsetattr(fd, TCSANOW, &t)
        // DTR and RTS both on, as pyserial leaves them: the ESP32-S3's USB serial resets the chip
        // when RTS is on while DTR is off.
        var bits: Int32 = TIOCM_DTR | TIOCM_RTS
        _ = ioctl(fd, 0x8004_746C /* TIOCMBIS */, &bits)
        self.fd = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        source.setCancelHandler { Darwin.close(fd) }
        self.source = source
        source.resume()
        return true
    }

    func send(_ line: String) {
        let data = Array((line + "\n").utf8)
        queue.async { [weak self] in
            guard let self, self.fd >= 0 else { return }
            var offset = 0
            var spins = 0
            while offset < data.count {
                let n = data[offset...].withUnsafeBytes { Darwin.write(self.fd, $0.baseAddress, $0.count) }
                if n > 0 {
                    offset += n
                } else if n < 0 && errno == EAGAIN && spins < 50 {
                    spins += 1
                    usleep(1_000)
                } else {
                    return
                }
            }
        }
    }

    func close() {
        queue.async { [weak self] in self?.shutDown(notify: false) }
    }

    private func readAvailable() {
        var buf = [UInt8](repeating: 0, count: 1024)
        let n = Darwin.read(fd, &buf, buf.count)
        if n > 0 {
            let lines = splitter.append(Data(buf[0..<n]))
            guard !lines.isEmpty else { return }
            let onLine = self.onLine
            DispatchQueue.main.async { MainActor.assumeIsolated { lines.forEach(onLine) } }
        } else if n == 0 || (errno != EAGAIN && errno != EINTR) {
            shutDown(notify: true)  // unplugged
        }
    }

    private func shutDown(notify: Bool) {
        guard fd >= 0 else { return }
        source?.cancel()
        source = nil
        fd = -1
        if notify {
            let onClose = self.onClose
            DispatchQueue.main.async { MainActor.assumeIsolated { onClose() } }
        }
    }
}
