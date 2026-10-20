import Foundation

/// WSPR Type 1 message coding: source packing, the K = 32 rate-1/2 convolutional code, the
/// bit-reversal interleaver and the sync vector.
///
/// Written from public protocol descriptions only; no WSJT-X or wsprd source was read. Sources, and
/// what each one confirms:
/// - G4JNT, "The WSPR Coding Process: Non-normative description", http://g4jnt.com/WSPR_Coding_Process.pdf
///   (the defining description; not reachable from the build container, so only its search-engine
///   excerpts were seen: the leading-space rule for callsigns, and bit-reversal interleaving with
///   I = 1 → J = 128 and I = 13 → J = 176 skipped).
/// - Wsprry Pi docs, "About WSPR",
///   https://github.com/WsprryPi/WsprryPi-Docs/blob/main/docs/About_WSPR/index.md: 28 + 15 + 7 = 50
///   bits; K = 32, r = 1/2; (50 + K − 1)·2 = 162 symbols; keying 12000/8192 baud; one sync and one data
///   bit per channel symbol.
/// - LZ1NY, https://github.com/LZ1NY/LZ0DLS (README): protocol table (sync is the LSB, data the MSB),
///   and a full listing for "LZ0DLS KN12 10": packed bytes, the 162 sync bits and channel symbols.
/// - S. Harden / W8ZLW, https://github.com/swharden/WsprSharp/blob/main/dev/WsprNetVB/readme.md:
///   the same kind of listing for "W8ZLW AA00 3"; README.md there gives bytes and symbols for "AJ4VD EL89 3".
/// - https://github.com/agamez/whisperice: reference/test_vectors/k1abc_fn42_37.txt holds verbatim
///   `wsprcode` output for "K1ABC FN42 37" (n = 259047992, m = 2896997, bytes, sync, symbols); its
///   docs/protocol.md gives in prose the callsign and locator/power formulas, the two polynomials with
///   POLY1's parity first, and the bit-reversal interleaver.
/// - Hackaday, "Encoding WSPRs", https://hackaday.io/project/166875-careless-wspr/log/167301-encoding-wsprs
///   (seen through search excerpts): polynomials 0xF2D05351 and 0xE4613C47.
/// - swharden.com, "WSPR - Protocol Notes", https://swharden.com/software/FSKview/wspr/ (seen through
///   search excerpts): the interleaver loop over 8-bit addresses and Symbol = Sync + 2 × Data.
///
/// Every constant was checked against at least two of these: the sync vector against three listings
/// that agree bit for bit; the packing rules against the four published byte strings; the
/// polynomials, their output order and the interleaver end to end against the four published
/// 162-symbol vectors (`WSPRCodecTests`).
public enum WSPRCodec {
    /// Payload bits in a Type 1 message.
    public static let messageBits = 50
    /// Constraint length of the convolutional code.
    public static let constraintLength = 32
    /// Information bits fed to the encoder: the message plus K − 1 zero tail bits.
    public static let encodedBits = messageBits + constraintLength - 1
    /// Channel symbols per transmission, two code bits per information bit.
    public static let symbolCount = 2 * encodedBits
    /// The Layland-Lushbaugh generator polynomials. Each new bit enters bit 0 of a 32-bit register;
    /// the two code bits are the parities of `register & poly1` then `register & poly2`.
    public static let poly1: UInt32 = 0xF2D0_5351
    public static let poly2: UInt32 = 0xE461_3C47
    /// 37·36·10·27³: callsign codes at or above this are not standard callsigns.
    static let callsignCodes = 262_177_560
    /// 180·180 four-character locators.
    static let locatorCodes = 32_400

    /// The 162-bit pseudo-random sync vector, sent as the low bit of every channel symbol.
    public static let syncVector: [UInt8] = [
        1, 1, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 1, 1, 1, 0, 0, 0, 1, 0, 0, 1, 0, 1, 1, 1, 1, 0, 0, 0,
        0, 0, 0, 0, 1, 0, 0, 1, 0, 1, 0, 0, 0, 0, 0, 0, 1, 0, 1, 1, 0, 0, 1, 1, 0, 1, 0, 0, 0, 1,
        1, 0, 1, 0, 0, 0, 0, 1, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 0, 1, 0, 0, 1, 0, 1, 1, 0, 0, 0, 1,
        1, 0, 1, 0, 1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 1, 0, 0, 1, 1, 1, 0, 1, 1, 0, 0, 1, 1,
        0, 1, 0, 0, 0, 1, 1, 1, 0, 0, 0, 0, 0, 1, 0, 1, 0, 0, 1, 1, 0, 0, 0, 0, 0, 0, 0, 1, 1, 0,
        1, 0, 1, 1, 0, 0, 0, 1, 1, 0, 0, 0,
    ]

