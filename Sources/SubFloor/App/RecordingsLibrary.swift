import AVFoundation
import Foundation
import Observation
import Recording

/// The recordings the Recordings window shows, and the one owner of what it has heard. It merges the folder
/// listing, every day log and the recording in progress into a `RecordingsCatalog`, and keeps that current
/// from what `AppModel` itself writes, so a recording that ends shows up without rereading the logs.
///
/// Folder listings, log reads and file-length reads run off the main actor (a recordings folder can hold
/// months of logs and thousands of files); their results are applied back here. The window never edits,
/// moves or deletes a recording and never edits a log line. The only thing the library writes is a `heard`
/// entry, through `RecordingLog.append`, as the log's append-only format intends.
@MainActor @Observable
final class RecordingsLibrary {
    private(set) var folder: URL
    private(set) var catalog: RecordingsCatalog

    /// Recordings the listener has not opened. A recording in progress is never counted.
    var unheardCount: Int { catalog.unheardCount }

    /// Called with a message when the log cannot be read or written; once per failure, not once per attempt.
    @ObservationIgnored var onError: ((String) -> Void)?
    /// Called after every change to `catalog`, so the player can reconcile what it holds with what exists.
    @ObservationIgnored var onChange: (() -> Void)?

    /// What the catalog is rebuilt from when the logs are read again, since the catalog does not expose them.
    @ObservationIgnored private var live: LiveRecording?
    @ObservationIgnored private var measured: [String: Double] = [:]
    /// Counts changes to the sources (the log lines applied here, the listing). A read that started before
    /// one has missed it, so it reads again rather than apply a catalog that is already out of date.
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var readFailed = false
    @ObservationIgnored private var writeFailed = false

    init(folder: URL) {
        self.folder = folder
        catalog = RecordingsCatalog()
    }

    func url(for file: String) -> URL { folder.appendingPathComponent(file) }

    /// Another recordings folder: nothing of the old one stays, and the new one is read in the background.
    /// A read of the old folder that is still running is discarded when it finishes.
    func setFolder(_ folder: URL) {
        guard folder != self.folder else { return }
        self.folder = folder
        revision += 1
        live = nil
        measured = [:]
        readFailed = false
        writeFailed = false
        catalog = RecordingsCatalog()
        changed()
        Task { await reload() }
    }

    /// Reads the folder listing and every day log, off the main actor, into a fresh catalog. Never applies
    /// the logs into the existing catalog: a pop applied twice is listed twice.
    func reload() async {
        let folder = self.folder
        while true {
            let seen = revision
            let (files, entries, failure) = await Task.detached(priority: .userInitiated) { Self.read(folder) }.value
            guard folder == self.folder else { return }   // setFolder came in while reading
            guard seen == revision else { continue }      // a line was logged meanwhile: read again
            if let failure {
                // One unreadable day file fails them all. The files are still listed, and with no log they
                // all read as heard and manual, which loses nothing.
                if !readFailed { onError?("Could not read the recordings log: \(failure)") }
                readFailed = true
            } else {
                readFailed = false
            }
            var fresh = RecordingsCatalog(files: files, entries: entries, live: live)
            for (file, seconds) in measured { fresh.setMeasuredSeconds(seconds, for: file) }
            catalog = fresh
            changed()
            return
        }
    }

    /// Reads the folder listing only: a file deleted in Finder, or a new recording the listing lacked.
    func refreshFiles() async {
        let folder = self.folder
        let files = await Task.detached(priority: .userInitiated) { Self.listing(of: folder) }.value
        guard folder == self.folder else { return }
        revision += 1   // a log read that started before this has an older listing
        catalog.setFiles(files)
        changed()
    }

    /// `AppModel`'s own writes, applied without rereading. Only for lines that were appended: the library
    /// sees exactly what is on disk.
    func didLog(_ entries: [RecordingLogEntry]) {
        guard !entries.isEmpty else { return }
        revision += 1
        catalog.apply(entries)
        changed()
        // A recording that has just been logged may be a file the listing has not seen yet.
        let unlisted = entries.contains { entry in
            switch entry {
            case .recording(let file, _, _, _, _, _), .autoStarted(let file, _, _, _): !catalog.files.contains(file)
            default: false
            }
        }
        if unlisted { Task { await refreshFiles() } }
    }

    /// The recording being written, or nil when none is.
    func setLive(_ live: LiveRecording?) {
        guard live != self.live else { return }
        self.live = live
        catalog.setLive(live)
        changed()
    }

    /// The listener opened `file`: one `heard` line. Nothing is written for a recording that is already heard,
    /// one in progress, or one the catalog does not list. If the write fails the recording stays unheard,
    /// so what the window shows is what the log says.
    func markHeard(_ file: String) {
        guard let recording = catalog.recording(file), !recording.heard, !recording.inProgress else { return }
        append([.heard(file: file, at: Date())])
    }

    /// Marks every unheard recording heard, in one append.
    func clear() {
        append(catalog.unheardFiles.map { .heard(file: $0, at: Date()) })
    }

    /// Reads the length of the day's recordings that have none (no log entry: a file from before the log, or
    /// an auto recording cut short), off the main actor. A file that cannot be opened stays without one.
    func measureMissingLengths(onUTCDay day: Date) async {
        let folder = self.folder
        let missing = catalog.recordings(onUTCDay: day).filter { $0.seconds == nil && !$0.inProgress }.map(\.file)
        guard !missing.isEmpty else { return }
        let lengths = await Task.detached(priority: .utility) { Self.lengths(of: missing, in: folder) }.value
        guard folder == self.folder else { return }
        var any = false
        for (file, seconds) in lengths where catalog.recording(file)?.seconds == nil {
            measured[file] = seconds
            catalog.setMeasuredSeconds(seconds, for: file)
            any = true
        }
        if any { changed() }
    }

    // MARK: Private

    /// Appends to the day logs and applies the lines. A failed write shows one error until a write succeeds.
    private func append(_ entries: [RecordingLogEntry]) {
        guard !entries.isEmpty else { return }
        do {
            try RecordingLog(folder: folder).append(entries)
        } catch {
            if !writeFailed { onError?("Could not write the recordings log: \(error.localizedDescription)") }
            writeFailed = true
            return
        }
        writeFailed = false
        didLog(entries)
    }

    private func changed() { onChange?() }

    /// The names in the folder (no file attributes: the catalog needs only names); none for a folder that
    /// does not exist yet.
    nonisolated private static func listing(of folder: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    }

    nonisolated private static func read(_ folder: URL) -> (files: [String], entries: [RecordingLogEntry], failure: String?) {
        let files = listing(of: folder)
        do {
            return (files, try RecordingLog(folder: folder).allEntries(), nil)
        } catch {
            return (files, [], error.localizedDescription)
        }
    }

    nonisolated private static func lengths(of files: [String], in folder: URL) -> [String: Double] {
        var lengths: [String: Double] = [:]
        for file in files {
            guard let audio = try? AVAudioFile(forReading: folder.appendingPathComponent(file)),
                  audio.processingFormat.sampleRate > 0 else { continue }
            lengths[file] = Double(audio.length) / audio.processingFormat.sampleRate
        }
        return lengths
    }
}
