import Foundation

/// The G3PLX PSK31 Varicode alphabet for ASCII 0...127.
///
/// Source: P. Martinez G3PLX, "PSK31: A New Radio-Teletype Mode", QEX July/Aug 1999, Table 1
/// (reprinted from RadCom Dec 1998/Jan 1999); cross-checked against the Wikipedia "Varicode" table.
/// Codes are sent left bit first. In BPSK a 0 is a phase reversal and a 1 a steady carrier.
/// Characters are separated by (at least) two zeros, and no code contains "00".
public enum Varicode {
    /// Index = ASCII code.
    static let table: [String] = [
        "1010101011", "1011011011", "1011101101", "1101110111", "1011101011", "1101011111", "1011101111", "1011111101",
        "1011111111", "11101111", "11101", "1101101111", "1011011101", "11111", "1101110101", "1110101011",
        "1011110111", "1011110101", "1110101101", "1110101111", "1101011011", "1101101011", "1101101101", "1101010111",
        "1101111011", "1101111101", "1110110111", "1101010101", "1101011101", "1110111011", "1011111011", "1101111111",
        "1", "111111111", "101011111", "111110101", "111011011", "1011010101", "1010111011", "101111111",
        "11111011", "11110111", "101101111", "111011111", "1110101", "110101", "1010111", "110101111",
        "10110111", "10111101", "11101101", "11111111", "101110111", "101011011", "101101011", "110101101",
        "110101011", "110110111", "11110101", "110111101", "111101101", "1010101", "111010111", "1010101111",
        "1010111101", "1111101", "11101011", "10101101", "10110101", "1110111", "11011011", "11111101",
        "101010101", "1111111", "111111101", "101111101", "11010111", "10111011", "11011101", "10101011",
        "11010101", "111011101", "10101111", "1101111", "1101101", "101010111", "110110101", "101011101",
        "101110101", "101111011", "1010101101", "111110111", "111101111", "111111011", "1010111111", "101101101",
        "1011011111", "1011", "1011111", "101111", "101101", "11", "111101", "1011011",
        "101011", "1101", "111101011", "10111111", "11011", "111011", "1111", "111",
        "111111", "110111111", "10101", "10111", "101", "110111", "1111011", "1101011",
        "11011111", "1011101", "111010101", "1010110111", "110111011", "1010110101", "1011010111", "1110110101",
    ]

    /// Longest code in the alphabet, in bits.
    static let maxLength = 10

    /// Code value (bits read MSB first; every code starts with 1, so the value fixes the length) → ASCII.
    static let byValue: [UInt32: UInt8] = {
        var map = [UInt32: UInt8]()
        for (ascii, bits) in table.enumerated() { map[UInt32(bits, radix: 2)!] = UInt8(ascii) }
        return map
    }()

    /// The code for `c`, left bit first; empty for characters outside ASCII.
    public static func encode(_ c: Character) -> [Bool] {
        guard let ascii = c.asciiValue else { return [] }
        return table[Int(ascii)].map { $0 == "1" }
    }

    /// The character for a complete code (without the "00" separator), or nil if it is not one.
    public static func decode(_ bits: [Bool]) -> Character? {
        guard !bits.isEmpty, bits.count <= maxLength else { return nil }
        let value = bits.reduce(UInt32(0)) { $0 << 1 | ($1 ? 1 : 0) }
        return decode(value: value).map { Character(Unicode.Scalar($0)) }
    }

    /// ASCII for a code given as its bit value (MSB = first bit sent), or nil.
    static func decode(value: UInt32) -> UInt8? { byValue[value] }
}

/// Collects Varicode bits into characters: a character ends at "00".
struct VaricodeAssembler {
    private var code: UInt32 = 0
    private var length = 0
    private var zeros = 0
    private var start = 0

    struct Character { var ascii: UInt8; var start: Int; var end: Int }

    mutating func push(_ bit: Bool, symbol: Int) -> Character? {
        if bit {
            if length == 0 { start = symbol }
            if zeros == 1 && length > 0 { appendBit(0) }
            zeros = 0
            appendBit(1)
            return nil
        }
        zeros += 1
        guard zeros == 2, length > 0 else { return nil }
        defer { code = 0; length = 0 }
        guard length <= Varicode.maxLength, let ascii = Varicode.decode(value: code) else { return nil }
        return Character(ascii: ascii, start: start, end: symbol)
    }

    private mutating func appendBit(_ b: UInt32) {
        length += 1
        if length <= Varicode.maxLength { code = code << 1 | b }
    }
}
