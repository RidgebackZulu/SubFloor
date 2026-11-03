import Foundation

/// How much a decoder's output reads as words rather than noise: the evidence a trial decode of RTTY or PSK31 gives
/// (`SignalIdentifier.identify(_:rfHz:readableDecode:)`). A decoder fed noise, random bits or a cypher still prints
/// characters; what it prints doesn't read.
///
/// The text is split into words (runs of letters and digits); each counts its characters when it is
///  - a word of the built-in list (`words`: common English, amateur abbreviations and Q-codes, weather and shipping
///    terms), or "A" or "I": no other single letter counts, since noise through Varicode is mostly its shortest codes,
///    the commonest letters;
///  - a callsign (`K1ABC`, `G4XYZ`, `2E0ABC`) or a Maidenhead locator (`FN42`, `IO91wm`);
///  - a number of up to four digits, with or without a unit (`599`, `1200Z`, `25KT`): `numberWeight` of it, as a number
///    in a run of noise is common. Five-figure groups (a cypher's) don't count.
///
/// A word whose case changes inside it (`iIan`, `poV`) never counts: text is in one case, or capitalised. The score is
/// the share of the text's characters (its words' and its stray symbols', not spaces or ordinary punctuation) that
/// count, scaled down while fewer than `minimumCharacters` count: a word or two in a burst of noise is no proof.
public enum ReadableText {
    /// Text scoring this or more reads: evidence for the mode that printed it. Numbers alone stay under it
    /// (`numberWeight`).
    public static let readableScore: Float = 0.5
    /// The counted characters at which the score stops being scaled down.
    public static let minimumCharacters = 12
    /// A number counts this share of its characters: under `readableScore`, so numbers alone never read.
    static let numberWeight = 0.4

