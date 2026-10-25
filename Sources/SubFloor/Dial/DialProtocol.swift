import DSPCore
import Foundation

/// The SubFloor Dial's line protocol (one ASCII command per `\n`-terminated line, the same over USB
/// serial and Bluetooth). See `radiodial/PROTOCOL.md` in the dial's firmware repository.
enum DialProtocol {
    static let version = 1

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
    static let ping = "PING"
    static let bye = "BYE"

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
