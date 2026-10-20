import Synchronization

/// Lock-free single-producer / single-consumer ring buffer.
/// Exactly one thread may write and exactly one thread may read at a time.
public final class SPSCRing<Element: BitwiseCopyable>: @unchecked Sendable {
    public let capacity: Int
    private let mask: Int
    private let storage: UnsafeMutablePointer<Element>
    private let writeIndex = Atomic<Int>(0)
    private let readIndex = Atomic<Int>(0)

    /// `capacity` is rounded up to a power of two.
    public init(capacity: Int, fill: Element) {
        var c = 1
        while c < capacity { c <<= 1 }
        self.capacity = c
        mask = c - 1
        storage = .allocate(capacity: c)
        storage.initialize(repeating: fill, count: c)
    }

    deinit { storage.deallocate() }

    public var availableToRead: Int {
        writeIndex.load(ordering: .acquiring) - readIndex.load(ordering: .acquiring)
    }

    public var availableToWrite: Int { capacity - availableToRead }

    /// Producer side. Writes as many elements as fit and returns the count written.
    @discardableResult
    public func write(_ src: UnsafeBufferPointer<Element>) -> Int {
        let w = writeIndex.load(ordering: .relaxed)
        let r = readIndex.load(ordering: .acquiring)
        let n = min(src.count, capacity - (w - r))
        guard n > 0, let base = src.baseAddress else { return 0 }
        let start = w & mask
        let first = min(n, capacity - start)
        (storage + start).update(from: base, count: first)
        if n > first { storage.update(from: base + first, count: n - first) }
        writeIndex.store(w + n, ordering: .releasing)
        return n
    }

    /// Consumer side. Reads up to `dst.count` elements and returns the count read.
    @discardableResult
    public func read(into dst: UnsafeMutableBufferPointer<Element>) -> Int {
        let r = readIndex.load(ordering: .relaxed)
        let w = writeIndex.load(ordering: .acquiring)
        let n = min(dst.count, w - r)
        guard n > 0, let base = dst.baseAddress else { return 0 }
        let start = r & mask
        let first = min(n, capacity - start)
        base.update(from: storage + start, count: first)
        if n > first { (base + first).update(from: storage, count: n - first) }
        readIndex.store(r + n, ordering: .releasing)
        return n
    }

    /// Consumer side: discards everything currently buffered.
    public func drain() {
        readIndex.store(writeIndex.load(ordering: .acquiring), ordering: .releasing)
    }
}
