import Foundation
import Transcription

/// Speech-transcript settings, saved with the session. The OpenRouter key is not part of it.
struct TranscriptionSettings: Codable, Equatable, Sendable {
    var enabled = true
    var model = OpenRouterTranscriber.defaultModel
    /// A language code for the model, or nil to let it detect the language.
    var language: String? = "en"
    /// When transcription was last turned on (or first launched). Relaunch queues only recordings that
    /// started at or after it, so recordings from before transcription was wanted are left alone.
    var enabledSince: Date?
}
