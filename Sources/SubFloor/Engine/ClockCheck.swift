import Foundation

/// How far the system clock is from network time: one SNTP v4 query (RFC 4330) over UDP.
///
/// The offset is `((T2 − T1) + (T3 − T4)) / 2`, where T1 is when the request left, T2 when the
/// server received it, T3 when the server sent its reply and T4 when the reply arrived; it is what
/// to add to the system clock to get the server's time (positive: the system clock is behind).
///
/// A reply is used only if it is a well-formed server reply to this request (see `parseOffset`);
/// anything else, an unresolvable host, a socket error or no valid reply within `timeout` gives
/// nil. The query is plain BSD sockets, whose calls and constants are spelled the same against
/// Darwin and Glibc (the two constants whose types differ go through `cInt`).
enum ClockCheck {
    /// Seconds from the NTP era-0 epoch (1900-01-01) to the Unix epoch (1970-01-01).
    static let unixEpochOffset = 2_208_988_800.0
    static let packetSize = 48

    /// The system clock's offset from `server`, in seconds, or nil (see the type's notes). Runs the
    /// blocking query on a utility queue, never on the caller's executor.
    static func offsetSeconds(server: String = "time.apple.com", timeout: Double = 2) async -> Double? {
        await offsetSeconds(server: server, port: "123", timeout: timeout)
    }

    /// As `offsetSeconds(server:timeout:)`, on any UDP port (tests use a local responder).
    static func offsetSeconds(server: String, port: String, timeout: Double) async -> Double? {
        await withCheckedContinuation { (done: CheckedContinuation<Double?, Never>) in
            DispatchQueue.global(qos: .utility).async {
                done.resume(returning: query(server: server, port: port, timeout: timeout))
            }
        }
    }

    // MARK: Parsing

    /// The clock offset from a server's reply, or nil when the reply is not valid:
    /// - at least 48 bytes;
    /// - leap indicator not 3 (server clock unsynchronised);
    /// - version 3 or 4 (a server answers with the request's version, or 3 for an old one);
    /// - mode 4 (server);
    /// - stratum 1…15 (0 is a kiss-o'-death reply, 16 and up unsynchronised);
    /// - non-zero receive and transmit timestamps;
    /// - the originate timestamp equal to the transmit timestamp of the request (`t1`, to within
    ///   1 ms), so it answers this request and not a stray or spoofed one.
    ///
    /// `t1` and `t4` are Unix seconds (when the request left, when the reply arrived). Timestamps are
    /// read with RFC 4330's era rule: a seconds field with its top bit clear is in 2036–2104.
    static func parseOffset(response: [UInt8], t1: Double, t4: Double) -> Double? {
        guard response.count >= packetSize, t1.isFinite, t4.isFinite else { return nil }
        let leap = response[0] >> 6
        let version = (response[0] >> 3) & 0x7
        let mode = response[0] & 0x7
        let stratum = response[1]
        guard leap != 3, version == 3 || version == 4, mode == 4, (1...15).contains(stratum) else { return nil }
        guard let originate = timestamp(response, at: 24), abs(originate - t1) <= 1e-3,
              let t2 = timestamp(response, at: 32), let t3 = timestamp(response, at: 40) else { return nil }
        let offset = ((t2 - t1) + (t3 - t4)) / 2
        return offset.isFinite ? offset : nil
    }

    /// The 64-bit NTP timestamp at `offset` as Unix seconds; nil when it is zero (unset).
    static func timestamp(_ bytes: [UInt8], at offset: Int) -> Double? {
        var seconds: UInt32 = 0, fraction: UInt32 = 0
        for k in 0..<4 {
            seconds = seconds << 8 | UInt32(bytes[offset + k])
            fraction = fraction << 8 | UInt32(bytes[offset + 4 + k])
        }
        guard seconds != 0 || fraction != 0 else { return nil }
        // Era 0 (1900–2036) has the top bit set for every date after 1968; a clear bit is era 1.
        let era = seconds & 0x8000_0000 != 0 ? 0.0 : 4_294_967_296.0
        return Double(seconds) + era + Double(fraction) / 4_294_967_296.0 - unixEpochOffset
    }

    /// Writes Unix time `t` as a 64-bit NTP timestamp at `offset` (the era is implied, as on the wire).
    static func putTimestamp(_ t: Double, into bytes: inout [UInt8], at offset: Int) {
        let ntp = t + unixEpochOffset
        let whole = ntp.rounded(.down)
        let seconds = UInt32(truncatingIfNeeded: Int64(whole))
        let fraction = UInt32(min((ntp - whole) * 4_294_967_296.0, 4_294_967_295.0))
        for k in 0..<4 {
            bytes[offset + k] = UInt8(truncatingIfNeeded: seconds >> (24 - 8 * k))
            bytes[offset + 4 + k] = UInt8(truncatingIfNeeded: fraction >> (24 - 8 * k))
        }
    }

    /// A client request: LI 0, version 4, mode 3, transmit timestamp `t1`.
    static func request(t1: Double) -> [UInt8] {
        var packet = [UInt8](repeating: 0, count: packetSize)
        packet[0] = 0 << 6 | 4 << 3 | 3
        putTimestamp(t1, into: &packet, at: 40)
        return packet
    }

    // MARK: Network

    /// Blocking: resolves `server`, sends one request to each address in turn until one gives a valid
    /// reply, all within `timeout` seconds (name resolution itself is bounded only by the system
    /// resolver's own timeouts).
    static func query(server: String, port: String, timeout: Double) -> Double? {
        guard timeout > 0, timeout.isFinite else { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = cInt(SOCK_DGRAM)
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(server, port, &hints, &list) == 0, let first = list else { return nil }
        defer { freeaddrinfo(first) }
        var entry: UnsafeMutablePointer<addrinfo>? = first
        while let a = entry, Date() < deadline {
            if let offset = query(address: a.pointee, deadline: deadline) { return offset }
            entry = a.pointee.ai_next
        }
        return nil
    }

    /// One request to one resolved address; replies that fail validation are ignored until the
    /// deadline.
    private static func query(address a: addrinfo, deadline: Date) -> Double? {
        let fd = socket(a.ai_family, a.ai_socktype, a.ai_protocol)
        guard fd >= 0 else { return nil }
        defer { _ = close(fd) }
        // Connected, so the kernel only delivers datagrams from the server's address.
        guard connect(fd, a.ai_addr, a.ai_addrlen) == 0 else { return nil }
        let t1 = Date().timeIntervalSince1970
        let packet = request(t1: t1)
        let sent = packet.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
        guard sent == packet.count else { return nil }
        var reply = [UInt8](repeating: 0, count: 512)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return nil }
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&p, 1, Int32(min((remaining * 1_000).rounded(.up), 60_000)))
            guard ready > 0 else {
                if ready < 0, errno == EINTR { continue }
                return nil
            }
            let n = reply.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
            let t4 = Date().timeIntervalSince1970
            guard n >= 0 else { return nil }
            if let offset = parseOffset(response: Array(reply[0..<n]), t1: t1, t4: t4) { return offset }
        }
    }
}

/// A C int from a socket constant: plain `Int32` on Darwin, an imported enum (`__socket_type`) on
/// Glibc. Overload resolution picks whichever applies, so the call reads the same on both.
func cInt(_ x: Int32) -> Int32 { x }

func cInt<T: RawRepresentable>(_ x: T) -> Int32 where T.RawValue: BinaryInteger { Int32(x.rawValue) }
