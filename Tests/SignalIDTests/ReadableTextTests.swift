import Foundation
import Testing
@testable import SignalID

/// `ReadableText`: what a trial decode's text is worth as evidence. Words read high; what a decoder prints from noise,
/// random bits or a cypher reads low. Cheap: a few hundred short strings.
struct ReadableTextTests {
    @Test func wordsScoreHigh() {
        #expect(ReadableText.score("CQ CQ DE K1ABC K1ABC PSE K") >= 0.7)
        let weather = """
            SECURITE SECURITE. GALE WARNING ISSUED 1200 UTC. NORTH SEA: WIND SOUTHWEST 6 TO GALE 8, BECOMING WEST \
            LATER. SEA ROUGH. RAIN THEN SHOWERS. VISIBILITY GOOD, OCCASIONALLY POOR.
            """
        #expect(ReadableText.score(weather) >= 0.7)
        // A keyboard QSO in PSK31's lower case, names and places among the words.
        #expect(ReadableText.score("hello bob, thanks for the call. name here is john, qth london. rst 599. how copy?") >= 0.7)
        #expect(ReadableText.score("K1ABC DE G4XYZ UR RST 599 599 NAME JOHN QTH FN42 HW CPY? K1ABC DE G4XYZ KN") >= 0.7)
    }

    @Test func noiseScoresLow() {
        var random = SynthRandom(seed: 8, stream: 1)
        var most: Float = 0
        for _ in 0..<200 {
            most = max(most, ReadableText.score(Self.baudot(codes: 300, &random)))
            most = max(most, ReadableText.score(Self.varicode(bits: 800, &random)))
        }
        #expect(most <= 0.3, "noise read \(most)")
        // Nothing at all, or only symbols.
        #expect(ReadableText.score("") == 0)
        #expect(ReadableText.score("#$%&'()*+") == 0)
    }

    @Test func cypherScoresLow() {
        var random = SynthRandom(seed: 9, stream: 1)
        let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        for _ in 0..<100 {
            let groups = (0..<12).map { _ in String((0..<5).map { _ in letters[Int(random.next() % 26)] }) }
            let text = groups.joined(separator: " ")
            #expect(ReadableText.score(text) <= 0.3, "\(text)")
        }
        // Five-figure groups too.
        #expect(ReadableText.score("37192 04821 99310 57720 18834 60271") <= 0.3)
    }

    /// A few words in a burst of noise prove nothing: the score scales down below `minimumCharacters` counted.
    @Test func aWordOrTwoIsNoProof() {
        #expect(ReadableText.score("THE") < 0.3)
        #expect(ReadableText.score("TU 599 05 NJ") < 0.5)
    }

    // MARK: What decoders print from noise

    /// ITA2 letters and US figures (`Baudot` in Modems), "\0" for NUL and the shifts.
    static let letters = Array("\0E\nA SIU\rDRJNFCKTZLWHYPQOBG\0MXV\0")
    static let figures = Array("\03\n- \u{7}87\r$4',!:(5\")2#6019?&\0./;\0")

    /// `codes` random 5-bit codes through a Baudot decoder (LTRS, FIGS, unshift on space).
    static func baudot(codes: Int, _ random: inout SynthRandom) -> String {
        var out = "", figs = false
        for _ in 0..<codes {
            let code = Int(random.next() % 32)
            if code == 27 { figs = true; continue }
            if code == 31 { figs = false; continue }
            let c = (figs ? figures : letters)[code]
            if c == " " { figs = false }
            if c != "\0" { out.append(c) }
        }
        return out
    }

    /// G3PLX Varicode for ASCII 0…127 (`Varicode` in Modems).
    static let varicodeTable = [
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
    static let varicodeByCode = Dictionary(uniqueKeysWithValues: varicodeTable.enumerated().map { ($1, $0) })

    /// `bits` random bits split at "00" into Varicode characters, as a PSK31 decoder fed noise prints them.
    static func varicode(bits: Int, _ random: inout SynthRandom) -> String {
        var out = "", code = "", zeros = 0
        for _ in 0..<bits {
            let one = random.next() & 1 == 1
            if one {
                if zeros >= 2, let ascii = varicodeByCode[code] { out.unicodeScalars.append(Unicode.Scalar(UInt8(ascii))) }
                if zeros >= 2 { code = "" }
                code += String(repeating: "0", count: zeros < 2 ? zeros : 0) + "1"
                zeros = 0
            } else {
                zeros += 1
            }
        }
        return out
    }
}