    /// Whether `dBm` is a Type 1 power level: 0…60 ending in 0, 3 or 7.
    public static func isValidPower(_ dBm: Int) -> Bool {
        (0...60).contains(dBm) && [0, 3, 7].contains(dBm % 10)
    }

    // MARK: - Source coding

    /// Packs a Type 1 message into 50 bits, most significant first, as 7 bytes whose last 6 bits are
    /// zero: the 28-bit callsign code N, then the 22-bit M = locator·128 + power + 64.
    ///
    /// The callsign is aligned so that its third character is a digit (a leading space is added
    /// when the second is the digit, so "K1ABC" becomes " K1ABC") and padded with spaces to six. With
    /// characters coded 0–9 → 0–9, A–Z → 10–35 and space → 36,
    /// `N = ((((c0·36 + c1)·10 + c2)·27 + c3−10)·27 + c4−10)·27 + c5−10`. For a locator `L1 L2 D3 D4`
    /// (letters A–R as 0–17), `locator = (179 − 10·L1 − D3)·180 + 10·L2 + D4`.
    ///
    /// Returns nil for anything that is not a standard callsign, a four-character locator and a
    /// valid power level (compound callsigns and six-character locators need Type 2 and 3 messages).
    public static func pack(call: String, grid: String, powerDbm: Int) -> [UInt8]? {
        guard let n = callsignCode(call), let locator = locatorCode(grid), isValidPower(powerDbm) else { return nil }
        let m = locator * 128 + powerDbm + 64
        let value = (UInt64(n) << 22 | UInt64(m)) << 6  // 56 bits, payload left-aligned
        return (0..<7).map { UInt8(truncatingIfNeeded: value >> UInt64(48 - 8 * $0)) }
    }

    /// Inverse of `pack`. Returns nil unless the bytes hold a plausible Type 1 message: a standard
    /// callsign, a locator code below 180², a valid power level and zero padding bits.
    public static func unpack(_ bytes: [UInt8]) -> (call: String, grid: String, powerDbm: Int)? {
        guard bytes.count >= 7, bytes[6] & 0x3F == 0 else { return nil }
        let value = bytes[0..<7].reduce(UInt64(0)) { $0 << 8 | UInt64($1) } >> 6
        let n = Int(value >> 22), m = Int(value & 0x3F_FFFF)
        guard let call = callsign(fromCode: n) else { return nil }
        let locator = m >> 7, power = (m & 127) - 64
        guard locator < locatorCodes, isValidPower(power) else { return nil }
        let q = 179 - locator / 180, r = locator % 180
        let letters = Array("ABCDEFGHIJKLMNOPQR")
        let grid = String([letters[q / 10], letters[r / 10]]) + "\(q % 10)\(r % 10)"
        return (call, grid, power)
    }

    /// The six-character aligned callsign, or nil if it is not a standard callsign.
    static func alignedCallsign(_ call: String) -> [Character]? {
        var c = Array(call.uppercased())
        guard (1...6).contains(c.count), c.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        if c.count >= 2, !(c.count >= 3 && c[2].isNumber), c[1].isNumber { c.insert(" ", at: 0) }
        guard c.count <= 6 else { return nil }
        c += [Character](repeating: " ", count: 6 - c.count)
        return isPlausible(c) ? c : nil
    }

    /// A standard callsign, aligned: a prefix of one or two characters with at least one letter (a
    /// leading space stands for a one-letter prefix), a digit third, then one to three letters and
    /// trailing spaces.
    private static func isPlausible(_ c: [Character]) -> Bool {
        let letter = { (ch: Character) in ch.isASCII && ch.isLetter }
        let digit = { (ch: Character) in ch.isASCII && ch.isNumber }
        let alphanumeric = { (ch: Character) in letter(ch) || digit(ch) }
        guard c.count == 6, digit(c[2]), letter(c[3]) else { return false }
        let prefixOK = c[0] == " "
            ? letter(c[1])
            : alphanumeric(c[0]) && alphanumeric(c[1]) && (letter(c[0]) || letter(c[1]))
        return prefixOK && c[3...].drop(while: letter).allSatisfy { $0 == " " }
    }

    private static func characterCode(_ ch: Character) -> Int {
        guard let a = ch.asciiValue else { return 36 }
        switch a {
        case 48...57: return Int(a) - 48
        case 65...90: return Int(a) - 55
        default: return 36
        }
    }

