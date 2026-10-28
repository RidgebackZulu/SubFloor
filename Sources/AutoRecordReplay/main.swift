// AutoRecordReplay: replays an IQ capture through the receiver and the auto-record trigger, faster
// than real time, and prints what auto-record would have done. Nothing is written to disk.
//
//   AutoRecordReplay <iq.wav> --vfo <Hz> --mode usb|lsb|am --bw <Hz>
//                    (--squelch <dBFS> | --above-floor <dB>)
//                    [--start <s>] [--stop <s>] [--start-after <s>] [--stop-after <s>]
//
// The file must be named like a SubFloor IQ recording (SubFloor_20261022_143000Z_14100000Hz_IQ.wav):
// the name gives the time of the first sample and the capture's centre frequency.

import Accelerate
import DSPCore
import Foundation
import Recording

struct UsageError: Error { let message: String }

let usage = "usage: AutoRecordReplay <iq.wav> --vfo <Hz> --mode usb|lsb|am --bw <Hz> (--squelch <dBFS> | --above-floor <dB>) [--start <s>] [--stop <s>] [--start-after <s>] [--stop-after <s>]"

struct Options {
    var path = ""
    var vfoHz = 0.0
    var mode = DemodMode.usb
    var bandwidthHz = 0.0
    var squelchDb: Float?
    var aboveFloorDb: Float?
    var startSeconds = 0.0
    var stopSeconds: Double?
    var timing = AutoRecordTiming()
}

func parseArguments(_ args: [String]) throws -> Options {
    var o = Options()
    var havePath = false, haveVFO = false, haveMode = false, haveBW = false
    var i = 0
    func value(_ flag: String) throws -> String {
        i += 1
        guard i < args.count else { throw UsageError(message: "\(flag) needs a value") }
        return args[i]
    }
    func number(_ flag: String) throws -> Double {
        let text = try value(flag)
        guard let v = Double(text), v.isFinite else { throw UsageError(message: "\(flag): '\(text)' is not a number") }
        return v
    }
    while i < args.count {
        let a = args[i]
        switch a {
        case "--vfo": o.vfoHz = try number(a); haveVFO = true
        case "--bw":
            o.bandwidthHz = try number(a); haveBW = true
            guard o.bandwidthHz > 0 else { throw UsageError(message: "--bw must be positive") }
        case "--mode":
            let text = try value(a).lowercased()
            guard let m = DemodMode(rawValue: text) else { throw UsageError(message: "--mode: unknown mode '\(text)' (usb, lsb or am)") }
            o.mode = m; haveMode = true
        case "--squelch": o.squelchDb = Float(try number(a))
        case "--above-floor": o.aboveFloorDb = Float(try number(a))
        case "--start":
            o.startSeconds = try number(a)
            guard o.startSeconds >= 0 else { throw UsageError(message: "--start must not be negative") }
        case "--stop": o.stopSeconds = try number(a)
        case "--start-after": o.timing.startAfter = try number(a)
        case "--stop-after": o.timing.stopAfter = try number(a)
        default:
            if a.hasPrefix("--") { throw UsageError(message: "unknown option \(a)") }
            guard !havePath else { throw UsageError(message: "more than one input file: \(a)") }
            o.path = a; havePath = true
        }
        i += 1
    }
    guard havePath else { throw UsageError(message: args.isEmpty ? usage : "no input file (\(usage))") }
    guard haveVFO else { throw UsageError(message: "--vfo is required (\(usage))") }
    guard haveMode else { throw UsageError(message: "--mode is required") }
    guard haveBW else { throw UsageError(message: "--bw is required") }
    guard (o.squelchDb == nil) != (o.aboveFloorDb == nil) else {
        throw UsageError(message: "give exactly one of --squelch and --above-floor")
    }
    if let stop = o.stopSeconds, stop <= o.startSeconds { throw UsageError(message: "--stop must be after --start") }
    return o
}

/// `SubFloor_20261022_143000Z_14100000Hz_IQ[_2].wav` gives the time of the first sample and the centre.
func parseFileName(_ name: String) throws -> (start: Date, centerHz: Double) {
    let pattern = #"^SubFloor_(\d{8})_(\d{6})Z_(\d+)Hz_IQ(?:_\d+)?\.wav$"#
    guard let match = name.wholeMatch(of: try Regex(pattern)),
          let date = match.output[1].substring, let time = match.output[2].substring,
          let hz = match.output[3].substring.flatMap({ Double($0) })
    else {
        throw UsageError(message: "file name '\(name)' is not like SubFloor_20261022_143000Z_14100000Hz_IQ.wav (time and centre are read from it)")
    }
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "UTC")
    f.dateFormat = "yyyyMMdd_HHmmss"
    guard let start = f.date(from: "\(date)_\(time)") else {
        throw UsageError(message: "file name '\(name)' has an invalid date or time")
    }
    return (start, hz)
}