    /// 0…1: how much of `text` reads as words, not noise.
    public static func score(_ text: String) -> Float {
        var counted = 0.0, total = 0.0
        var word = ""
        func close() {
            guard !word.isEmpty else { return }
            total += Double(word.count)
            counted += weight(word) * Double(word.count)
            word = ""
        }
        for scalar in text.unicodeScalars {
            if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) {
                word.unicodeScalars.append(scalar)
                continue
            }
            close()
            // Spaces and ordinary punctuation are neutral; any other symbol or control character is noise.
            if !CharacterSet.whitespacesAndNewlines.contains(scalar) && !neutral.contains(scalar) { total += 1 }
        }
        close()
        guard total > 0 else { return 0 }
        let share = counted / total
        return Float(share * min(1, counted / Double(minimumCharacters)))
    }

    /// `text` as a decode's text is kept: control, format, surrogate, private-use and unassigned scalars out, whitespace
    /// (line breaks and tabs too) as single spaces, trimmed, at most `maxScalars` scalars. A decode's text is scored as
    /// kept.
    public static func cleaned(_ text: String, maxScalars: Int) -> String {
        var out = String.UnicodeScalarView()
        var space = false
        for scalar in text.unicodeScalars {
            let category = scalar.properties.generalCategory
            if scalar.properties.isWhitespace || category == .lineSeparator || category == .paragraphSeparator {
                space = !out.isEmpty
                continue
            }
            guard category != .control, category != .format, category != .surrogate, category != .privateUse,
                  category != .unassigned else { continue }
            if space {
                guard out.count + 2 <= maxScalars else { break }   // never a space last
                out.append(" ")
            }
            space = false
            guard out.count < maxScalars else { break }
            out.append(scalar)
        }
        return String(out)
    }

    /// Punctuation ordinary text has, which neither counts for nor against it.
    static let neutral = CharacterSet(charactersIn: ".,?!'-/:;()\"=+")

    /// 1 for a word that reads, `numberWeight` for a short number, 0 otherwise.
    static func weight(_ word: String) -> Double {
        let lower = word.lowercased(), upper = word.uppercased()
        let letters = word.filter(\.isLetter)
        // One case, or capitalised: never a case change inside the word.
        let capitalised = word.first.map { String($0).uppercased() + word.dropFirst().lowercased() } == word
        guard letters.isEmpty || word == upper || word == lower || capitalised else { return 0 }
        if word.count == 1 { return upper == "A" || upper == "I" ? 1 : 0 }
        if words.contains(upper) || isCallsign(upper) || isLocator(upper) { return 1 }
        if isNumber(upper) { return numberWeight }
        return 0
    }

    /// One or two letters (or a digit and a letter, or a letter and a digit), a digit, and one to four letters.
    static func isCallsign(_ w: String) -> Bool {
        let c = Array(w)
        guard (4...7).contains(c.count), let digit = c.lastIndex(where: \.isNumber), digit >= 1, digit <= 2 else { return false }
        let prefix = c[..<digit], suffix = c[(digit + 1)...]
        guard (1...4).contains(suffix.count), suffix.allSatisfy(\.isLetter) else { return false }
        switch prefix.count {
        case 1: return prefix[0].isLetter
        default: return prefix.contains(where: \.isLetter)
        }
    }

    /// Field (two letters A–R), square (two digits), and optionally subsquare (two letters A–X).
    static func isLocator(_ w: String) -> Bool {
        let c = Array(w)
        guard c.count == 4 || c.count == 6 else { return false }
        func field(_ x: Character) -> Bool { ("A"..."R").contains(x) }
        func sub(_ x: Character) -> Bool { ("A"..."X").contains(x) }
        return field(c[0]) && field(c[1]) && c[2].isNumber && c[3].isNumber && (c.count == 4 || (sub(c[4]) && sub(c[5])))
    }

    /// Up to four digits, then nothing or a unit.
    static func isNumber(_ w: String) -> Bool {
        let digits = w.prefix { $0.isNumber }
        guard (1...4).contains(digits.count) else { return false }
        let unit = w.dropFirst(digits.count)
        return unit.isEmpty || units.contains(String(unit))
    }

    static let units: Set<String> = ["Z", "KT", "KTS", "M", "MB", "HPA", "UTC", "W", "DB", "NM", "FT", "C", "F", "KHZ",
                                     "MHZ", "HZ", "H", "S", "MIN"]

    /// The words that read (upper case).
    static let words: Set<String> = Set("""
        CQ DE KN SK AR BK TU TNX TKS FB OM YL XYL UR RST NAME QTH QSL QSO QRZ QRM QRN QSB QRP QRT QRV QSY QRX QTC QTR
        HW CPY COPY PSE ES ANT RIG WX HR HERE AGN ABT 73 88 599 5NN TEST CONTEST DX GL GE GM GA GN BTU FER VY SRI CUL
        BCNU OP RPT INFO
        THE AND OF TO IN IS IT FOR ON WITH AS AT BY FROM THIS THAT BE ARE WAS WERE WILL BEEN HAS HAVE HAD NOT NO BUT
        OR IF AN ME MY WE OUR YOU YOUR HE SHE THEY THEM HIS HER ITS SO DO CAN MAY UP OUT OVER UNDER INTO THAN THEN
        THERE WHERE WHEN WHAT WHO HOW WHY ALL ANY SOME MORE MOST LESS VERY ALSO ONLY JUST NOW NEW GOOD WELL THANKS
        THANK HELLO HI CALL CALLING DEAR NICE MEET HOPE BEST REGARDS SEE AGAIN SOON TODAY TONIGHT TOMORROW TIME DAY
        NIGHT WEEK MORNING EVENING AFTERNOON POWER WATTS WATT ANTENNA RADIO STATION SIGNAL SIGNALS BAND FREQUENCY
        RECEIVE RECEIVED SEND SENDING MESSAGE MESSAGES NUMBER END OK YES
        WEATHER FORECAST WIND WINDS SEA SEAS SWELL WAVE WAVES VISIBILITY VIS MODERATE POOR FAIR RAIN SHOWERS SHOWER
        FOG MIST SNOW HAIL THUNDER STORM STORMS GALE GALES WARNING WARNINGS STRONG LIGHT VARIABLE BECOMING LATER
        ISSUED VALID UNTIL AREA AREAS NORTH SOUTH EAST WEST NORTHERN SOUTHERN EASTERN WESTERN NORTHEAST NORTHWEST
        SOUTHEAST SOUTHWEST NE NW SE SW NNE ENE ESE SSE SSW WSW WNW NNW KNOTS KT KTS METRES METERS FEET HIGH LOW
        PRESSURE MOVING EXPECTED FALLING RISING SLOWLY QUICKLY OCCASIONALLY OCCASIONAL ROUGH SLIGHT CALM SMOOTH HEAVY
        ISOLATED SCATTERED CLOUD CLOUDY CLEAR TEMPERATURE SYNOPSIS OUTLOOK SHIPPING COASTAL WATERS BAY CHANNEL GULF
        OCEAN SECURITE PAN MAYDAY NAVTEX NAVAREA MB HPA UTC GMT
        """.split(whereSeparator: \.isWhitespace).map(String.init))
}
