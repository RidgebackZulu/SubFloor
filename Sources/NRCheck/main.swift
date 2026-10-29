// NRCheck: runs a stretch of a recording through the noise reducer at Light, Medium and Strong,
// writes the results as WAVs to listen to, and prints the rough "voice above hiss" measure for each
// (the design spec's section 6). Compare with the Python spike: original 2.5 dB, medium 9.7 dB.
//
//   NRCheck <audio file> <start s> <seconds> <out dir>
//
// Writes original.wav, light.wav, medium.wav and strong.wav (strength 0, 0.5, 1): 16-bit mono PCM
// at 48 kHz, each peak-normalised to 0.7 like the spike.

@preconcurrency import AVFoundation
import DSPCore
import Foundation

let sampleRate = 48_000.0
let usage = "usage: NRCheck <audio file> <start s> <seconds> <out dir>"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("NRCheck: \(message)\n".utf8))
    exit(1)
}

/// Whether the converter's input block has already handed over the clip.
final class OneShot: @unchecked Sendable { var taken = false }

/// Mono samples at 48 kHz from `seconds` of the file starting at `start`; converts if the file is
/// another rate or has more than one channel (channels are averaged by AVAudioConverter).
func loadClip(path: String, start: Double, seconds: Double) throws -> [Float] {
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
    let inFormat = file.processingFormat
    let first = AVAudioFramePosition(start * inFormat.sampleRate)
    guard first >= 0, first < file.length else { fail("start \(start) s is beyond the end of the file (\(Double(file.length) / inFormat.sampleRate) s)") }
    file.framePosition = first
    let wanted = AVAudioFrameCount(min(Double(file.length - first), seconds * inFormat.sampleRate))
    guard let raw = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: wanted) else { fail("out of memory") }
    try file.read(into: raw, frameCount: wanted)

    let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
    if inFormat.sampleRate == sampleRate && inFormat.channelCount == 1 {
        return Array(UnsafeBufferPointer(start: raw.floatChannelData![0], count: Int(raw.frameLength)))
    }
    print(String(format: "converting %.0f Hz, %d channel(s) to 48000 Hz mono", inFormat.sampleRate, inFormat.channelCount))
    guard let converter = AVAudioConverter(from: inFormat, to: outFormat) else { fail("cannot convert this file's format") }
    let capacity = AVAudioFrameCount(Double(raw.frameLength) * sampleRate / inFormat.sampleRate) + 4096
    guard let converted = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { fail("out of memory") }
    let supplied = OneShot()
    var error: NSError?
    let status = converter.convert(to: converted, error: &error) { _, inputStatus in
        if supplied.taken { inputStatus.pointee = .endOfStream; return nil }
        supplied.taken = true
        inputStatus.pointee = .haveData
        return raw
    }
    if status == .error { fail("conversion failed: \(error?.localizedDescription ?? "unknown")") }
    return Array(UnsafeBufferPointer(start: converted.floatChannelData![0], count: Int(converted.frameLength)))
}

/// One fresh reducer, enabled before any audio, run over the clip; the output is shifted back by
/// the reducer's latency (the tail is fed as silence so the last samples come out).
func reduce(_ clip: [Float], strength: Double) -> [Float] {
    let latency = SpectralNoiseReducer().latency
    let reducer = NoiseReducer(sampleRate: sampleRate)
    reducer.update(NoiseReductionSettings(enabled: true, strength: strength))
    var buffer = clip + [Float](repeating: 0, count: latency)
    buffer.withUnsafeMutableBufferPointer { p in
        // Odd block sizes on purpose: the reducer must not care.
        var offset = 0, block = 480
        while offset < p.count {
            let n = min(block, p.count - offset)
            reducer.process(UnsafeMutableBufferPointer(rebasing: p[offset..<offset + n]))
            offset += n
            block = block == 480 ? 1000 : 480
        }
    }
    return Array(buffer[latency..<latency + clip.count])
}

func peakNormalised(_ x: [Float], to peak: Float = 0.7) -> [Float] {
    let top = x.reduce(0) { max($0, abs($1)) }
    guard top > 1e-9 else { return x }
    return x.map { $0 * peak / top }
}

