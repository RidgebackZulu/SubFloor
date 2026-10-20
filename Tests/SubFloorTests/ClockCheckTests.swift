import Foundation
import Synchronization
import Testing
@testable import SubFloor

// MARK: - Packets

/// A server reply: LI/version/mode in byte 0, stratum, and the originate, receive and transmit
/// timestamps (Unix seconds).
private func reply(leap: UInt8 = 0, version: UInt8 = 4, mode: UInt8 = 4, stratum: UInt8 = 2,
                   originate: Double, receive: Double, transmit: Double) -> [UInt8] {
    var p = [UInt8](repeating: 0, count: ClockCheck.packetSize)
    p[0] = leap << 6 | version << 3 | mode
    p[1] = stratum
    p[2] = 6       // poll
    p[3] = 0xEC    // precision, -20
    ClockCheck.putTimestamp(receive - 1, into: &p, at: 16)   // reference
    ClockCheck.putTimestamp(originate, into: &p, at: 24)
    ClockCheck.putTimestamp(receive, into: &p, at: 32)
    ClockCheck.putTimestamp(transmit, into: &p, at: 40)
    return p
}

// MARK: - Local responder

/// A UDP SNTP responder on 127.0.0.1 (ephemeral port) for `ClockCheck.query`, on its own thread.
/// `respond` turns the request and the receive time into the reply (nil: stay silent).
private final class Responder: @unchecked Sendable {
    let port: String
    private let fd: Int32
    private let running = Atomic<Bool>(true)
    private let done = DispatchSemaphore(value: 0)
    let requests = Atomic<Int>(0)

    init?(respond: @escaping @Sendable (_ request: [UInt8], _ receivedAt: Double) -> [UInt8]?) {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = cInt(SOCK_DGRAM)
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo("127.0.0.1", "0", &hints, &list) == 0, let a = list else { return nil }
        defer { freeaddrinfo(a) }
        let s = socket(a.pointee.ai_family, a.pointee.ai_socktype, a.pointee.ai_protocol)
        guard s >= 0 else { return nil }
        guard bind(s, a.pointee.ai_addr, a.pointee.ai_addrlen) == 0 else {
            _ = close(s)
            return nil
        }
        var storage = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let named = withUnsafeMutablePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(s, $0, &length) }
        }
        guard named == 0 else {
            _ = close(s)
            return nil
        }
        let bound = withUnsafePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt16(bigEndian: $0.pointee.sin_port) }
        }
        fd = s
        port = String(bound)
        let thread = Thread { [self] in
            var buffer = [UInt8](repeating: 0, count: 512)
            while running.load(ordering: .acquiring) {
                var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                guard poll(&p, 1, 20) > 0 else { continue }
                var peer = sockaddr_storage()
                var peerLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
                let n = buffer.withUnsafeMutableBytes { b in
                    withUnsafeMutablePointer(to: &peer) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            recvfrom(fd, b.baseAddress, b.count, 0, $0, &peerLength)
                        }
                    }
                }
                let t2 = Date().timeIntervalSince1970
                guard n > 0 else { continue }
                requests.add(1, ordering: .relaxed)
                guard let out = respond(Array(buffer[0..<n]), t2) else { continue }
                _ = out.withUnsafeBytes { o in
                    withUnsafePointer(to: &peer) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            sendto(fd, o.baseAddress, o.count, 0, $0, peerLength)
                        }
                    }
                }
            }
            done.signal()
        }
        thread.start()
    }

    func stop() {
        running.store(false, ordering: .releasing)
        done.wait()
        _ = close(fd)
    }
}

/// The request's transmit timestamp (what a server copies into the originate field).
private func transmitTime(_ request: [UInt8]) -> Double? {
    request.count >= ClockCheck.packetSize ? ClockCheck.timestamp(request, at: 40) : nil
}

// MARK: - Tests

@Suite struct ClockCheckTests {
    /// RFC 4330: offset = ((T2 − T1) + (T3 − T4)) / 2, from a hand-built 48-byte reply.
    @Test func sntpParse() throws {
        let t1 = 1_800_000_000.25
        let t2 = t1 + 5.1, t3 = t2 + 0.001
        let t4 = t1 + 0.2
        let p = reply(originate: t1, receive: t2, transmit: t3)
        #expect(p.count == 48)
        let offset = try #require(ClockCheck.parseOffset(response: p, t1: t1, t4: t4))
        #expect(abs(offset - ((t2 - t1) + (t3 - t4)) / 2) < 1e-5)
        #expect(abs(offset - 5.0005) < 1e-5)
        // A clock that is ahead gives a negative offset.
        let behind = reply(originate: t1, receive: t1 - 2.95, transmit: t1 - 2.95)
        let negative = try #require(ClockCheck.parseOffset(response: behind, t1: t1, t4: t1 + 0.1))
        #expect(abs(negative - (-3.0)) < 1e-5)
        // Version 3 servers are accepted; longer packets (extension fields, MAC) too.
        #expect(ClockCheck.parseOffset(response: reply(version: 3, originate: t1, receive: t2, transmit: t3), t1: t1, t4: t4) != nil)
        #expect(ClockCheck.parseOffset(response: p + [UInt8](repeating: 0, count: 20), t1: t1, t4: t4) != nil)
    }