func clock(_ date: Date) -> String {
    let utc = TimeZone(identifier: "UTC")!
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = utc
    let c = cal.dateComponents([.hour, .minute, .second, .nanosecond], from: date)
    let floorTenths = min(9, (c.nanosecond ?? 0) / 100_000_000)   // floored, so the seconds never carry
    return String(format: "%02d:%02d:%02d.%dZ", c.hour ?? 0, c.minute ?? 0, c.second ?? 0, floorTenths)
}

func span(_ seconds: Double) -> String {
    let tenths = Int((seconds * 10).rounded())
    let s = Double(tenths) / 10
    if s >= 3600 {
        let h = Int(s / 3600), m = Int((s - Double(h) * 3600) / 60)
        return String(format: "%dh%02dm%04.1fs", h, m, s - Double(h) * 3600 - Double(m) * 60)
    }
    if s >= 60 {
        let m = Int(s / 60)
        return String(format: "%dm%04.1fs", m, s - Double(m) * 60)
    }
    return String(format: "%.1fs", s)
}

/// Streams a stereo I/Q WAV in blocks without holding the file in memory.
struct IQReader {
    static let blockFrames = 1_008
    static let blocksPerRead = 256

    let handle: FileHandle
    let layout: IQFileSource.WAVLayout
    let frameCount: Int
    private(set) var position = 0   // frames consumed

    init(path: String) throws {
        guard let h = FileHandle(forReadingAtPath: path) else { throw UsageError(message: "cannot open \(path)") }
        handle = h
        let fileSize = Int(try h.seekToEnd())
        try h.seek(toOffset: 0)
        guard let head = try h.read(upToCount: 1 << 16) else { throw UsageError(message: "\(path) is empty") }
        let parsed: IQFileSource.WAVLayout
        do { parsed = try IQFileSource.parseWAVHeader(head) } catch { throw UsageError(message: "\(path): \(error)") }
        layout = parsed
        // parseWAVHeader only saw the head of the file; take the data size from the file itself.
        // A recording still being written (size 0) or cut short (size beyond the file) runs to the end.
        let available = max(0, fileSize - parsed.dataOffset)
        let declared = Int(head.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: parsed.dataOffset - 4, as: UInt32.self) }.littleEndian)
        let dataBytes = (declared == 0 || declared > available) ? available : declared
        frameCount = dataBytes / parsed.bytesPerFrame
    }

    mutating func seek(toFrame frame: Int) throws {
        position = min(frame, frameCount)
        try handle.seek(toOffset: UInt64(layout.dataOffset + position * layout.bytesPerFrame))
    }

    /// Calls `body` with each block of up to 1,008 frames until `limit` frames have been read in all
    /// (counted from the start of the file) or the data ends.
    mutating func forEachBlock(upTo limit: Int, _ body: (UnsafeBufferPointer<DSPComplex>) -> Void) throws {
        let bpf = layout.bytesPerFrame
        var block = [DSPComplex](repeating: DSPComplex(real: 0, imag: 0), count: Self.blockFrames)
        while position < min(limit, frameCount) {
            let want = min(Self.blockFrames * Self.blocksPerRead, min(limit, frameCount) - position)
            guard let chunk = try handle.read(upToCount: want * bpf), chunk.count >= bpf else { break }
            let frames = chunk.count / bpf
            chunk.withUnsafeBytes { raw in
                var done = 0
                while done < frames {
                    let n = min(Self.blockFrames, frames - done)
                    block.withUnsafeMutableBufferPointer { out in
                        out.withMemoryRebound(to: Float.self) { floats in
                            let base = raw.baseAddress! + done * bpf
                            if layout.isFloat {
                                let src = base.bindMemory(to: Float.self, capacity: n * 2)
                                for k in 0..<(n * 2) {
                                    let v = Float(bitPattern: UInt32(littleEndian: src[k].bitPattern))
                                    floats[k] = v.isFinite ? v : 0
                                }
                            } else {
                                for k in 0..<(n * 2) {
                                    let v = Int16(littleEndian: base.loadUnaligned(fromByteOffset: k * 2, as: Int16.self))
                                    floats[k] = Float(v) / 32_768
                                }
                            }
                        }
                        body(UnsafeBufferPointer(rebasing: out[0..<n]))
                    }
                    done += n
                }
            }
            position += frames
        }
    }
}

