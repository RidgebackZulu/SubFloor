import DSPCore
import Foundation

/// The SubFloor Dial's line protocol (one ASCII command per `\n`-terminated line, the same over USB
/// serial and Bluetooth). See `radiodial/PROTOCOL.md` in the dial's firmware repository.
enum DialProtocol {
    static let version = 2

    /// What the dial tells SubFloor.
    enum Event: Equatable {
        /// The dial's HELLO reply: firmware version, its tuning step and what the knob controls.
        case hello(firmware: String, stepHz: Double, knob: Knob)
        /// Knob turned: `steps` of `stepHz` from the step's grid. `seq` is echoed with the new frequency.
        case tune(seq: Int, steps: Int, stepHz: Double)
        /// Knob turned in bandwidth mode: `steps` of the mode's bandwidth step.
        case bandwidth(steps: Int)
        case step(hz: Double)
        case mode(DemodMode)
        case knob(Knob)
        case pong
        /// Knob turned on the scrub screen: `jumps` of `jump` seconds. `seq` is echoed with the new position.
        case scrubMove(seq: Int, jumps: Int, jump: Double)
        /// The jump size picked on the dial.
        case jump(seconds: Double)
        /// Tap on the scrub screen.
        case playToggle
    }

    enum Knob: String, Equatable { case tune, bandwidth = "bw" }

    static func parse(_ line: String) -> Event? {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let cmd = parts.first else { return nil }
        let args = Array(parts.dropFirst())
        switch cmd {
        case "HELLO":
            guard args.first == "SubFloorDial" else { return nil }
            let fields = keyValues(args.dropFirst(2))
            return .hello(firmware: args.count > 1 ? args[1] : "?",
                          stepHz: fields["step"].flatMap(Double.init) ?? 100,
                          knob: fields["knob"].flatMap(Knob.init(rawValue:)) ?? .tune)
        case "T":
            guard args.count == 3, let seq = Int(args[0]), let steps = Int(args[1]),
                  let step = Double(args[2]), step > 0 else { return nil }
            return .tune(seq: seq, steps: steps, stepHz: step)
        case "B":
            guard let n = args.first.flatMap(Int.init) else { return nil }
            return .bandwidth(steps: n)
        case "STEP":
            guard let hz = args.first.flatMap(Double.init), hz > 0 else { return nil }
            return .step(hz: hz)
        case "M":
            guard let m = args.first.flatMap({ DemodMode(rawValue: $0.lowercased()) }) else { return nil }
            return .mode(m)
        case "KNOB":
            guard let k = args.first.flatMap(Knob.init(rawValue:)) else { return nil }
            return .knob(k)
        case "J":
            guard args.count == 3, let seq = Int(args[0]), let jumps = Int(args[1]),
                  let jump = Double(args[2]), jump > 0 else { return nil }
            return .scrubMove(seq: seq, jumps: jumps, jump: jump)
        case "JUMP":
            guard let s = args.first.flatMap(Double.init), s > 0 else { return nil }
            return .jump(seconds: s)
        case "PLAY":
            return .playToggle
        case "PONG":
            return .pong
        default:
            return nil
        }
    }

    private static func keyValues(_ tokens: ArraySlice<String>) -> [String: String] {
        var out: [String: String] = [:]
        for t in tokens {
            let kv = t.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 { out[kv[0]] = kv[1] }
        }
        return out
    }

    // MARK: SubFloor → dial

    static func hello(host: String) -> String {
        // The host name ends the line: the dial shows everything after "host=".
        "HELLO SubFloor \(version) host=\(host.replacingOccurrences(of: "\n", with: " "))"
    }

    static func state(vfoHz: Double, mode: DemodMode, bandwidthHz: Double, running: Bool) -> String {
        "S f=\(hz(vfoHz)) m=\(mode.label) bw=\(hz(bandwidthHz)) run=\(running ? 1 : 0)"
    }

    /// The VFO; `seq` when it answers the dial's tune message of that number.
    static func frequency(_ vfoHz: Double, seq: Int? = nil) -> String {
        seq.map { "F \(hz(vfoHz)) \($0)" } ?? "F \(hz(vfoHz))"
    }

    static func mode(_ m: DemodMode) -> String { "M \(m.label)" }
    static func bandwidth(_ bwHz: Double) -> String { "BW \(hz(bwHz))" }
    static func signal(_ db: Float) -> String { String(format: "SIG %.1f", max(db, -200)) }

    /// Scrub mode on: the recording's start (UTC seconds since midnight), length, position, play state, jump size and
    /// lane title. The title ends the line: the dial shows everything after "title=". `t0` goes to the millisecond
    /// (a recording's start is), not `%.2f` like the other seconds, so the dial's clock truncates to the same tenth
    /// as `RecordingsFormat.clock`; only the position's 0.01 s rounding is left between them.
    static func scrubOn(startSecondOfDay: Double, length: Double, position: Double, playing: Bool, jump: Double,
                        title: String) -> String {
        "SCRUB on t0=\(String(format: "%.3f", startSecondOfDay)) len=\(seconds(length)) pos=\(seconds(position)) "
            + "play=\(playing ? 1 : 0) jump=\(jumpText(jump)) title=\(title.replacingOccurrences(of: "\n", with: " "))"
    }

    static let scrubOff = "SCRUB off"

    /// The playback position; `seq` when it answers the dial's `J` message of that number.
    static func position(_ s: Double, seq: Int? = nil) -> String {
        seq.map { "POS \(seconds(s)) \($0)" } ?? "POS \(seconds(s))"
    }

    static func playing(_ on: Bool) -> String { "PLAY \(on ? 1 : 0)" }
    static func jump(_ s: Double) -> String { "JUMP \(jumpText(s))" }

    /// Whether the dial's firmware (the HELLO version, "major.minor[.patch]") knows the scrub lines: 1.1 or later.
    /// Anything unparsable counts as older.
    static func supportsScrub(firmware: String) -> Bool {
        let parts = firmware.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.contains(where: { $0 == nil }) else { return false }
        let numbers = parts.compactMap { $0 }
        let major = numbers[0], minor = numbers.count > 1 ? numbers[1] : 0
        return major > 1 || (major == 1 && minor >= 1)
    }

    static let ping = "PING"
    static let bye = "BYE"

    private static func seconds(_ v: Double) -> String { String(format: "%.2f", v) }
    private static func jumpText(_ v: Double) -> String { String(format: "%g", v) }

    private static func hz(_ v: Double) -> String { String(Int64(v.rounded())) }
}

/// Splits a byte stream into lines (either link delivers arbitrary chunks).
struct LineSplitter {
    private var buffer = Data()

    mutating func append(_ data: Data) -> [String] {
        buffer.append(data)
        var lines: [String] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            if let s = String(data: lineData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
                lines.append(s)
            }
        }
        if buffer.count > 4096 { buffer.removeAll() }  // not our protocol
        return lines
    }
}
