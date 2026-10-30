import Foundation
import Recording
import Transcription

/// The Recordings header's search, as a value: which recordings a query leaves lit, which it fades and how
/// ◀ ▶ walk the matches across days. A blank query (empty, spaces, only punctuation) is no filter at all.
struct RecordingsSearch: Equatable {
    /// The query's words, normalized (`TranscriptSearch.terms`): empty when the query is blank.
    let terms: [String]

    init(query: String) { terms = TranscriptSearch.terms(query) }

    /// False for a blank query: nothing fades and nothing is counted.
    var isActive: Bool { !terms.isEmpty }

    /// The recordings, on any day, whose transcript holds every term, by start time. A recording in progress
    /// has no transcript yet and one never transcribed has none at all: neither matches.
    func matches(catalog: RecordingsCatalog, index: TranscriptIndex) -> [CatalogRecording] {
        guard isActive else { return [] }
        return catalog.allRecordings.filter { !$0.inProgress && index.matches($0.file, terms: terms) }
    }

    /// The files of `recordings` the search fades: everything that is not a match, untranscribed and in-progress
    /// ones included. Empty when the search is not active, so a blank field restores everything.
    ///
    /// `keeping` is never faded: the recording the listener picked stays in view even when it does not match
    /// (its selected glow is drawn at full strength, so dimming it would only half work).
    func dimmed(_ recordings: [CatalogRecording], index: TranscriptIndex, keeping selected: String? = nil) -> Set<String> {
        guard isActive else { return [] }
        var faded = Set(recordings.filter { $0.inProgress || !index.matches($0.file, terms: terms) }.map(\.file))
        if let selected { faded.remove(selected) }
        return faded
    }

    /// The next (or previous) match after `current`, wrapping around; nil when there are no matches. When
    /// `current` is one of `matches` the step is from its place in the list; when it is not (or is nil) the
    /// step is from its time: forward takes the first match after it, backward the last before it, and
    /// nothing at all takes the first or the last.
    static func step(_ matches: [CatalogRecording], from current: CatalogRecording?, forward: Bool) -> CatalogRecording? {
        guard !matches.isEmpty else { return nil }
        guard let current else { return forward ? matches.first : matches.last }
        if let i = matches.firstIndex(where: { $0.file == current.file }) {
            let j = i + (forward ? 1 : -1)
            return matches[(j + matches.count) % matches.count]
        }
        let key = (current.start, current.file)
        if forward { return matches.first { ($0.start, $0.file) > key } ?? matches.first }
        return matches.last { ($0.start, $0.file) < key } ?? matches.last
    }

    /// Where a step starts: the selected recording when it is a match, otherwise the shown day's edge, so
    /// → goes to the first match from that day on and ← to the last before it.
    static func stepOrigin(_ matches: [CatalogRecording], selected: String?, dayStart: Date, forward: Bool) -> CatalogRecording? {
        if let selected, let current = matches.first(where: { $0.file == selected }) { return current }
        if forward { return matches.last { $0.start < dayStart } }
        return matches.first { $0.start >= dayStart }
    }

    /// "1 match", "2 matches", "0 matches".
    static func countText(_ count: Int) -> String { count == 1 ? "1 match" : "\(count) matches" }
}
