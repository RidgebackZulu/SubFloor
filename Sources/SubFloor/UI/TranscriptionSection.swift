import AppKit
import Foundation
import SwiftUI
import Transcription

/// How the Transcription settings and the Recordings header chip word things.
enum TranscriptionFormat {
    /// The "Transcribe older recordings" button's text: how many recordings and, when the model's price is
    /// known, what they would cost; or that there is nothing left to do.
    static func olderButton(count: Int, dollars: Double?) -> String {
        guard count > 0 else { return "All recordings transcribed" }
        let noun = count == 1 ? "recording" : "recordings"
        guard let dollars else { return "Transcribe \(count) \(noun)" }
        return "Transcribe \(count) \(noun) (≈ $\(String(format: "%.2f", dollars)))"
    }

    /// Whether a key is saved. Never the key itself.
    static func keyStatus(hasKey: Bool) -> String { hasKey ? "Key saved ✓" : "No key" }
}

/// Settings → Transcription: the on/off switch, the OpenRouter key, the model and language, and the button
/// that sends the recordings made before transcription was on.
///
/// The key is typed into a field that is empty every time and cleared after Save; the stored key is never
/// shown, only "Key saved ✓" or "No key". Errors under the key row never include the key or file contents.
struct TranscriptionSection: View {
    @Environment(AppModel.self) private var model
    /// The key being typed. Local only, and cleared after Save.
    @State private var keyText = ""
    @State private var keyError: String?
    @State private var modelText = ""

    var body: some View {
        @Bindable var model = model
        Section("Transcription") {
            Toggle("Transcribe recordings", isOn: $model.transcriptionSettings.enabled)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    SecureField("OpenRouter API key", text: $keyText)
                        .onSubmit(save)
                    Button("Save", action: save)
                        .disabled(keyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Remove") { run { try model.removeAPIKey() } }
                        .disabled(!model.hasAPIKey)
                    Button("Import from .env…", action: importFromEnv)
                }
                Text(TranscriptionFormat.keyStatus(hasKey: model.hasAPIKey))
                    .font(.caption).foregroundStyle(.secondary)
                if let keyError {
                    Text(keyError).font(.caption).foregroundStyle(.red)
                }
                if let blocked = model.transcription.blocked {
                    Text(blocked.message).font(.caption).foregroundStyle(.red)
                }
            }
            TextField("Model", text: $modelText)
                .onSubmit(commitModel)
            Picker("Language", selection: $model.transcriptionSettings.language) {
                Text("English").tag(String?.some("en"))
                Text("Auto-detect").tag(String?.none)
            }
            Text("Recordings are sent to OpenRouter and the model's provider for transcription.")
                .font(.caption).foregroundStyle(.secondary)
            olderRow
        }
        .onAppear { modelText = model.transcriptionSettings.model }
    }

    @ViewBuilder private var olderRow: some View {
        if let progress = model.transcription.backlogProgress {
            HStack {
                Text("Transcribing \(progress.done) of \(progress.total)").monospacedDigit()
                Spacer()
                Button("Stop") { model.transcription.stopBacklog() }
            }
        } else {
            let estimate = model.olderRecordingsEstimate
            Button(TranscriptionFormat.olderButton(count: estimate.count, dollars: estimate.dollars)) {
                model.transcribeOlderRecordings()
            }
            .disabled(estimate.count == 0 || !model.hasAPIKey || !model.transcriptionSettings.enabled)
        }
    }

    private func save() {
        let text = keyText
        run { try model.saveAPIKey(text) }
        if keyError == nil { keyText = "" }
    }

    /// An empty model name goes back to the default.
    private func commitModel() {
        let trimmed = modelText.trimmingCharacters(in: .whitespacesAndNewlines)
        let chosen = trimmed.isEmpty ? OpenRouterTranscriber.defaultModel : trimmed
        modelText = chosen
        model.transcriptionSettings.model = chosen
    }

    private func importFromEnv() {
        let panel = NSOpenPanel()
        panel.message = "Choose a .env file with an OPENROUTER key"
        panel.showsHiddenFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        run { try model.importAPIKey(fromEnvFileAt: url) }
    }

    /// Runs a key change and shows its failure as one line. The messages are fixed text: never the key, the
    /// file's contents or the system's description of the error.
    private func run(_ change: () throws -> Void) {
        do {
            try change()
            keyError = nil
        } catch let error as APIKeyImportError where error == .noKey {
            keyError = "No OPENROUTER key in that file"
        } catch let error as KeychainError {
            keyError = "Couldn't update the Keychain (error \(error.status))"
        } catch {
            keyError = "Couldn't read that file"
        }
    }
}

/// The Recordings header's Transcribe chip, in the Skip silence chip's style: green when on, with the key
/// status or the reason the queue is blocked as its tooltip.
struct TranscribeChip: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let isOn = model.transcriptionSettings.enabled
        let help = model.transcription.blocked?.message ?? TranscriptionFormat.keyStatus(hasKey: model.hasAPIKey)
        Button { model.toggleTranscription() } label: {
            Label("Transcribe", systemImage: "text.bubble")
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .foregroundStyle(isOn ? Color.black : Color.secondary)
        .background { RoundedRectangle(cornerRadius: 5).fill(isOn ? Color.green : Color.white.opacity(0.06)) }
        .overlay { RoundedRectangle(cornerRadius: 5).stroke(isOn ? Color.green : Color.white.opacity(0.15)) }
        .opacity(isOn ? 1 : 0.6)
        .help(help)
        .accessibilityLabel("Transcribe")
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityHint(help)
        .accessibilityAddTraits(.isToggle)
    }
}