    @Test func sntpRejectsInvalidReplies() {
        let t1 = 1_800_000_000.0, t2 = t1 + 0.05, t4 = t1 + 0.1
        func parse(_ p: [UInt8]) -> Double? { ClockCheck.parseOffset(response: p, t1: t1, t4: t4) }
        #expect(parse(reply(originate: t1, receive: t2, transmit: t2)) != nil)
        #expect(parse(reply(mode: 3, originate: t1, receive: t2, transmit: t2)) == nil, "client mode")
        #expect(parse(reply(mode: 5, originate: t1, receive: t2, transmit: t2)) == nil, "broadcast mode")
        #expect(parse(reply(version: 2, originate: t1, receive: t2, transmit: t2)) == nil)
        #expect(parse(reply(version: 5, originate: t1, receive: t2, transmit: t2)) == nil)
        #expect(parse(reply(stratum: 0, originate: t1, receive: t2, transmit: t2)) == nil, "kiss-o'-death")
        #expect(parse(reply(stratum: 16, originate: t1, receive: t2, transmit: t2)) == nil, "unsynchronised")
        #expect(parse(reply(stratum: 1, originate: t1, receive: t2, transmit: t2)) != nil)
        #expect(parse(reply(stratum: 15, originate: t1, receive: t2, transmit: t2)) != nil)
        #expect(parse(reply(leap: 3, originate: t1, receive: t2, transmit: t2)) == nil, "alarm")
        #expect(parse(reply(leap: 1, originate: t1, receive: t2, transmit: t2)) != nil, "leap second pending")
        #expect(parse(reply(originate: t1 + 0.01, receive: t2, transmit: t2)) == nil, "not our request")
        var zeroTransmit = reply(originate: t1, receive: t2, transmit: t2)
        for i in 40..<48 { zeroTransmit[i] = 0 }
        #expect(parse(zeroTransmit) == nil)
        var zeroReceive = reply(originate: t1, receive: t2, transmit: t2)
        for i in 32..<40 { zeroReceive[i] = 0 }
        #expect(parse(zeroReceive) == nil)
        #expect(parse(Array(reply(originate: t1, receive: t2, transmit: t2)[0..<47])) == nil, "short")
        #expect(ClockCheck.parseOffset(response: reply(originate: t1, receive: t2, transmit: t2), t1: t1, t4: .nan) == nil)
    }

    /// Timestamps round-trip, across the 2036 era boundary (RFC 4330 section 3).
    @Test func timestampsRoundTripAcrossEras() throws {
        for t in [1_800_000_000.5, 2_085_978_495.75, 2_085_978_496.25, 2_200_000_000.125, 0.5] {
            var p = [UInt8](repeating: 0, count: 48)
            ClockCheck.putTimestamp(t, into: &p, at: 40)
            let back = try #require(ClockCheck.timestamp(p, at: 40))
            #expect(abs(back - t) < 1e-6, "\(t) → \(back)")
        }
        // 2039 has the seconds field's top bit clear (era 1).
        var p = [UInt8](repeating: 0, count: 48)
        ClockCheck.putTimestamp(2_200_000_000, into: &p, at: 40)
        #expect(p[40] & 0x80 == 0)
        let request = ClockCheck.request(t1: 1_800_000_000.5)
        #expect(request.count == 48 && request[0] == 0x23)
        #expect(abs((transmitTime(request) ?? 0) - 1_800_000_000.5) < 1e-6)
    }

    /// The real query path against a local responder whose clock is 5 s ahead of ours.
    @Test func queryAgainstLocalResponder() async throws {
        let server = try #require(Responder { request, t2 in
            guard let t1 = transmitTime(request) else { return nil }
            return reply(originate: t1, receive: t2 + 5, transmit: Date().timeIntervalSince1970 + 5)
        })
        defer { server.stop() }
        let offset = try #require(await ClockCheck.offsetSeconds(server: "127.0.0.1", port: server.port, timeout: 2))
        #expect(abs(offset - 5) < 0.05, "offset \(offset)")
        #expect(server.requests.load(ordering: .relaxed) == 1)
    }

    /// No reply, or only invalid replies: nil once the timeout has passed, not much later. Times the
    /// blocking query itself: the async wrapper's utility queue can start late on a loaded machine (a
    /// full parallel test run), which says nothing about the timeout (`queryAgainstLocalResponder`
    /// covers the wrapper).
    @Test func queryTimesOut() throws {
        let silent = try #require(Responder { _, _ in nil })
        defer { silent.stop() }
        var start = Date()
        #expect(ClockCheck.query(server: "127.0.0.1", port: silent.port, timeout: 0.3) == nil)
        var elapsed = Date().timeIntervalSince(start)
        #expect(elapsed >= 0.25 && elapsed < 1.5, "elapsed \(elapsed)")
        #expect(silent.requests.load(ordering: .relaxed) == 1)

        let wrong = try #require(Responder { request, t2 in
            guard let t1 = transmitTime(request) else { return nil }
            return reply(mode: 3, originate: t1, receive: t2, transmit: t2)
        })
        defer { wrong.stop() }
        start = Date()
        #expect(ClockCheck.query(server: "127.0.0.1", port: wrong.port, timeout: 0.3) == nil)
        elapsed = Date().timeIntervalSince(start)
        #expect(elapsed >= 0.25 && elapsed < 1.5, "elapsed \(elapsed)")
        #expect(wrong.requests.load(ordering: .relaxed) == 1)
    }

    /// A non-positive or non-finite timeout gives nil at once (no name resolution is attempted, so
    /// this needs no network).
    @Test func invalidTimeoutGivesNil() async {
        #expect(await ClockCheck.offsetSeconds(server: "127.0.0.1", port: "123", timeout: 0) == nil)
        #expect(await ClockCheck.offsetSeconds(server: "127.0.0.1", port: "123", timeout: .nan) == nil)
    }
}
