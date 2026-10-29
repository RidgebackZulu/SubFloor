import Foundation

/// Reads and writes the transcript sidecars: one JSON file per transcribed recording, in
/// `<recordings folder>/.subfloor/transcripts/`, beside the folder's peaks cache. A sidecar holds the
/// model's replies and never the API key; recordings themselves are never touched.
public enum TranscriptStore {
    /// `<folder>/.subfloor/transcripts`.
    public static func directory(in recordingsFolder: URL) -> URL {
        recordingsFolder.appending(path: ".subfloor", directoryHint: .isDirectory)
            .appending(path: "transcripts", directoryHint: .isDirectory)
    }

    /// `<folder>/.subfloor/transcripts/<file>.json`, where `file` is the recording's file name.
    public static func url(for file: String, in recordingsFolder: URL) -> URL {
        directory(in: recordingsFolder).appending(path: file + ".json", directoryHint: .notDirectory)
    }

    /// Saves `t`, creating the directory if needed. The write is atomic, so a crash leaves either the
    /// old sidecar or the new one, never half of one. Pretty-printed with sorted keys to keep diffs readable.
    public static func write(_ t: StoredTranscript, in recordingsFolder: URL) throws {
        try FileManager.default.createDirectory(at: directory(in: recordingsFolder), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(t).write(to: url(for: t.file, in: recordingsFolder), options: .atomic)
    }

    /// Every readable sidecar in the folder, keyed by the recording file name it records. A missing
    /// directory gives an empty result; a file that is not valid JSON of the right shape is skipped.
    public static func readAll(in recordingsFolder: URL) -> [String: StoredTranscript] {
        let dir = directory(in: recordingsFolder)
        guard let urls = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var out: [String: StoredTranscript] = [:]
        for url in urls where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url), let t = try? decoder.decode(StoredTranscript.self, from: data) else { continue }
            out[t.file] = t
        }
        return out
    }
}
