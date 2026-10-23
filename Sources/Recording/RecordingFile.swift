import AudioToolbox
import Foundation

public enum RecordingError: Error, CustomStringConvertible {
    case io(String)
    case coreAudio(OSStatus, String)
    case unsupported(String)

    public var description: String {
        switch self {
        case .io(let why): why
        case .coreAudio(let code, let what): "\(what) failed (\(code))"
        case .unsupported(let why): why
        }
    }
}

/// The stream a file holds.
public struct StreamLayout: Equatable, Sendable {
    public var sampleRate: Double
    public var channels: Int
    public var sampleFormat: SampleFormat

    public init(sampleRate: Double, channels: Int, sampleFormat: SampleFormat) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.sampleFormat = sampleFormat
    }

    public var bytesPerFrame: Int { channels * sampleFormat.bytesPerSample }
}

/// What a SigMF (or any) recording says about itself.
public struct RecordingMetadata: Equatable, Sendable {
    public var frequencyHz: Double
    public var firstSample: Date
    public var hardware: String
    public var description: String

    public init(frequencyHz: Double, firstSample: Date, hardware: String, description: String = "SubFloor") {
        self.frequencyHz = frequencyHz
        self.firstSample = firstSample
        self.hardware = hardware
        self.description = description
    }
}

/// A file being recorded: fed raw interleaved little-endian bytes in the layout's sample format.
public protocol RecordingFile: AnyObject {
    var url: URL { get }
    /// Sample bytes written so far.
    var bytesWritten: Int { get }
    func write(_ bytes: UnsafeRawBufferPointer) throws
    /// Every few seconds: leaves the file readable so far, where the format allows.
    func checkpoint() throws
    func finalize() throws
}

public enum RecordingFiles {
    /// `base` without extension; the format adds its own.
    public static func open(_ format: FileFormat, base: URL, layout: StreamLayout, metadata: RecordingMetadata) throws -> any RecordingFile {
        guard format.sampleFormats.contains(layout.sampleFormat) else {
            throw RecordingError.unsupported("\(format.label) cannot hold \(layout.sampleFormat.label) samples")
        }
        let url = base.appendingPathExtension(format.fileExtension)
        switch format {
        case .wav: return try WAVFile(url: url, layout: layout)
        case .sigmf: return try SigMFFile(url: url, layout: layout, metadata: metadata)
        case .flac, .alac: return try CoreAudioFile(url: url, layout: layout, format: format)
        }
    }
}

/// POSIX file: appends with write(2), patches with pwrite(2).
final class RawFile {
    let url: URL
    private var fd: Int32
    private(set) var bytesWritten = 0

    init(url: URL) throws {
        self.url = url
        fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw RecordingError.io("Could not create \(url.lastPathComponent): \(String(cString: strerror(errno)))") }
    }

    deinit { if fd >= 0 { Darwin.close(fd) } }

    func append(_ bytes: UnsafeRawBufferPointer) throws {
        guard var p = bytes.baseAddress else { return }
        var left = bytes.count
        while left > 0 {
            let n = Darwin.write(fd, p, left)
            if n < 0 {
                if errno == EINTR { continue }
                throw RecordingError.io("Writing \(url.lastPathComponent) failed: \(String(cString: strerror(errno)))")
            }
            p += n
            left -= n
            bytesWritten += n
        }
    }

    func patch(_ bytes: [UInt8], at offset: Int) throws {
        let n = bytes.withUnsafeBytes { Darwin.pwrite(fd, $0.baseAddress, $0.count, off_t(offset)) }
        guard n == bytes.count else { throw RecordingError.io("Updating \(url.lastPathComponent) failed: \(String(cString: strerror(errno)))") }
    }

    func close() throws {
        guard fd >= 0 else { return }
        let r = Darwin.close(fd)
        fd = -1
        guard r == 0 else { throw RecordingError.io("Closing \(url.lastPathComponent) failed: \(String(cString: strerror(errno)))") }
    }
}