func writeWAV(_ x: [Float], to url: URL) throws {
    var data = Data()
    func put32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    func put16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    let bytes = UInt32(x.count * 2)
    data.append(contentsOf: Array("RIFF".utf8)); put32(36 + bytes)
    data.append(contentsOf: Array("WAVEfmt ".utf8)); put32(16)
    put16(1); put16(1); put32(UInt32(sampleRate)); put32(UInt32(sampleRate) * 2); put16(2); put16(16)
    data.append(contentsOf: Array("data".utf8)); put32(bytes)
    for s in x { put16(UInt16(bitPattern: Int16((min(max(s, -1), 1) * 32767).rounded()))) }
    try data.write(to: url)
}

// MARK: The voice-above-hiss measure (spec section 6)

let frameLength = 4800                 // 0.1 s
let firstBin = 30, lastBin = 250       // 300 ... 2500 Hz at 10 Hz per bin

/// Spectral flatness (geometric over arithmetic mean of the power) of FFT bins 30...250 of the
/// Hann-windowed frame. A direct DFT of just those bins: 4800 is not a size vDSP's FFT takes.
final class FlatnessMeter {
    private let window: [Double]
    private let cosTable: [Double]
    private let sinTable: [Double]

    init() {
        window = (0..<frameLength).map { 0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(frameLength)) }
        cosTable = (0..<frameLength).map { cos(2 * Double.pi * Double($0) / Double(frameLength)) }
        sinTable = (0..<frameLength).map { sin(2 * Double.pi * Double($0) / Double(frameLength)) }
    }

    func flatness(_ frame: ArraySlice<Float>) -> Double {
        let x = zip(frame, window).map { Double($0) * $1 }
        var logSum = 0.0, sum = 0.0
        for bin in firstBin...lastBin {
            var re = 0.0, im = 0.0
            var idx = 0
            for n in 0..<frameLength {
                re += x[n] * cosTable[idx]
                im -= x[n] * sinTable[idx]
                idx += bin
                if idx >= frameLength { idx -= frameLength }
            }
            let power = re * re + im * im + 1e-30
            logSum += log(power)
            sum += power
        }
        let count = Double(lastBin - firstBin + 1)
        return exp(logSum / count) / (sum / count)
    }
}

func frameLevelsDb(_ x: [Float]) -> [Double] {
    (0..<(x.count / frameLength)).map { f in
        var sum = 0.0
        for s in x[f * frameLength..<(f + 1) * frameLength] { sum += Double(s) * Double(s) }
        return 10 * log10(sum / Double(frameLength) + 1e-12)
    }
}

func mean(_ values: [Double], at indices: [Int]) -> Double {
    indices.reduce(0) { $0 + values[$1] } / Double(indices.count)
}

// MARK: Main

let args = CommandLine.arguments
guard args.count == 5, let start = Double(args[2]), let seconds = Double(args[3]), start >= 0, seconds > 0 else { fail(usage) }
let outDir = URL(fileURLWithPath: args[4], isDirectory: true)

do {
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    let clip = try loadClip(path: args[1], start: start, seconds: seconds)
    guard clip.count >= frameLength else { fail("the clip is shorter than one 0.1 s frame") }
    print(String(format: "clip: %.2f s from %.1f s in %@", Double(clip.count) / sampleRate, start, (args[1] as NSString).lastPathComponent))

    let meter = FlatnessMeter()
    let frames = clip.count / frameLength
    let flatness = (0..<frames).map { meter.flatness(clip[$0 * frameLength..<($0 + 1) * frameLength]) }
    let voice = flatness.indices.filter { flatness[$0] < 0.25 }
    let hiss = flatness.indices.filter { flatness[$0] > 0.5 }
    print("frames: \(frames) total, \(voice.count) voice (flatness < 0.25), \(hiss.count) hiss (> 0.5)   [spec: 37 and 206]")
    guard !voice.isEmpty, !hiss.isEmpty else { fail("need both voice and hiss frames to score") }

    let variants: [(name: String, samples: [Float])] = [
        ("original", clip),
        ("light", reduce(clip, strength: 0)),
        ("medium", reduce(clip, strength: 0.5)),
        ("strong", reduce(clip, strength: 1)),
    ]
    for (name, samples) in variants {
        let out = peakNormalised(samples)
        let url = outDir.appendingPathComponent("\(name).wav")
        try writeWAV(out, to: url)
        let levels = frameLevelsDb(out)
        let score = mean(levels, at: voice) - mean(levels, at: hiss)
        print(String(format: "%-8@ voice above hiss: %5.1f dB   -> %@", name as NSString, score, url.path))
    }
} catch {
    fail("\(error)")
}
