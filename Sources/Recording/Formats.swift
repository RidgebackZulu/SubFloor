import Accelerate
import Foundation

/// How each sample is stored, in the file and in the pre-roll ring. Little-endian.
public enum SampleFormat: String, Codable, CaseIterable, Sendable, Identifiable {
    case int16, int24, float32

    public var id: String { rawValue }
    public var bytesPerSample: Int {
        switch self {
        case .int16: 2
        case .int24: 3
        case .float32: 4
        }
    }
    public var bitsPerSample: Int { bytesPerSample * 8 }
    public var isFloat: Bool { self == .float32 }
    public var label: String {
        switch self {
        case .int16: "16-bit"
        case .int24: "24-bit"
        case .float32: "32-bit float"
        }
    }
}

/// The container a recording is written to. Every one is lossless.
public enum FileFormat: String, Codable, CaseIterable, Sendable, Identifiable {
    case wav, flac, alac, sigmf

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .wav: "WAV"
        case .flac: "FLAC"
        case .alac: "Apple Lossless"
        case .sigmf: "SigMF"
        }
    }
    public var fileExtension: String {
        switch self {
        case .wav: "wav"
        case .flac: "flac"
        case .alac: "m4a"
        case .sigmf: "sigmf-data"
        }
    }
    /// The sample formats the container can hold (FLAC and ALAC are integer-only).
    public var sampleFormats: [SampleFormat] {
        switch self {
        case .wav: [.int16, .int24, .float32]
        case .flac, .alac: [.int16, .int24]
        case .sigmf: [.int16, .float32]
        }
    }
    /// Sample bytes per file before the recorder rolls to a new one. RIFF sizes are 32-bit.
    public var dataLimit: Int? {
        switch self {
        case .wav: 4_000_000_000
        case .flac, .alac, .sigmf: nil
        }
    }
}

/// The two things that can be recorded.
public enum StreamKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case audio, iq

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .audio: "Audio"
        case .iq: "IQ"
        }
    }
    public var channels: Int {
        switch self {
        case .audio: 1
        case .iq: 2
        }
    }
    public var fileFormats: [FileFormat] {
        switch self {
        case .audio: [.wav, .flac, .alac]
        case .iq: [.wav, .sigmf]
        }
    }
    /// IQ is 16-bit (the RSP1B's ADC is 14-bit, so this is lossless) or float; 24-bit IQ WAVs are
    /// read by almost no SDR software.
    public func sampleFormats(for format: FileFormat) -> [SampleFormat] {
        switch self {
        case .audio: format.sampleFormats
        case .iq: format.sampleFormats.filter { $0 != .int24 }
        }
    }
}

/// The user's recording preferences. `normalized()` keeps every combination valid.
public struct RecordingSettings: Codable, Equatable, Sendable {
    public static let preRollRange = 5.0...120.0
    public static let memoryLimits = [1 << 30, 2 << 30, 4 << 30, 8 << 30]

    public var preRollSeconds = 30.0
    public var audioFormat: FileFormat = .flac
    public var audioSampleFormat: SampleFormat = .int24
    public var iqFormat: FileFormat = .wav
    public var iqSampleFormat: SampleFormat = .int16
    /// Cap on the IQ pre-roll ring (the audio ring is always small).
    public var iqMemoryLimitBytes = 2 << 30
    /// nil: `defaultFolder`.
    public var folderPath: String?

    public init() {}

