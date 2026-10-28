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
    /// How long the recording in progress has run, apart from `catalog`, which holds the recording as it
    /// began. It grows at every 5 Hz poll; kept here, it redraws the live marker and nothing else (not the
    /// window's day, not the unheard badge). nil when none is recording.
    private(set) var liveSeconds: Double?

    /// Recordings the listener has not opened. A recording in progress is never counted.
    var unheardCount: Int { catalog.unheardCount }

    /// Called with a message when the log cannot be read or written; once per failure, not once per attempt.
    @ObservationIgnored var onError: ((String) -> Void)?
    /// Called after every change to `catalog`, so the player can reconcile what it holds with what exists.
    @ObservationIgnored var onChange: (() -> Void)?

    /// What the catalog is rebuilt from when the logs are read again, since the catalog does not expose them.
    @ObservationIgnored private var live: LiveRecording?
    @ObservationIgnored private var measured: [String: Double] = [:]
    /// The lines applied here while a read is in flight, numbered, so a read that may have missed them adds
    /// them rather than reading again: a read of a year of logs on a slow disk can take longer than the gap
    /// between two lines, and reading again each time would never finish.
    @ObservationIgnored private var linesLogged = 0
    @ObservationIgnored private var recentLines: [(number: Int, entry: RecordingLogEntry)] = []
    @ObservationIgnored private var readsInFlight = 0
    /// Counts listing changes, so a read can tell that the listing it took is older than the one held.
    @ObservationIgnored private var listingRevision = 0
    @ObservationIgnored private var readFailed = false
    @ObservationIgnored private var writeFailed = false

    /// What one read of a recordings folder finds, as a catalog built off the main actor (a year of logs is
    /// tens of thousands of lines). `listed` is false when the folder could not be listed.
    struct Snapshot: Sendable {
        var catalog: RecordingsCatalog, listed: Bool, failure: String?
    }

    /// Test hook: how a folder is read. The default reads off the main actor; a test replaces it to hold a
    /// read in flight while the library changes under it.
    @ObservationIgnored var reader: @Sendable (URL) async -> Snapshot = { folder in
        await Task.detached(priority: .userInitiated) { RecordingsLibrary.read(folder) }.value
    }

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
        live = nil
        liveSeconds = nil
        measured = [:]
        readFailed = false
        writeFailed = false
        catalog = RecordingsCatalog()
        changed()
        Task { await reload() }
    }

    /// Reads the folder listing and every day log, off the main actor, into a fresh catalog. Never applies
    /// the logs into the existing catalog. What changed while it read is added to what it read rather than
    /// read again: the lines applied meanwhile (a line it also read counts once), and a newer listing.
    func reload() async {
        let folder = self.folder
        let firstLine = linesLogged, listingSeen = listingRevision
        readsInFlight += 1
        let read = await reader(folder)
        readsInFlight -= 1
        defer { if readsInFlight == 0 { recentLines = [] } }
        guard folder == self.folder else { return }   // setFolder came in while reading
        if let failure = read.failure {
            // An unreadable day file is skipped; the other days still count.
            if !readFailed { onError?("Could not read the recordings log: \(failure)") }
            readFailed = true
        } else {
            readFailed = false
        }
        var fresh = read.catalog
        // A listing that failed reads as no files: keep the one held. One taken since the read began is newer.
        if !read.listed || listingRevision != listingSeen { fresh.setFiles(catalog.files) }
        fresh.apply(recentLines.filter { $0.number >= firstLine }.map(\.entry))
        fresh.setLive(live)
        for (file, seconds) in measured { fresh.setMeasuredSeconds(seconds, for: file) }
        catalog = fresh
        changed()
    }

    /// Reads the folder listing only: a file deleted in Finder, or a new recording the listing lacked. An
    /// unchanged listing changes nothing; one that cannot be read (a network share that dropped, a disk
    /// asleep) keeps the one held, so the files do not vanish and the player does not stop.
    func refreshFiles() async {
        let folder = self.folder
        let files = await Task.detached(priority: .userInitiated) { Self.listing(of: folder).map(Set.init) }.value
        // Compared first: even an unchanged `setFiles` writes `catalog`, which redraws the window and the badge.
        guard folder == self.folder, let files, files != catalog.files, catalog.setFiles(files) else { return }
        listingRevision += 1
        changed()
    }

    /// `AppModel`'s own writes, applied without rereading. Only for lines that were appended: the library
    /// sees exactly what is on disk.
    func didLog(_ entries: [RecordingLogEntry]) {
        guard !entries.isEmpty else { return }
        if readsInFlight > 0 {
            // As they read back from the file, so a line the read also saw is the same line, applied once.
            recentLines += entries.enumerated().map { (linesLogged + $0, $1.asLogged) }
        }
        linesLogged += entries.count
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

    /// The recording being written, or nil when none is. Its length growing changes only `liveSeconds`.
    func setLive(_ live: LiveRecording?) {
        guard live != self.live else { return }
        let sameRecording = live.map { Self.identity($0) } == self.live.map { Self.identity($0) }
        self.live = live
        liveSeconds = live?.seconds
        guard !sameRecording else { return }
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

    /// A live recording with its length left out: what the catalog holds of it.
    private static func identity(_ live: LiveRecording) -> LiveRecording {
        var live = live
        live.seconds = 0
        return live
    }

    /// The names in the folder (no file attributes: the catalog needs only names): none for a folder that
    /// does not exist yet, nil for one that cannot be listed.
    nonisolated private static func listing(of folder: URL) -> [String]? {
        do {
            return try FileManager.default.contentsOfDirectory(atPath: folder.path)
        } catch {
            return FileManager.default.fileExists(atPath: folder.path) ? nil : []
        }
    }

    nonisolated static func read(_ folder: URL) -> Snapshot {
        let files = listing(of: folder)
        let log = RecordingLog(folder: folder).readableEntries()
        return Snapshot(catalog: RecordingsCatalog(files: files ?? [], entries: log.entries), listed: files != nil,
                        failure: log.failure?.localizedDescription)
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
