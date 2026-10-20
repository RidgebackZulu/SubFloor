import Accelerate
import Foundation

public enum IQFileError: Error, CustomStringConvertible {
    case notWAV
    case unsupported(String)
    public var description: String {
        switch self {
        case .notWAV: "Not a WAV file"
        case .unsupported(let why): "Unsupported WAV: \(why)"
        }
    }
}

/// Loops a stereo (I/Q) WAV recording in real time. 16-bit PCM and 32-bit float are supported.
public final class IQFileSource: IQSource, @unchecked Sendable {
    public struct WAVLayout: Equatable, Sendable {
        public var sampleRate: Double
        public var isFloat: Bool
        public var dataOffset: Int
        public var dataLength: Int
        public var bytesPerFrame: Int { isFloat ? 8 : 4 }
    }

    public let name: String
    public let sampleRate: Double
    public let centerFrequency: Double
    public var frameCount: Int { layout.dataLength / layout.bytesPerFrame }

    private let data: Data
    private let layout: WAVLayout
    private let queue = DispatchQueue(label: "subfloor.iqfile", qos: .userInteractive)
    private let lock = NSLock()   // guards `timer`; never held across queue.sync
    private var timer: DispatchSourceTimer?
    private var position = 0   // touched only on `queue`

    public init(url: URL, centerFrequency: Double) throws {
        data = try Data(contentsOf: url, options: .alwaysMapped)
        layout = try Self.parseWAVHeader(data)
        // An empty data chunk would make frameCount 0 and trap on `position % frameCount` in start().
        guard layout.dataLength >= layout.bytesPerFrame else { throw IQFileError.unsupported("no samples") }
        sampleRate = layout.sampleRate
        self.centerFrequency = centerFrequency
        name = url.lastPathComponent
    }

    public static func parseWAVHeader(_ data: Data) throws -> WAVLayout {
        func u32(_ o: Int) -> UInt32 { data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt32.self) }.littleEndian }
        func u16(_ o: Int) -> UInt16 { data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt16.self) }.littleEndian }
        func tag(_ o: Int) -> String { String(decoding: data[data.startIndex + o ..< data.startIndex + o + 4], as: UTF8.self) }
        guard data.count >= 12, tag(0) == "RIFF", tag(8) == "WAVE" else { throw IQFileError.notWAV }
        var offset = 12
        var format: (rate: Double, isFloat: Bool)?
        while offset + 8 <= data.count {
            let id = tag(offset)
            let size = Int(u32(offset + 4))
            let body = offset + 8
            if id == "fmt " {
                // Bounds-check before reading any field: 16 bytes minimum, 26 for WAVE_FORMAT_EXTENSIBLE.
                guard size >= 16, body + size <= data.count else { throw IQFileError.unsupported("truncated fmt chunk") }
                var audioFormat = u16(body)
                if audioFormat == 0xFFFE {
                    guard size >= 26 else { throw IQFileError.unsupported("truncated fmt chunk") }
                    audioFormat = u16(body + 24)
                }
                let channels = u16(body + 2)
                let bits = u16(body + 14)
                guard channels == 2 else { throw IQFileError.unsupported("\(channels) channels (need 2: I and Q)") }
                switch (audioFormat, bits) {
                case (1, 16): format = (Double(u32(body + 4)), false)
                case (3, 32): format = (Double(u32(body + 4)), true)
                default: throw IQFileError.unsupported("format \(audioFormat), \(bits)-bit")
                }
            } else if id == "data" {
                guard let format else { throw IQFileError.unsupported("data before fmt chunk") }
                return WAVLayout(sampleRate: format.rate, isFloat: format.isFloat,
                                 dataOffset: body, dataLength: min(size, data.count - body))
            }
            offset = body + size + (size & 1)
        }
        throw IQFileError.notWAV
    }

    func readFrames(at frame: Int, count: Int) -> [DSPComplex] {
        var out = [DSPComplex](repeating: DSPComplex(real: 0, imag: 0), count: count)
        data.withUnsafeBytes { raw in
            let base = raw.baseAddress! + layout.dataOffset + frame * layout.bytesPerFrame
            out.withUnsafeMutableBufferPointer { o in
                o.withMemoryRebound(to: Float.self) { floats in
                    if layout.isFloat {
                        floats.baseAddress!.update(from: base.assumingMemoryBound(to: Float.self), count: count * 2)
                        // Float WAVs may contain NaN/Inf; those would poison the filters and AGC.
                        for k in 0..<(count * 2) where !floats[k].isFinite { floats[k] = 0 }
                    } else {
                        vDSP_vflt16(base.assumingMemoryBound(to: Int16.self), 1, floats.baseAddress!, 1, vDSP_Length(count * 2))
                        var scale: Float = 1 / 32_768
                        vDSP_vsmul(floats.baseAddress!, 1, &scale, floats.baseAddress!, 1, vDSP_Length(count * 2))
                    }
                }
            }
        }
        return out
    }

    public func start(_ handler: @escaping @Sendable (UnsafeBufferPointer<DSPComplex>) -> Void) throws {
        stop()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            var remaining = Int(self.sampleRate / 100)
            while remaining > 0 {
                let n = min(remaining, self.frameCount - self.position)
                let block = self.readFrames(at: self.position, count: n)
                block.withUnsafeBufferPointer { handler($0) }
                self.position = (self.position + n) % self.frameCount
                remaining -= n
            }
        }
        lock.withLock { timer = t }
        t.resume()
    }

    /// Hard barrier: when this returns, no handler is running or will run again.
    /// Must not be called from the source's own queue (the `queue.sync` below would deadlock).
    public func stop() {
        let old = lock.withLock { () -> DispatchSourceTimer? in
            let t = timer
            timer = nil
            return t
        }
        old?.cancel()
        queue.sync {}   // lock is not held here
    }

    deinit { timer?.cancel() }

    /// Recordings have a fixed centre; retuning is a no-op.
    public func setCenterFrequency(_ hz: Double) throws {}
}
