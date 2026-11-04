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
    /// Translate transcripts of other languages into English, for any recording sent with auto-detect.
    var translate = true
    /// The OpenRouter chat model that translates.
    var translationModel = OpenRouterTranslator.defaultModel
}

extension TranscriptionSettings {
    /// Settings saved before translation existed have no `translate` or `translationModel`: they take the
    /// defaults. Kept in an extension so the memberwise initializer stays.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? enabled
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? model
        language = try c.decodeIfPresent(String.self, forKey: .language)
        enabledSince = try c.decodeIfPresent(Date.self, forKey: .enabledSince)
        translate = try c.decodeIfPresent(Bool.self, forKey: .translate) ?? translate
        translationModel = try c.decodeIfPresent(String.self, forKey: .translationModel) ?? translationModel
    }
}
