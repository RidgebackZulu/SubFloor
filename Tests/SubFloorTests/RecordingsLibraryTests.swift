import AppKit
import AVFoundation
import Foundation
import Recording
import SubFloorCore
import Testing
import Transcription
@testable import SubFloor

/// The library of recordings the Recordings window shows: the folder listing, every day log and the recording
/// in progress, kept current without rereading what the app itself just wrote. Folders are temporary; files
/// are empty placeholders where only their names matter.
@MainActor
@Suite(.serialized)
struct RecordingsLibraryTests {
    private func tempFolder() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SubFloorLibraryTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// `SubFloor_20261026_143000Z_146520000Hz_NFM.wav` for a start `offset` seconds after 2026-10-26 14:30:00 UTC.
    private static let base = Date(timeIntervalSince1970: 1_792_074_600)

    private func name(_ offset: Double) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd_HHmmss"
        return "SubFloor_\(f.string(from: Self.base.addingTimeInterval(offset)))Z_146520000Hz_NFM.wav"
    }

    private func entry(_ file: String, _ offset: Double, seconds: Double = 5) -> RecordingLogEntry {
        .recording(file: file, start: Self.base.addingTimeInterval(offset), seconds: seconds, frequencyHz: 146_520_000, mode: "NFM", auto: true)
    }

    /// Placeholder files and their `recording` entries, written through the log as the app does.
    @discardableResult
    private func populate(_ folder: URL, offsets: [Double]) throws -> [String] {
        let files = offsets.map(name)
        for file in files { FileManager.default.createFile(atPath: folder.appendingPathComponent(file).path, contents: Data()) }
        try RecordingLog(folder: folder).append(zip(files, offsets).map { entry($0, $1) })
        return files
    }

    private func heardLines(_ folder: URL) throws -> [String] {
        try RecordingLog(folder: folder).allEntries().compactMap { if case .heard(let file, _) = $0 { file } else { nil } }
    }

    private final class Box { var messages: [String] = [] }

    @Test func reloadReadsTheFolderAndEveryLog() async throws {
        let folder = tempFolder()
        let files = try populate(folder, offsets: [0, 86_400])   // two UTC days
        let library = RecordingsLibrary(folder: folder)
        #expect(library.unheardCount == 0)   // nothing read yet
        await library.reload()
        #expect(library.catalog.recording(files[0]) != nil)
        #expect(library.catalog.recording(files[1]) != nil)
        #expect(library.unheardCount == 2)
    }

    @Test func markHeardWritesOneLineAndDropsTheCount() async throws {
        let folder = tempFolder()
        let files = try populate(folder, offsets: [0, 60])
        let library = RecordingsLibrary(folder: folder)
        await library.reload()
        library.markHeard(files[0])
        #expect(library.unheardCount == 1)
        #expect(try heardLines(folder) == [files[0]])
        library.markHeard(files[0])   // already heard: nothing written
        #expect(try heardLines(folder) == [files[0]])
        #expect(library.unheardCount == 1)
    }

    @Test func clearMarksEverythingHeard() async throws {
        let folder = tempFolder()
        let files = try populate(folder, offsets: [0, 60, 120])
        let library = RecordingsLibrary(folder: folder)
        await library.reload()
        #expect(library.unheardCount == 3)
        library.clear()
        #expect(library.unheardCount == 0)
        #expect(Set(try heardLines(folder)) == Set(files))
        await library.reload()   // from disk
        #expect(library.unheardCount == 0)
        library.clear()   // nothing unheard: nothing written
        #expect(try heardLines(folder).count == 3)
    }

    @Test func didLogUpdatesWithoutReading() async throws {
        let folder = tempFolder()
        let file = name(0)
        FileManager.default.createFile(atPath: folder.appendingPathComponent(file).path, contents: Data())
        let library = RecordingsLibrary(folder: folder)
        await library.reload()
        #expect(library.unheardCount == 0)   // no log line: a file from before the log, heard
        library.didLog([entry(file, 0)])
        #expect(library.unheardCount == 1)
    }

    @Test func setFolderReloadsFromTheNewFolder() async throws {
        let a = tempFolder(), b = tempFolder()
        let aFiles = try populate(a, offsets: [0, 60])
        let bFiles = try populate(b, offsets: [120])
        let library = RecordingsLibrary(folder: a)
        await library.reload()
        #expect(library.unheardCount == 2)
        library.setFolder(b)
        #expect(library.folder == b)
        #expect(library.unheardCount == 0)   // replaced at once
        await library.reload()
        #expect(library.unheardCount == 1)
        #expect(library.catalog.recording(bFiles[0]) != nil)
        #expect(aFiles.allSatisfy { library.catalog.recording($0) == nil && !library.catalog.files.contains($0) })
    }

    /// Holds one read of a folder in flight, after it has read, so a test can change the library under it.
    private actor Gate {
        private(set) var reads = 0
        private var armed = false
        private var waiter: CheckedContinuation<Void, Never>?
        var isHeld: Bool { waiter != nil }
        func arm() { armed = true }
        func pass() async {
            reads += 1
            guard armed else { return }
            armed = false
            await withCheckedContinuation { waiter = $0 }
        }
        func release() { waiter?.resume(); waiter = nil }
    }

    private func gated(_ library: RecordingsLibrary) -> Gate {
        let gate = Gate()
        library.reader = { folder in
            let snapshot = RecordingsLibrary.read(folder)   // the data as it was when the read began
            await gate.pass()
            return snapshot
        }
        return gate
    }

    private func waitUntilHeld(_ gate: Gate) async throws {
        for _ in 0..<500 where !(await gate.isHeld) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await gate.isHeld)
    }

    @Test func aReloadThatFinishesAfterSetFolderIsDiscarded() async throws {
        let a = tempFolder(), b = tempFolder()
        let aFiles = try populate(a, offsets: [0, 60])
        let bFiles = try populate(b, offsets: [120])
        let library = RecordingsLibrary(folder: a)
        let gate = gated(library)
        await gate.arm()
        let stale = Task { await library.reload() }   // reads A, then waits
        try await waitUntilHeld(gate)
        library.setFolder(b)
        await library.reload()   // B's, which is not held
        await gate.release()
        await stale.value        // A's finishes last, and must not replace B's
        #expect(library.folder == b)
        #expect(library.catalog.files.isDisjoint(with: aFiles))
        #expect(bFiles.allSatisfy { library.catalog.recording($0) != nil })
        #expect(library.unheardCount == 1)
    }

    @Test func aLineLoggedWhileAReadIsInFlightIsNotLost() async throws {
        let folder = tempFolder()
        let files = try populate(folder, offsets: [0])
        let library = RecordingsLibrary(folder: folder)
        let gate = gated(library)
        await library.reload()
        #expect(library.unheardCount == 1)
        await gate.arm()
        let reading = Task { await library.reload() }   // reads the log without the heard line, then waits
        try await waitUntilHeld(gate)
        library.markHeard(files[0])                    // written and applied meanwhile
        await gate.release()
        await reading.value
        #expect(await gate.reads == 2)   // the line is added to what the held read found, not read again
        #expect(library.unheardCount == 0)
    }

    private func transcript(_ file: String) -> StoredTranscript {
        StoredTranscript(file: file, model: "m", language: "en", createdAt: Date(timeIntervalSince1970: 0),
                         durationSeconds: 5, costUSD: nil, note: "silent", chunks: [])
    }

    @Test func reloadReadsSidecarsAndSetFolderClearsThem() async throws {
        let a = tempFolder(), b = tempFolder()
        let files = try populate(a, offsets: [0, 60])
        try TranscriptStore.write(transcript(files[0]), in: a)
        let library = RecordingsLibrary(folder: a)
        await library.reload()
        #expect(library.transcripts.contains(files[0]))
        #expect(!library.transcripts.contains(files[1]))
        #expect(library.untranscribed().map(\.file) == [files[1]])
        library.setFolder(b)
        #expect(!library.transcripts.contains(files[0]))   // at once, before B is read
        library.didTranscribe(transcript(files[1]), folder: a)   // a job from A landing late
        #expect(!library.transcripts.contains(files[1]))
    }

    @Test func aTranscriptLandingWhileAReadIsInFlightIsNotLost() async throws {
        let folder = tempFolder()
        let files = try populate(folder, offsets: [0])
        let library = RecordingsLibrary(folder: folder)
        let gate = gated(library)
        await gate.arm()
        let reading = Task { await library.reload() }   // lists the sidecars before this one exists, then waits
        try await waitUntilHeld(gate)
        try TranscriptStore.write(transcript(files[0]), in: folder)
        library.didTranscribe(transcript(files[0]), folder: folder)
        await gate.release()
        await reading.value
        #expect(library.transcripts.contains(files[0]))
    }

    /// Holds one read in flight before it reads, so what is written meanwhile is in what it reads.
    private func gatedBeforeReading(_ library: RecordingsLibrary) -> Gate {
        let gate = Gate()
        library.reader = { folder in
            await gate.pass()
            return RecordingsLibrary.read(folder)
        }
        return gate
    }

    @Test func aLineTheReadAlsoSawCountsOnce() async throws {
        let folder = tempFolder()
        try populate(folder, offsets: [0])
        let library = RecordingsLibrary(folder: folder)
        let gate = gatedBeforeReading(library)
        await gate.arm()
        let reading = Task { await library.reload() }
        try await waitUntilHeld(gate)
        // Written as the app writes it (at full precision in memory, to the millisecond on disk), then read.
        let pop = RecordingLogEntry.pop(at: Self.base.addingTimeInterval(30.123456), seconds: 0.2, frequencyHz: 146_520_000, mode: "NFM")
        try RecordingLog(folder: folder).append([pop])
        library.didLog([pop])
        await gate.release()
        await reading.value
        #expect(library.catalog.pops(onUTCDay: Self.base).count == 1)
        #expect(await gate.reads == 1)
    }

    @Test func aListingTakenDuringAReadIsKeptWithoutReadingAgain() async throws {
        let folder = tempFolder()
        let files = try populate(folder, offsets: [0, 60])
        let library = RecordingsLibrary(folder: folder)
        let gate = gated(library)
        await library.reload()
        await gate.arm()
        let reading = Task { await library.reload() }   // lists both files, then waits
        try await waitUntilHeld(gate)
        try FileManager.default.removeItem(at: folder.appendingPathComponent(files[0]))
        await library.refreshFiles()
        await gate.release()
        await reading.value
        #expect(await gate.reads == 2)   // no read again, however often the listing changes during a slow read
        #expect(library.catalog.recording(files[0]) == nil)   // the newer listing
        #expect(library.catalog.recording(files[1]) != nil)
        #expect(library.unheardCount == 1)
    }

    @Test func anUnchangedListingChangesNothing() async throws {
        let folder = tempFolder()
        try populate(folder, offsets: [0, 60])
        let library = RecordingsLibrary(folder: folder)
        await library.reload()
        var changes = 0
        library.onChange = { changes += 1 }
        await library.refreshFiles()
        #expect(changes == 0)
    }

    @Test func aListingThatFailsKeepsTheFiles() async throws {
        let folder = tempFolder()
        let files = try populate(folder, offsets: [0, 60])
        let library = RecordingsLibrary(folder: folder)
        await library.reload()
        // Searchable but not listable: the files are still there, the listing fails (a share that dropped).
        try FileManager.default.setAttributes([.posixPermissions: 0o333], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        await library.refreshFiles()
        #expect(files.allSatisfy { library.catalog.recording($0) != nil })
        await library.reload()
        #expect(files.allSatisfy { library.catalog.recording($0) != nil })
        #expect(library.unheardCount == 2)   // the logs were still read
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        try FileManager.default.removeItem(at: folder)   // a folder that is gone is empty, not a failure
        await library.refreshFiles()
        #expect(library.catalog.files.isEmpty)
    }

    @Test func oneUnreadableDayKeepsTheOtherDays() async throws {
        let folder = tempFolder()
        let files = try populate(folder, offsets: [0, 86_400])   // two UTC days
        let day = RecordingLog(folder: folder).fileURL(forUTCDay: Self.base)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: day.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: day.path) }
        let library = RecordingsLibrary(folder: folder)
        let errors = Box()
        library.onError = { errors.messages.append($0) }
        await library.reload()
        await library.reload()
        #expect(library.catalog.recording(files[1])?.heard == false)   // the readable day's log still counts
        #expect(library.catalog.recording(files[0])?.heard == true)    // the unreadable one's: heard and manual
        #expect(library.unheardCount == 1)
        #expect(errors.messages.count == 1)
    }

    @Test func aGrowingLiveRecordingLeavesTheCatalogAlone() async throws {
        let folder = tempFolder()
        try populate(folder, offsets: [0])
        let library = RecordingsLibrary(folder: folder)
        await library.reload()
        var changes = 0
        library.onChange = { changes += 1 }
        var live = LiveRecording(file: name(300), start: Self.base.addingTimeInterval(300), seconds: 0.2,
                                 frequencyHz: 146_520_000, mode: "NFM", auto: true)
        library.setLive(live)
        #expect(changes == 1)
        let catalog = library.catalog
        live.seconds = 12.4
        library.setLive(live)
        #expect(library.liveSeconds == 12.4)
        #expect(library.catalog == catalog)   // the window's day and the badge are not touched
        #expect(changes == 1)
        library.setLive(nil)
        #expect(library.liveSeconds == nil)
        #expect(changes == 2)
    }

    @Test func refreshFilesDropsDeletedFiles() async throws {
        let folder = tempFolder()
        let files = try populate(folder, offsets: [0, 60])
        let library = RecordingsLibrary(folder: folder)
        await library.reload()
        #expect(library.unheardCount == 2)
        try FileManager.default.removeItem(at: folder.appendingPathComponent(files[0]))
        await library.refreshFiles()
        #expect(library.catalog.recording(files[0]) == nil)
        #expect(library.catalog.recording(files[1]) != nil)
        #expect(library.unheardCount == 1)
    }

    @Test func logWriteFailureReportsOnce() async throws {
        let folder = tempFolder()
        let files = try populate(folder, offsets: [0, 60])
        let library = RecordingsLibrary(folder: folder)
        let errors = Box()
        library.onError = { errors.messages.append($0) }
        await library.reload()
        // Today's day file does not exist, and a read-only .subfloor cannot take a new one.
        let log = folder.appendingPathComponent(".subfloor")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: log.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: log.path) }
        library.markHeard(files[0])
        library.markHeard(files[0])
        #expect(errors.messages.count == 1)
        #expect(library.unheardCount == 2)   // not heard: nothing was written
    }

    @Test func anUnreadableLogStillListsTheFilesAndReportsOnce() async throws {
        let folder = tempFolder()
        let files = try populate(folder, offsets: [0, 60])
        let day = RecordingLog(folder: folder).fileURL(forUTCDay: Self.base)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: day.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: day.path) }
        let library = RecordingsLibrary(folder: folder)
        let errors = Box()
        library.onError = { errors.messages.append($0) }
        await library.reload()
        await library.reload()
        #expect(files.allSatisfy { library.catalog.recording($0) != nil })
        #expect(library.unheardCount == 0)   // no log: heard and manual
        #expect(errors.messages.count == 1)
    }

    @Test func theRecordingInProgressIsNeverUnheardAndCannotBeMarkedHeard() async throws {
        let folder = tempFolder()
        let files = try populate(folder, offsets: [0])
        let library = RecordingsLibrary(folder: folder)
        await library.reload()
        let live = name(300)
        library.setLive(LiveRecording(file: live, start: Self.base.addingTimeInterval(300), seconds: 2, frequencyHz: 146_520_000, mode: "NFM", auto: true))
        library.didLog([.autoStarted(file: live, start: Self.base.addingTimeInterval(300), frequencyHz: 146_520_000, mode: "NFM")])
        #expect(library.unheardCount == 1)   // only the finished one
        library.markHeard(live)
        #expect(try heardLines(folder).isEmpty)
        library.setLive(nil)
        #expect(library.unheardCount == files.count)   // the folder has not listed it: still not a recording
    }

    @Test func aNewRecordingThatTheListingLacksIsPickedUp() async throws {
        let folder = tempFolder()
        let library = RecordingsLibrary(folder: folder)
        await library.reload()
        let file = name(0)
        FileManager.default.createFile(atPath: folder.appendingPathComponent(file).path, contents: Data())
        library.didLog([entry(file, 0)])
        await library.refreshFiles()
        #expect(library.unheardCount == 1)
    }

    @Test func onChangeFollowsEveryChange() async throws {
        let folder = tempFolder()
        let files = try populate(folder, offsets: [0, 60])
        let library = RecordingsLibrary(folder: folder)
        var changes = 0
        library.onChange = { changes += 1 }
        await library.reload()
        #expect(changes >= 1)
        var last = changes
        library.markHeard(files[0])
        #expect(changes > last)
        last = changes
        let live = LiveRecording(file: name(300), start: Self.base, seconds: 1, frequencyHz: 1, mode: "AM", auto: false)
        library.setLive(live)
        #expect(changes > last)
        last = changes
        library.setLive(live)
        #expect(changes == last)   // the same again: no change, no call
        library.clear()
        #expect(changes > last)
        last = changes
        library.setFolder(tempFolder())
        #expect(changes > last)
    }

    @Test func measuresOnlyTheLengthsTheLogLacks() async throws {
        let folder = tempFolder()
        let logged = name(0), bare = name(60)
        try writeWAV(folder.appendingPathComponent(logged), seconds: 1)
        try writeWAV(folder.appendingPathComponent(bare), seconds: 2)
        try RecordingLog(folder: folder).append([entry(logged, 0, seconds: 99)])
        let library = RecordingsLibrary(folder: folder)
        await library.reload()
        #expect(library.catalog.recording(bare)?.seconds == nil)
        await library.measureMissingLengths(onUTCDay: Self.base)
        #expect(library.catalog.recording(bare)?.seconds == 2)
        #expect(library.catalog.recording(logged)?.seconds == 99)   // the log wins
        await library.reload()   // a reload keeps what was measured
        #expect(library.catalog.recording(bare)?.seconds == 2)
    }

    @Test func theModelPointsTheLibraryAtTheRecordingsFolder() async throws {
        let dir = tempFolder()
        let model = AppModel(bookmarkStore: BookmarkStore(url: dir.appendingPathComponent("bookmarks.json")),
                             defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let folder = dir.appendingPathComponent("rec", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let files = try populate(folder, offsets: [0])
        model.recording.folderPath = folder.path
        #expect(model.library.folder == model.recording.folder)
        await model.library.reload()
        #expect(model.library.catalog.recording(files[0]) != nil)
    }

    @Test func comingToTheFrontListsTheFolderAgain() async throws {
        let dir = tempFolder()
        let model = AppModel(bookmarkStore: BookmarkStore(url: dir.appendingPathComponent("bookmarks.json")),
                             defaults: UserDefaults(suiteName: UUID().uuidString)!)
        defer { model.shutdown() }
        let folder = dir.appendingPathComponent("rec", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let files = try populate(folder, offsets: [0, 60])
        model.recording.folderPath = folder.path
        model.startLibrary()
        await model.library.reload()
        #expect(model.library.unheardCount == 2)
        try FileManager.default.removeItem(at: folder.appendingPathComponent(files[0]))   // in Finder, window closed
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        for _ in 0..<500 where model.library.unheardCount != 1 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.library.unheardCount == 1)
    }

    private func writeWAV(_ url: URL, seconds: Double) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 8000, channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(seconds * 8000)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        try file.write(from: buffer)
    }
}
