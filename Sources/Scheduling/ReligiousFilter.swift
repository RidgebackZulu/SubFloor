import Foundation

/// The religious-station rule, read from `Resources/religious.json`. No religious broadcast is ever scheduled
/// or shown. Matching is case- and diacritic-insensitive.
public struct ReligiousFilter: Sendable, Decodable {
    /// Matched anywhere in a station's name.
    public var denylist: [String]
    /// Matched at the start of any word in a station's name ("Christ" matches "Christian").
    public var keywords: [String]
    /// A name containing any of these is not religious by a keyword alone ("Sound of Hope"); a denylist entry still
    /// catches it ("WBCQ World's Last Chance").
    public var allowlist: [String]

    public init(denylist: [String], keywords: [String], allowlist: [String]) {
        self.denylist = denylist
        self.keywords = keywords
        self.allowlist = allowlist
    }

    /// From `Resources/religious.json`. A missing or unreadable file is a programmer error (precondition).
    public static let bundled: ReligiousFilter = {
        guard let url = Bundle.module.url(forResource: "religious", withExtension: "json", subdirectory: "Resources"),
              let data = try? Data(contentsOf: url),
              let filter = try? JSONDecoder().decode(ReligiousFilter.self, from: data)
        else { preconditionFailure("religious.json is missing or unreadable") }
        return filter
    }()

    /// True when `station` is religious. A denylist entry matches as a substring, and is checked first. A keyword
    /// matches the start of a word ("Christ" matches "Christian"), unless the name contains an allowlist entry (which
    /// only cancels keyword hits). Matching is case- and diacritic-insensitive.
    public func isReligious(_ station: String) -> Bool {
        let name = Self.fold(station)
        if denylist.contains(where: { name.contains(Self.fold($0)) }) { return true }
        if allowlist.contains(where: { name.contains(Self.fold($0)) }) { return false }
        let words = name.split { !($0.isLetter || $0.isNumber) }
        let stems = keywords.map(Self.fold)
        return words.contains { word in stems.contains { word.hasPrefix($0) } }
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