/// RIFF WAVE, 44-byte header: PCM (format 1) for integers, IEEE float (format 3). Sizes are patched
/// at every checkpoint and at the end.
public final class WAVFile: RecordingFile {
    public static let headerSize = 44
    private let file: RawFile
    public let layout: StreamLayout

    public var url: URL { file.url }
    public var bytesWritten: Int { file.bytesWritten - Self.headerSize }

    public init(url: URL, layout: StreamLayout) throws {
        self.layout = layout
        file = try RawFile(url: url)
        let header = Self.header(layout: layout, dataBytes: 0)
        try header.withUnsafeBytes { try file.append($0) }
    }

    public static func header(layout: StreamLayout, dataBytes: Int) -> [UInt8] {
        var h: [UInt8] = []
        func u32(_ v: UInt32) { h += withUnsafeBytes(of: v.littleEndian) { Array($0) } }
        func u16(_ v: UInt16) { h += withUnsafeBytes(of: v.littleEndian) { Array($0) } }
        let data = UInt32(clamping: dataBytes)
        h += Array("RIFF".utf8); u32(36 + data); h += Array("WAVE".utf8)
        h += Array("fmt ".utf8); u32(16)
        u16(layout.sampleFormat.isFloat ? 3 : 1)
        u16(UInt16(layout.channels))
        u32(UInt32(layout.sampleRate.rounded()))
        u32(UInt32(layout.sampleRate.rounded()) * UInt32(layout.bytesPerFrame))
        u16(UInt16(layout.bytesPerFrame))
        u16(UInt16(layout.sampleFormat.bitsPerSample))
        h += Array("data".utf8); u32(data)
        return h
    }

    public func write(_ bytes: UnsafeRawBufferPointer) throws { try file.append(bytes) }

    public func checkpoint() throws {
        let data = UInt32(clamping: bytesWritten)
        try file.patch(withUnsafeBytes(of: (36 + data).littleEndian) { Array($0) }, at: 4)
        try file.patch(withUnsafeBytes(of: data.littleEndian) { Array($0) }, at: 40)
    }

    public func finalize() throws {
        try checkpoint()
        try file.close()
    }
}

/// SigMF: raw samples in `.sigmf-data`, a JSON description beside it in `.sigmf-meta`, written when
/// the file opens (so a crash still leaves a complete pair) and again at the end.
public final class SigMFFile: RecordingFile {
    private let file: RawFile
    public let layout: StreamLayout
    public let metadata: RecordingMetadata
    public let metaURL: URL

    public var url: URL { file.url }
    public var bytesWritten: Int { file.bytesWritten }

    public init(url: URL, layout: StreamLayout, metadata: RecordingMetadata) throws {
        self.layout = layout
        self.metadata = metadata
        metaURL = url.deletingPathExtension().appendingPathExtension("sigmf-meta")
        file = try RawFile(url: url)
        try writeMeta()
    }

    /// `ci16_le`, `cf32_le`, `ri16_le`, … per the SigMF core specification.
    public static func datatype(_ layout: StreamLayout) -> String {
        let kind = layout.channels == 2 ? "c" : "r"
        let type = layout.sampleFormat.isFloat ? "f" : "i"
        return "\(kind)\(type)\(layout.sampleFormat.bitsPerSample)_le"
    }

    public static func meta(layout: StreamLayout, metadata: RecordingMetadata) -> [String: Any] {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        iso.timeZone = TimeZone(identifier: "UTC")
        return [
            "global": [
                "core:datatype": datatype(layout),
                "core:sample_rate": layout.sampleRate,
                "core:version": "1.2.0",
                "core:num_channels": layout.channels == 2 ? 1 : layout.channels,
                "core:description": metadata.description,
                "core:recorder": "SubFloor",
                "core:hw": metadata.hardware,
            ] as [String: Any],
            "captures": [[
                "core:sample_start": 0,
                "core:frequency": metadata.frequencyHz,
                "core:datetime": iso.string(from: metadata.firstSample),
            ] as [String: Any]],
            "annotations": [] as [Any],
        ]
    }

    private func writeMeta() throws {
        let data = try JSONSerialization.data(withJSONObject: Self.meta(layout: layout, metadata: metadata), options: [.prettyPrinted, .sortedKeys])
        try data.write(to: metaURL, options: .atomic)
    }

