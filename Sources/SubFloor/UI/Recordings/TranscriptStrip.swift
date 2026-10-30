import AppKit
import SwiftUI
import Transcription

/// What the timeline's badge says about a recording's transcript.
enum TranscriptMark: Equatable {
    /// Real words were heard: a green dot.
    case voice
    /// Nothing usable came back: a grey ring.
    case possibleNoise
    /// Given up on, with the reason: an orange dot.
    case failed(String)
}

enum TranscriptMarks {
    /// The badge for every recording that has one: its transcript's verdict, or the reason it failed. A
    /// failure only marks a recording with no transcript (an old transcript stays while it is redone), and
    /// a queued or running one has no mark.
    @MainActor static func marks(index: TranscriptIndex, states: [String: TranscriptionJobState]) -> [String: TranscriptMark] {
        var marks: [String: TranscriptMark] = [:]
        for file in index.files {
            guard let summary = index.summary(file) else { continue }
            marks[file] = summary.verdict == .voice ? .voice : .possibleNoise
        }
        for (file, state) in states {
            if case .failed(let reason) = state, marks[file] == nil { marks[file] = .failed(reason) }
        }
        return marks
    }
}

/// A word the strip draws: which of the transcript's words, where its left edge goes, and on which of the two
/// lines.
struct PlacedWord: Equatable {
    var index: Int
    var x: CGFloat
    var line: Int
}

/// Where each word goes: under the signal it was spoken in, on one of two lines.
enum TranscriptStripLayout {
    /// The room kept between two words on a line.
    static let gap: CGFloat = 6

    /// The words that start inside `visible`, at their time across `width`. A word that would run into the
    /// last one on line 0 goes to line 1; one that would run into both is left out, so text never overlaps.
    /// Zooming in spreads the words apart and brings the hidden ones back.
    static func place(_ words: [TranscriptWord], visible: ClosedRange<Double>, width: CGFloat,
                      measure: (String) -> CGFloat) -> [PlacedWord] {
        let span = visible.upperBound - visible.lowerBound
        guard span > 0, width > 0 else { return [] }
        var ends: [CGFloat] = [-.infinity, -.infinity]
        var placed: [PlacedWord] = []
        for (index, word) in words.enumerated() where visible.contains(word.start) {
            let x = CGFloat((word.start - visible.lowerBound) / span) * width
            guard let line = ends.firstIndex(where: { x >= $0 }) else { continue }
            ends[line] = x + measure(word.text) + gap
            placed.append(PlacedWord(index: index, x: x, line: line))
        }
        return placed
    }
}

/// What the strip shows for the selected recording.
enum TranscriptStripContent: Equatable {
    case words([TranscriptWord], text: String)
    case noise
    case failed(String)
    case transcribing
    case notTranscribed

    /// A recording being sent right now says so even when it has an old transcript (Transcribe Again);
    /// otherwise a transcript wins over a queued retry, and a failure shows only for a recording with none.
    static func decide(summary: TranscriptSummary?, state: TranscriptionJobState?) -> Self {
        if state == .running { return .transcribing }
        // The verdict, as the badge has it: a transcript with under 3 kept words is possible noise, whatever
        // words it holds (they stay in the index for search).
        if let summary { return summary.verdict == .possibleNoise ? .noise : .words(summary.words, text: summary.text) }
        switch state {
        case .failed(let reason)?: return .failed(reason)
        case .queued?, .running?: return .transcribing
        case nil: return .notTranscribed
        }
    }

    /// The line that stands where there are no words, or nil for the words.
    var message: String? {
        switch self {
        case .words: nil
        case .noise: "Possible noise — no clear speech"
        case .failed(let reason): "Couldn't transcribe — \(reason)"
        case .transcribing: "Transcribing…"
        case .notTranscribed: "Not transcribed"
        }
    }
}

/// The selected recording's transcript under its waveform: each word at the time it was spoken, across
/// exactly the span the waveform shows. The word being spoken is bright, the rest dim, words that match the
/// search are lit green, and a click on a word plays from it. Where there are no words it says why, and for
/// a recording that was never transcribed offers to do it.
///
/// Everything comes in as values; `PlayerPanel` feeds it from the model and the player.
struct TranscriptStrip: View {
    static let fontSize: CGFloat = 11
    static let lineHeight: CGFloat = 14
    /// Two lines of text.
    static let height: CGFloat = lineHeight * 2 + 2

    let content: TranscriptStripContent
    /// Seconds into the file, and its length: what the waveform is drawn from.
    let position: Double
    let duration: Double
    let zoom: WaveformZoom
    /// The playhead when a waveform drag began, which holds the range still; nil otherwise.
    var dragAnchor: Double?
    /// The search's normalized terms; empty lights nothing.
    let terms: [String]
    /// Whether "Transcribe" can do anything, and if not, why.
    let canTranscribe: Bool
    let cannotTranscribeReason: String
    let onSeek: (Double) -> Void
    let onTranscribe: () -> Void

    @State private var width: CGFloat = 0

    /// True for the word being spoken at `position`.
    nonisolated static func isCurrent(_ word: TranscriptWord, position: Double) -> Bool {
        word.start <= position && position < word.end
    }

    var body: some View {
        Group {
            switch content {
            case .words(let words, let text):
                wordsView(words)
                    .help(text)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Transcript")
                    .accessibilityValue(text)
            case .notTranscribed:
                HStack(spacing: 10) {
                    note("Not transcribed")
                    Button("Transcribe", action: onTranscribe)
                        .buttonStyle(ChipButtonStyle())
                        .disabled(!canTranscribe)
                        .help(canTranscribe ? "Transcribe this recording" : cannotTranscribeReason)
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Transcript")
            default:
                note(content.message ?? "")
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Transcript")
                    .accessibilityValue(content.message ?? "")
            }
        }
        .frame(maxWidth: .infinity, minHeight: Self.height, maxHeight: Self.height, alignment: .topLeading)
        .clipped()
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: Self.fontSize))
            .foregroundStyle(RecordingsTheme.muted)
            .frame(height: Self.lineHeight, alignment: .leading)
    }

    private func wordsView(_ words: [TranscriptWord]) -> some View {
        // The waveform's own span: its width is the view's, and it draws from the left edge.
        let range = zoom.shownRange(duration: duration, position: position, anchor: dragAnchor)
        let placed = TranscriptStripLayout.place(words, visible: range, width: width, measure: Self.measure)
        return ZStack(alignment: .topLeading) {
            ForEach(placed, id: \.index) { p in
                let word = words[p.index]
                Text(word.text)
                    .font(.system(size: Self.fontSize))
                    .foregroundStyle(Self.isCurrent(word, position: position) ? HierarchicalShapeStyle.primary : .secondary)
                    .lineLimit(1)
                    .fixedSize()
                    .background {
                        if TranscriptSearch.wordMatches(word.text, terms: terms) {
                            RoundedRectangle(cornerRadius: 3).fill(Color(red: 0x4d / 255, green: 0xdb / 255, blue: 0x78 / 255).opacity(0.35))
                                .padding(.horizontal, -2)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { onSeek(word.start) }
                    .offset(x: p.x, y: CGFloat(p.line) * (Self.lineHeight + 2))
            }
        }
    }

    /// A word's width in the font it is drawn in. Words repeat, so the widths are remembered.
    @MainActor private static var widths: [String: CGFloat] = [:]
    @MainActor private static func measure(_ text: String) -> CGFloat {
        if let w = widths[text] { return w }
        let w = ceil((text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: fontSize)]).width)
        if widths.count > 4000 { widths.removeAll() }
        widths[text] = w
        return w
    }
}