    private static func callsignCode(_ call: String) -> Int? {
        guard let c = alignedCallsign(call) else { return nil }
        var n = characterCode(c[0])
        n = n * 36 + characterCode(c[1])
        n = n * 10 + characterCode(c[2])
        for ch in c[3...] { n = n * 27 + characterCode(ch) - 10 }
        return n
    }

    private static func callsign(fromCode code: Int) -> String? {
        guard code >= 0, code < callsignCodes else { return nil }
        let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ ")
        var n = code
        var c = [Character](repeating: " ", count: 6)
        for i in stride(from: 5, through: 3, by: -1) { c[i] = alphabet[n % 27 + 10]; n /= 27 }
        c[2] = alphabet[n % 10]; n /= 10
        c[1] = alphabet[n % 36]; n /= 36
        c[0] = alphabet[n]
        guard isPlausible(c) else { return nil }
        return String(c).trimmingCharacters(in: .whitespaces)
    }

    private static func locatorCode(_ grid: String) -> Int? {
        let g = Array(grid.uppercased())
        guard g.count == 4,
              let l1 = g[0].asciiValue, let l2 = g[1].asciiValue, (65...82).contains(l1), (65...82).contains(l2),
              let d3 = g[2].wholeNumberValue, let d4 = g[3].wholeNumberValue, g[2].isASCII, g[3].isASCII
        else { return nil }
        return (179 - 10 * Int(l1 - 65) - d3) * 180 + 10 * Int(l2 - 65) + d4
    }

    // MARK: - Channel coding

    /// Parity (0 or 1) of the register's taps.
    @inline(__always) static func parity(_ x: UInt32) -> UInt8 { UInt8(x.nonzeroBitCount & 1) }

    /// The 162 code bits (0 or 1) of the first 50 bits of `bytes` (most significant first) followed by
    /// 31 zero tail bits, two per information bit: the `poly1` parity, then the `poly2` parity.
    public static func convolve(_ bytes: [UInt8]) -> [UInt8] {
        precondition(bytes.count * 8 >= messageBits, "WSPR payload needs 7 bytes")
        var out = [UInt8]()
        out.reserveCapacity(symbolCount)
        var register: UInt32 = 0
        for i in 0..<encodedBits {
            let bit: UInt32 = i < messageBits ? UInt32(bytes[i / 8] >> UInt8(7 - i % 8) & 1) : 0
            register = register << 1 | bit
            out.append(parity(register & poly1))
            out.append(parity(register & poly2))
        }
        return out
    }

    /// Destination of each source bit: counting 8-bit addresses 0…255 up, each address whose bit
    /// reversal is below 162 takes the next source bit at that reversed position.
    static let interleaveMap: [Int] = {
        var map = [Int]()
        map.reserveCapacity(symbolCount)
        for address in 0..<256 {
            let reversed = Int(UInt8(address).bitReversed)
            if reversed < symbolCount { map.append(reversed) }
        }
        return map
    }()

    /// Bit-reversal interleaving of the 162 code bits (works on any per-symbol values).
    public static func interleave(_ bits: [UInt8]) -> [UInt8] {
        precondition(bits.count == symbolCount)
        var out = [UInt8](repeating: 0, count: symbolCount)
        for (source, destination) in interleaveMap.enumerated() { out[destination] = bits[source] }
        return out
    }

    /// Inverse of `interleave`.
    public static func deinterleave(_ bits: [UInt8]) -> [UInt8] {
        precondition(bits.count == symbolCount)
        return interleaveMap.map { bits[$0] }
    }

    /// `deinterleave` for soft metrics.
    public static func deinterleave(_ soft: [Float]) -> [Float] {
        precondition(soft.count == symbolCount)
        return interleaveMap.map { soft[$0] }
    }

    /// The 162 channel symbols (0…3), `sync[i] + 2 × data[i]`, where data is the interleaved code.
    public static func channelSymbols(call: String, grid: String, powerDbm: Int) -> [UInt8]? {
        guard let bytes = pack(call: call, grid: grid, powerDbm: powerDbm) else { return nil }
        let data = interleave(convolve(bytes))
        return zip(syncVector, data).map { $0 + 2 * $1 }
    }
}

private extension UInt8 {
    var bitReversed: UInt8 {
        var x = self, r: UInt8 = 0
        for _ in 0..<8 { r = r << 1 | (x & 1); x >>= 1 }
        return r
    }
}
