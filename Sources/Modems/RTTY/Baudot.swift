import Foundation

/// ITA2 ("Baudot") 5-bit teleprinter code, with the US TTY figures set that amateur RTTY uses.
///
/// Source: ITU-T Recommendation S.1 (International Telegraph Alphabet No. 2), with the US figures
/// variants (BELL on S, `$` on D, `'` on J, `!` on F, `"` on Z, `#` on H, `&` on G, `;` on V) as in
/// ARRL handbooks and fldigi. A code's bit 0 is the first data bit sent after the start bit;
/// 1 = mark. Codes 27 (FIGS) and 31 (LTRS) shift between the two sets; NUL (0), space (4), LF (2)
/// and CR (8) are the same in both.
public enum Baudot {
    public static let figs: UInt8 = 27
    public static let ltrs: UInt8 = 31
    static let space: UInt8 = 4

    /// Index = code. "\0" marks the shift codes and NUL; BELL is "\u{7}".
    static let letters: [Character] = [
        "\0", "E", "\n", "A", " ", "S", "I", "U", "\r", "D", "R", "J", "N", "F", "C", "K",
        "T", "Z", "L", "W", "H", "Y", "P", "Q", "O", "B", "G", "\0", "M", "X", "V", "\0",
    ]
    static let figures: [Character] = [
        "\0", "3", "\n", "-", " ", "\u{7}", "8", "7", "\r", "$", "4", "'", ",", "!", ":", "(",
        "5", "\"", ")", "2", "#", "6", "0", "1", "9", "?", "&", "\0", ".", "/", ";", "\0",
    ]

    private static let letterCodes: [Character: UInt8] = codes(of: letters)
    private static let figureCodes: [Character: UInt8] = codes(of: figures)

    private static func codes(of table: [Character]) -> [Character: UInt8] {
        var map = [Character: UInt8]()
        for (code, c) in table.enumerated() where c != "\0" { map[c] = UInt8(code) }
        return map
    }

    /// The codes for `text`, upper-cased, starting in letters, with LTRS/FIGS inserted where the
    /// shift changes. Characters ITA2 lacks are skipped; "\n" is sent as CR LF.
    ///
    /// `unshiftOnSpace`: the receiver returns to letters after every space (USOS, the amateur
    /// default), so a figure that follows a space gets a fresh FIGS.
    public static func encode(_ text: String, unshiftOnSpace: Bool = true) -> [UInt8] {
        var out: [UInt8] = []
        var inFigures = false
        for c in text.uppercased() {
            if c == "\n" {
                out += [8, 2]
                continue
            }
            if let code = letterCodes[c], code == space || code == 8 || code == 2 {
                out.append(code)
                if code == space && unshiftOnSpace { inFigures = false }
            } else if let code = letterCodes[c] {
                if inFigures { out.append(ltrs); inFigures = false }
                out.append(code)
            } else if let code = figureCodes[c] {
                if !inFigures { out.append(figs); inFigures = true }
                out.append(code)
            }
        }
        return out
    }

    /// Turns received codes into characters, following the LTRS/FIGS shift.
    public struct Decoder: Sendable {
        public var unshiftOnSpace = true
        public private(set) var inFigures = false

        public init(unshiftOnSpace: Bool = true) { self.unshiftOnSpace = unshiftOnSpace }

        /// The character for `code` (its low 5 bits), or nil for a shift, NUL or BELL. CR and LF
        /// come back as "\r" and "\n".
        public mutating func decode(_ code: UInt8) -> Character? {
            let c = code & 31
            switch c {
            case Baudot.figs: inFigures = true; return nil
            case Baudot.ltrs: inFigures = false; return nil
            case Baudot.space:
                if unshiftOnSpace { inFigures = false }
                return " "
            default:
                let ch = (inFigures ? Baudot.figures : Baudot.letters)[Int(c)]
                return ch == "\0" || ch == "\u{7}" ? nil : ch
            }
        }
    }
}
