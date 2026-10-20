import Testing
@testable import DSPCore

@Test func ringRoundTripsAcrossWrap() {
    let ring = SPSCRing<Float>(capacity: 8, fill: 0)
    var out = [Float](repeating: 0, count: 5)
    for round in 0..<5 {
        let input = (0..<5).map { Float(round * 10 + $0) }
        #expect(input.withUnsafeBufferPointer { ring.write($0) } == 5)
        #expect(out.withUnsafeMutableBufferPointer { ring.read(into: $0) } == 5)
        #expect(out == input)
    }
}

@Test func ringRejectsOverflowAndRoundsCapacity() {
    let ring = SPSCRing<Float>(capacity: 3, fill: 0)
    #expect(ring.capacity == 4)
    let input: [Float] = [1, 2, 3, 4, 5, 6]
    #expect(input.withUnsafeBufferPointer { ring.write($0) } == 4)
    #expect(ring.availableToWrite == 0)
    ring.drain()
    #expect(ring.availableToRead == 0)
}

@Test func ringPreservesOrderUnderConcurrency() async {
    let ring = SPSCRing<Int32>(capacity: 1024, fill: 0)
    let total: Int32 = 200_000
    let producer = Task.detached {
        var next: Int32 = 0
        var chunk = [Int32](repeating: 0, count: 100)
        while next < total {
            for i in chunk.indices { chunk[i] = next + Int32(i) }
            var offset = 0
            while offset < chunk.count {
                offset += chunk.withUnsafeBufferPointer { ring.write(UnsafeBufferPointer(rebasing: $0[offset...])) }
            }
            next += Int32(chunk.count)
        }
    }
    var expected: Int32 = 0
    var ok = true
    var buf = [Int32](repeating: 0, count: 256)
    while expected < total {
        let n = buf.withUnsafeMutableBufferPointer { ring.read(into: $0) }
        for i in 0..<n where buf[i] != expected + Int32(i) { ok = false }
        expected += Int32(n)
        if n == 0 { await Task.yield() }
    }
    await producer.value
    #expect(ok)
}