func run() throws {
    let o = try parseArguments(Array(CommandLine.arguments.dropFirst()))
    let url = URL(fileURLWithPath: o.path)
    let (fileStart, centerHz) = try parseFileName(url.lastPathComponent)
    var reader = try IQReader(path: o.path)
    let rate = reader.layout.sampleRate
    guard rate > 0 else { throw UsageError(message: "\(o.path): sample rate is 0") }
    let offsetHz = o.vfoHz - centerHz
    guard abs(offsetHz) < rate / 2 else {
        throw UsageError(message: "--vfo \(Int(o.vfoHz)) Hz is outside the capture (centre \(Int(centerHz)) Hz, ±\(Int(rate / 2)) Hz)")
    }
    let startFrame = Int(o.startSeconds * rate)
    guard startFrame < reader.frameCount else {
        throw UsageError(message: "--start is past the end of the file (\(span(Double(reader.frameCount) / rate)))")
    }
    let stopFrame = o.stopSeconds.map { min(reader.frameCount, Int($0 * rate)) } ?? reader.frameCount
    let origin = fileStart.addingTimeInterval(o.startSeconds)   // time of the first replayed sample

    func makeReceiver(squelch: Float?) -> Receiver {
        Receiver(config: Receiver.Config(inputRate: rate, offsetHz: offsetHz, mode: o.mode,
                                         bandwidthHz: o.bandwidthHz, squelchDb: squelch))
    }

    // The threshold: given, or the median level of the first 60 s of the replayed span plus the margin.
    var squelchDb = o.squelchDb ?? 0
    var floorNote = ""
    if let margin = o.aboveFloorDb {
        let receiver = makeReceiver(squelch: nil)
        var audio: [Float] = []
        var levels: [Float] = []
        try reader.seek(toFrame: startFrame)
        try reader.forEachBlock(upTo: min(stopFrame, startFrame + Int(60 * rate))) { block in
            audio.removeAll(keepingCapacity: true)
            receiver.process(block, audio: &audio)
            levels.append(receiver.signalDb)
        }
        guard !levels.isEmpty else { throw UsageError(message: "no samples to measure the noise floor from") }
        levels.sort()
        let median = levels[levels.count / 2]
        squelchDb = median + margin
        floorNote = String(format: " (floor %.1f dBFS median of the first %@ + %.1f dB)", median,
                           span(Double(levels.count * IQReader.blockFrames) / rate), margin)
    }

    let receiver = makeReceiver(squelch: squelchDb)
    let audioRate = Receiver.audioRate
    var trigger = AutoRecordTrigger(sampleRate: audioRate, timing: o.timing.normalized())
    let timing = trigger.timing

    print("\(url.lastPathComponent)  \(Int(rate)) S/s, \(reader.layout.isFloat ? "float32" : "int16"), \(span(Double(reader.frameCount) / rate))")
    print(String(format: "centre %.0f Hz, vfo %.0f Hz (offset %+.0f Hz), %@ bw %.0f Hz, squelch %.1f dBFS%@",
                 centerHz, o.vfoHz, offsetHz, o.mode.label, o.bandwidthHz, squelchDb, floorNote))
    print(String(format: "start after %.1f s, stop after %.0f s, replaying %@ to %@ from %@",
                 timing.startAfter, timing.stopAfter, span(Double(startFrame) / rate),
                 span(Double(stopFrame) / rate), clock(origin)))
    print("")

    var recordings = 0, pops = 0
    var recordedFrames = 0
    var recordingStart: Int?
    var events: [AutoRecordTrigger.Event] = []
    var audio: [Float] = []
    var audioFrames = 0

    func time(_ frame: Int) -> Date { origin.addingTimeInterval(Double(frame) / audioRate) }
    func finish(stopAt frame: Int, note: String = "") {
        guard let first = recordingStart else { return }
        recordingStart = nil
        let frames = max(0, frame - first)
        recordings += 1
        recordedFrames += frames
        print("REC \(clock(time(first)))  \(span(Double(frames) / audioRate))\(note)")
    }
    func handle(_ events: [AutoRecordTrigger.Event], note: String = "") {
        for event in events {
            switch event {
            case .start(let frame): recordingStart = frame
            case .commit, .silence: break
            case .stop(let frame): finish(stopAt: frame, note: note)
            case .pop(let frame, let frames):
                pops += 1
                print("pop \(clock(time(frame)))  \(span(Double(frames) / audioRate))")
            }
        }
    }

    try reader.seek(toFrame: startFrame)
    try reader.forEachBlock(upTo: stopFrame) { block in
        audio.removeAll(keepingCapacity: true)
        receiver.process(block, audio: &audio)
        audioFrames += audio.count
        events.removeAll(keepingCapacity: true)
        trigger.advance(to: audioFrames, gateOpen: receiver.isSquelchOpen, into: &events)
        handle(events)
    }

    // A recording still open when the replay ends is cut where a retune would cut it.
    events.removeAll(keepingCapacity: true)
    trigger.cut(into: &events)
    handle(events, note: stopFrame < reader.frameCount ? "  (still open at --stop)" : "  (still open at end of file)")

    print("")
    print("\(recordings) recording\(recordings == 1 ? "" : "s"), \(pops) pop\(pops == 1 ? "" : "s"), "
          + "\(span(Double(recordedFrames) / audioRate)) recorded")
}

do {
    try run()
} catch let e as UsageError {
    print("AutoRecordReplay: \(e.message)")
    exit(2)
} catch {
    print("AutoRecordReplay: \(error)")
    exit(1)
}