    public static var defaultFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music/SubFloor", isDirectory: true)
    }
    public var folder: URL { folderPath.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? Self.defaultFolder }

    public func fileFormat(for kind: StreamKind) -> FileFormat { kind == .audio ? audioFormat : iqFormat }
    public func sampleFormat(for kind: StreamKind) -> SampleFormat { kind == .audio ? audioSampleFormat : iqSampleFormat }

    /// Pre-roll inside its range; sample formats the chosen containers can hold (the nearest allowed
    /// one is picked: 24-bit under SigMF becomes 16-bit, float under FLAC becomes 24-bit).
    public func normalized() -> RecordingSettings {
        var s = self
        s.preRollSeconds = min(max(s.preRollSeconds.isFinite ? s.preRollSeconds : 30, Self.preRollRange.lowerBound), Self.preRollRange.upperBound).rounded()
        if !StreamKind.audio.fileFormats.contains(s.audioFormat) { s.audioFormat = .flac }
        if !StreamKind.iq.fileFormats.contains(s.iqFormat) { s.iqFormat = .wav }
        s.audioSampleFormat = Self.nearest(s.audioSampleFormat, in: StreamKind.audio.sampleFormats(for: s.audioFormat))
        s.iqSampleFormat = Self.nearest(s.iqSampleFormat, in: StreamKind.iq.sampleFormats(for: s.iqFormat))
        if !Self.memoryLimits.contains(s.iqMemoryLimitBytes) { s.iqMemoryLimitBytes = 2 << 30 }
        return s
    }

    private static func nearest(_ f: SampleFormat, in allowed: [SampleFormat]) -> SampleFormat {
        if allowed.contains(f) { return f }
        let order = SampleFormat.allCases
        let i = order.firstIndex(of: f)!
        return allowed.min { abs(order.firstIndex(of: $0)! - i) < abs(order.firstIndex(of: $1)! - i) } ?? allowed[0]
    }
}

/// Converts interleaved floats in [-1, 1] to a `SampleFormat`, little-endian. Integers round to
/// nearest and clip; no dither (the receiver's noise floor is far above an LSB).
public final class SampleConverter {
    public let format: SampleFormat
    private var floats: [Float] = []
    private var ints: [Int32] = []

    public init(format: SampleFormat) { self.format = format }

    /// `out` must hold `input.count * format.bytesPerSample` bytes and be 4-byte aligned.
    public func convert(_ input: UnsafeBufferPointer<Float>, into out: UnsafeMutableRawBufferPointer) {
        let n = input.count
        guard n > 0, let src = input.baseAddress, let dst = out.baseAddress else { return }
        precondition(out.count >= n * format.bytesPerSample)
        switch format {
        case .float32:
            dst.copyMemory(from: UnsafeRawPointer(src), byteCount: n * 4)
        case .int16:
            scaled(src, count: n, fullScale: 32_767)
            floats.withUnsafeBufferPointer { f in
                vDSP_vfixr16(f.baseAddress!, 1, dst.assumingMemoryBound(to: Int16.self), 1, vDSP_Length(n))
            }
        case .int24:
            scaled(src, count: n, fullScale: 8_388_607)
            if ints.count < n { ints = .init(repeating: 0, count: n) }
            floats.withUnsafeBufferPointer { f in
                ints.withUnsafeMutableBufferPointer { i in vDSP_vfixr32(f.baseAddress!, 1, i.baseAddress!, 1, vDSP_Length(n)) }
            }
            let bytes = dst.assumingMemoryBound(to: UInt8.self)
            ints.withUnsafeBufferPointer { i in
                for k in 0..<n {
                    let v = UInt32(bitPattern: i[k])
                    bytes[3 * k] = UInt8(truncatingIfNeeded: v)
                    bytes[3 * k + 1] = UInt8(truncatingIfNeeded: v >> 8)
                    bytes[3 * k + 2] = UInt8(truncatingIfNeeded: v >> 16)
                }
            }
        }
    }

    /// `floats[0..<count]` = clip(src, ±1) × fullScale.
    private func scaled(_ src: UnsafePointer<Float>, count n: Int, fullScale: Float) {
        if floats.count < n { floats = .init(repeating: 0, count: n) }
        floats.withUnsafeMutableBufferPointer { f in
            var lo: Float = -1, hi: Float = 1, scale = fullScale
            vDSP_vclip(src, 1, &lo, &hi, f.baseAddress!, 1, vDSP_Length(n))
            vDSP_vsmul(f.baseAddress!, 1, &scale, f.baseAddress!, 1, vDSP_Length(n))
        }
    }
}

/// Text for the recording controls.
public enum RecordingFormat {
    /// `0:07`, `12:34`, `1:02:03`.
    public static func elapsed(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    /// `12 MB`, `1.9 GB` (decimal units, as the Finder shows file sizes).
    public static func bytes(_ n: Int) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useKB, .useMB, .useGB]
        return f.string(fromByteCount: Int64(n))
    }
}
