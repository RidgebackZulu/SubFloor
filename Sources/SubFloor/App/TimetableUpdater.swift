import Foundation
import Scheduling

/// Keeps the scheduler's EiBi timetable current: loads the cached copy at launch, then checks for an update (the
/// files themselves only fetch once a week) every 24 hours while SubFloor runs. Made once, by the app, never in tests.
@MainActor
final class TimetableUpdater {
    static let interval: Duration = .seconds(24 * 3600)

    private let files: TimetableFiles
    private let scheduler: Scheduler
    private var loop: Task<Void, Never>?

    init(files: TimetableFiles, scheduler: Scheduler) {
        self.files = files
        self.scheduler = scheduler
    }

    /// Loads the cache (a fetched copy replaces the bundled one), then checks now and every 24 hours.
    func start() {
        guard loop == nil else { return }
        if files.meta?.fetchedAt != nil { scheduler.timetableUpdated(files.load()) }
        scheduler.timetableCheckedAt = files.meta?.checkedAt
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.check(now: Date())
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    /// One check: a new timetable goes to the scheduler, and the check time is passed on either way.
    func check(now: Date) async {
        if let timetable = await files.updateIfDue(now: now) { scheduler.timetableUpdated(timetable) }
        scheduler.timetableCheckedAt = files.meta?.checkedAt
    }
}
