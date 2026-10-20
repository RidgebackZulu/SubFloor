public enum MorseCode {
    public struct Element: Equatable, Sendable {
        public let on: Bool
        public let units: Int
    }

    public static let table: [Character: String] = [
        "A": ".-", "B": "-...", "C": "-.-.", "D": "-..", "E": ".", "F": "..-.", "G": "--.", "H": "....",
        "I": "..", "J": ".---", "K": "-.-", "L": ".-..", "M": "--", "N": "-.", "O": "---", "P": ".--.",
        "Q": "--.-", "R": ".-.", "S": "...", "T": "-", "U": "..-", "V": "...-", "W": ".--", "X": "-..-",
        "Y": "-.--", "Z": "--..",
        "0": "-----", "1": ".----", "2": "..---", "3": "...--", "4": "....-", "5": ".....",
        "6": "-....", "7": "--...", "8": "---..", "9": "----.",
        ".": ".-.-.-", ",": "--..--", "?": "..--..", "/": "-..-.", "=": "-...-", "+": ".-.-.", "-": "-....-",
    ]

    public static let reverse: [String: Character] = Dictionary(uniqueKeysWithValues: table.map { ($1, $0) })

    /// PARIS-timed key timeline: dit 1, dah 3, element gap 1, character gap 3, word gap 7.
    public static func timeline(for text: String) -> [Element] {
        var out: [Element] = []
        for (wi, word) in text.uppercased().split(separator: " ").enumerated() {
            if wi > 0 { out.append(Element(on: false, units: 7)) }
            for (ci, ch) in word.enumerated() {
                guard let code = table[ch] else { continue }
                if ci > 0 { out.append(Element(on: false, units: 3)) }
                for (ei, e) in code.enumerated() {
                    if ei > 0 { out.append(Element(on: false, units: 1)) }
                    out.append(Element(on: true, units: e == "." ? 1 : 3))
                }
            }
        }
        return out
    }

    public static func dotSeconds(wpm: Double) -> Double { 1.2 / wpm }
}
