import Foundation

/// The parts of a decoded FT8 or WSPR message that tell who is talking: callsigns, grid and report.
/// Parsing is forgiving: anything that does not fit the standard shapes is `.other`, with no fields.
public struct SlotMessage: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case cq, call, report, rogerReport, rr73, rrr, seventyThree, wspr, other
    }

    public var kind: Kind
    /// The station called (nil for a CQ, or a hash that could not be resolved).
    public var to: String?
    /// The sender.
    public var from: String?
    /// A 4- or 6-character Maidenhead locator, upper case.
    public var grid: String?
    /// A signal report (`-12`, the `R` of a roger report dropped) or, for WSPR, the power in dBm.
    public var report: String?

    public init(kind: Kind, to: String? = nil, from: String? = nil, grid: String? = nil, report: String? = nil) {
        self.kind = kind
        self.to = to
        self.from = from
        self.grid = grid
        self.report = report
    }

    public static func parse(_ text: String, mode: ModeID) -> SlotMessage {
        let tokens = text.split(whereSeparator: \.isWhitespace).map { $0.uppercased() }
        let other = SlotMessage(kind: .other)
        switch mode {
        case .wspr: return parseWSPR(tokens) ?? other
        case .ft8: return parseFT8(tokens) ?? other
        case .cw, .psk31, .rtty: return other
        }
    }

    /// 3–11 characters of letters, digits and `/`, with at least one of each; a hashed call
    /// (`<PJ4/K1ABC>`) is unwrapped first.
    public static func isCallsign(_ s: String) -> Bool {
        let call = unwrapped(s.uppercased())
        guard (3...11).contains(call.count) else { return false }
        var hasDigit = false, hasLetter = false
        for c in call.unicodeScalars {
            switch c {
            case "0"..."9": hasDigit = true
            case "A"..."Z": hasLetter = true
            case "/": break
            default: return false
            }
        }
        return hasDigit && hasLetter
    }

    private static func unwrapped(_ s: String) -> String {
        s.hasPrefix("<") && s.hasSuffix(">") && s.count > 2 ? String(s.dropFirst().dropLast()) : s
    }

    private static func parseWSPR(_ t: [String]) -> SlotMessage? {
        switch t.count {
        case 3 where isCallsign(t[0]) && Maidenhead.isGrid(t[1]) && isNumber(t[2]):
            SlotMessage(kind: .wspr, from: unwrapped(t[0]), grid: t[1], report: t[2])
        case 2 where isCallsign(t[0]) && isNumber(t[1]):
            SlotMessage(kind: .wspr, from: unwrapped(t[0]), report: t[1])
        default: nil
        }
    }

    private static func parseFT8(_ t: [String]) -> SlotMessage? {
        if t.first == "CQ" { return parseCQ(Array(t.dropFirst())) }
        guard t.count == 2 || t.count == 3, let to = addressee(t[0]), isCallsign(t[1]) else { return nil }
        let from = unwrapped(t[1])
        guard t.count == 3 else { return SlotMessage(kind: .call, to: to, from: from) }
        let last = t[2]
        switch last {
        case "RR73": return SlotMessage(kind: .rr73, to: to, from: from)
        case "RRR": return SlotMessage(kind: .rrr, to: to, from: from)
        case "73": return SlotMessage(kind: .seventyThree, to: to, from: from)
        default: break
        }
        if Maidenhead.isGrid(last) { return SlotMessage(kind: .call, to: to, from: from, grid: last) }
        if isReport(last) { return SlotMessage(kind: .report, to: to, from: from, report: last) }
        if last.hasPrefix("R"), isReport(String(last.dropFirst())) {
            return SlotMessage(kind: .rogerReport, to: to, from: from, report: String(last.dropFirst()))
        }
        return nil
    }

    /// `CQ [modifier] CALL [GRID]`; `rest` is what follows the CQ. The modifier (DX, POTA, a region)
    /// is ignored.
    private static func parseCQ(_ rest: [String]) -> SlotMessage? {
        var rest = rest
        var grid: String?
        if rest.count >= 2, let last = rest.last, Maidenhead.isGrid(last) {
            grid = last
            rest.removeLast()
        }
        guard let call = rest.last, rest.count <= 2, call != "RR73", isCallsign(call) else { return nil }
        return SlotMessage(kind: .cq, from: unwrapped(call), grid: grid)
    }

    /// A callsign, or `<...>` (a hash the decoder could not resolve), which names no one.
    private static func addressee(_ s: String) -> String?? {
        if s == "<...>" { return .some(nil) }
        return isCallsign(s) ? .some(unwrapped(s)) : nil
    }

    private static func isReport(_ s: String) -> Bool {
        s.count == 3 && (s.hasPrefix("+") || s.hasPrefix("-")) && s.dropFirst().allSatisfy(\.isASCIIDigit)
    }

    private static func isNumber(_ s: String) -> Bool { !s.isEmpty && s.allSatisfy(\.isASCIIDigit) }
}

private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}

/// Maidenhead locators: field (20° × 10°), square (2° × 1°), optional subsquare (5′ × 2.5′).
public enum Maidenhead {
    /// `[A-R]{2}[0-9]{2}` with an optional `[A-X]{2}`, in either case. `RR73` is the FT8 sign-off, not a grid.
    public static func isGrid(_ s: String) -> Bool {
        let g = s.uppercased()
        return g != "RR73" && center(g) != nil
    }

    /// The middle of the square (or subsquare); nil for anything that is not a grid.
    public static func center(_ grid: String) -> (lat: Double, lon: Double)? {
        let c = Array(grid.uppercased().unicodeScalars.map(\.value))
        guard c.count == 4 || c.count == 6 else { return nil }
        let a = UInt32(("A" as Unicode.Scalar).value), zero = UInt32(("0" as Unicode.Scalar).value)
        func letter(_ i: Int, upTo last: Character) -> Double? {
            guard c[i] >= a, c[i] <= last.unicodeScalars.first!.value else { return nil }
            return Double(c[i] - a)
        }
        func digit(_ i: Int) -> Double? { (zero...(zero + 9)).contains(c[i]) ? Double(c[i] - zero) : nil }
        guard let fieldLon = letter(0, upTo: "R"), let fieldLat = letter(1, upTo: "R"),
              let squareLon = digit(2), let squareLat = digit(3) else { return nil }
        var lon = -180 + fieldLon * 20 + squareLon * 2
        var lat = -90 + fieldLat * 10 + squareLat
        if c.count == 6 {
            guard let subLon = letter(4, upTo: "X"), let subLat = letter(5, upTo: "X") else { return nil }
            lon += subLon * 5 / 60 + 2.5 / 60
            lat += subLat * 2.5 / 60 + 1.25 / 60
        } else {
            lon += 1
            lat += 0.5
        }
        return (lat, lon)
    }
}