    public func write(_ bytes: UnsafeRawBufferPointer) throws { try file.append(bytes) }
    public func checkpoint() throws {}
    public func finalize() throws {
        try file.close()
        try writeMeta()
    }
}

/// FLAC or Apple Lossless through `ExtAudioFile`: the client format is the layout's integer LPCM, so
/// the encoder sees exactly the samples the recorder produced.
public final class CoreAudioFile: RecordingFile {
    public let url: URL
    public let layout: StreamLayout
    private var ref: ExtAudioFileRef?
    public private(set) var bytesWritten = 0

    public init(url: URL, layout: StreamLayout, format: FileFormat) throws {
        self.url = url
        self.layout = layout
        guard !layout.sampleFormat.isFloat else { throw RecordingError.unsupported("\(format.label) holds integer samples only") }
        var fileFormat = AudioStreamBasicDescription()
        fileFormat.mSampleRate = layout.sampleRate
        fileFormat.mChannelsPerFrame = UInt32(layout.channels)
        fileFormat.mFormatID = format == .flac ? kAudioFormatFLAC : kAudioFormatAppleLossless
        fileFormat.mFormatFlags = layout.sampleFormat == .int16 ? kAppleLosslessFormatFlag_16BitSourceData : kAppleLosslessFormatFlag_24BitSourceData
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let info = AudioFormatGetProperty(kAudioFormatProperty_FormatInfo, 0, nil, &size, &fileFormat)
        guard info == noErr else { throw RecordingError.coreAudio(info, "\(format.label) format lookup") }

        var client = Self.clientFormat(layout)
        var created: ExtAudioFileRef?
        let fileType: AudioFileTypeID = format == .flac ? kAudioFileFLACType : kAudioFileM4AType
        let status = ExtAudioFileCreateWithURL(url as CFURL, fileType, &fileFormat, nil, AudioFileFlags.eraseFile.rawValue, &created)
        guard status == noErr, let created else { throw RecordingError.coreAudio(status, "Creating \(url.lastPathComponent)") }
        ref = created
        let set = ExtAudioFileSetProperty(created, kExtAudioFileProperty_ClientDataFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &client)
        guard set == noErr else {
            ExtAudioFileDispose(created)
            ref = nil
            throw RecordingError.coreAudio(set, "Setting the \(format.label) client format")
        }
    }

    deinit { if let ref { ExtAudioFileDispose(ref) } }

    static func clientFormat(_ layout: StreamLayout) -> AudioStreamBasicDescription {
        var f = AudioStreamBasicDescription()
        f.mSampleRate = layout.sampleRate
        f.mFormatID = kAudioFormatLinearPCM
        f.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked
        f.mChannelsPerFrame = UInt32(layout.channels)
        f.mBitsPerChannel = UInt32(layout.sampleFormat.bitsPerSample)
        f.mBytesPerFrame = UInt32(layout.bytesPerFrame)
        f.mFramesPerPacket = 1
        f.mBytesPerPacket = f.mBytesPerFrame
        return f
    }

    public func write(_ bytes: UnsafeRawBufferPointer) throws {
        guard let ref, let base = bytes.baseAddress else { return }
        let frames = bytes.count / layout.bytesPerFrame
        guard frames > 0 else { return }
        var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
            mNumberChannels: UInt32(layout.channels), mDataByteSize: UInt32(frames * layout.bytesPerFrame),
            mData: UnsafeMutableRawPointer(mutating: base)))
        let status = ExtAudioFileWrite(ref, UInt32(frames), &list)
        guard status == noErr else { throw RecordingError.coreAudio(status, "Writing \(url.lastPathComponent)") }
        bytesWritten += frames * layout.bytesPerFrame
    }

    public func checkpoint() throws {}

    public func finalize() throws {
        guard let ref else { return }
        self.ref = nil
        let status = ExtAudioFileDispose(ref)
        guard status == noErr else { throw RecordingError.coreAudio(status, "Closing \(url.lastPathComponent)") }
    }
}
