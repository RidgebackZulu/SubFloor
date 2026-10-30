import AppKit
import Recording
import SwiftUI

/// The Recordings window's own palette: darker than the main window, like the spectrum, and fixed whatever
/// the appearance setting, so the lane colours glow the way the owner picked them in the mockup.
enum RecordingsTheme {
    static let background = rgb(0x0b0f15)
    static let panel = rgb(0x10151d)
    static let text = rgb(0xd8e1ec)
    static let muted = rgb(0x6b7686)
    static let now = rgb(0xff5a5f)
    static let line = Color.white.opacity(0.07)
    /// Amber, cyan, green, pink, violet, lime: one per lane, cycled.
    static let lanes = [0xffb847, 0x5cd6ff, 0x4ddb78, 0xff7ac8, 0xa98bff, 0xc6f06a].map(rgb)

    static func lane(_ index: Int) -> Color { lanes[((index % lanes.count) + lanes.count) % lanes.count] }

    private static func rgb(_ v: Int) -> Color {
        Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

/// Where the owner comes back to see what Auto caught while they were away: one UTC day at a time, the day's
/// recordings in lanes, and (under the timeline) the player for the one picked. The selection is the
/// window's; the player follows it.
///
/// The window never edits a recording or the log. Its only writes go through the library (`heard` lines,
/// from Clear and from playing) and the waveform cache.
struct RecordingsWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.controlActiveState) private var controlActiveState

    /// UTC midnight of the day shown.
    @State private var day = RecordingsCatalog.utcDayStart(Date())
    /// The selected recording's file. Never one in progress: that cannot be played yet.
    @State private var selection: String?
    /// Moves the now line; ticks only on today's view.
    @State private var now = Date()
    /// The window's content holds focus so Space and the arrows reach the player without a click first.
    @FocusState private var keysFocused: Bool
    /// The file whose peaks the player panel could not read: unplayable, for Space as for the play button.
    @State private var peaksFailure: URL?
    /// The timeline's height as it laid itself out: more than one row a lane where markers are stacked,
    /// which depends on its width.
    @State private var timelineHeight: CGFloat?
    /// The search field's text. Not remembered: a new window starts with everything lit.
    @State private var query = ""
    /// The recordings on every day that match the query, by start time, and the files it fades on the timeline.
    /// Worked out when the query, the catalog, the transcripts or the selection change, not on the clock's tick.
    @State private var matches: [CatalogRecording] = []
    @State private var dimmedFiles: Set<String> = []
    /// Typing in the field must not reach the player: Space and the arrows are the field's own while it has focus.
    @FocusState private var searchFocused: Bool

    private var library: RecordingsLibrary { model.library }
    private var today: Date { RecordingsCatalog.utcDayStart(now) }
    private var isToday: Bool { day == today }
    private var search: RecordingsSearch { RecordingsSearch(query: query) }

    /// The selected recording as the catalog has it now, or nil once it is gone (deleted in Finder).
    private var selectedRecording: CatalogRecording? { selection.flatMap { library.catalog.recording($0) } }

    var body: some View {
        content
            .background { findShortcut }
            .onChange(of: query) { refreshSearch() }
            .onChange(of: library.catalog) { refreshSearch() }
            .onChange(of: library.transcripts) { refreshSearch() }
            .onChange(of: selection) { refreshSearch() }
    }

    private var content: some View {
        let catalog = library.catalog
        let lanes = catalog.lanes(onUTCDay: day)
        let height = timelineHeight ?? DayTimelineView.height(lanes: lanes.count)
        return VStack(spacing: 0) {
            header
            Rectangle().fill(RecordingsTheme.line).frame(height: 1)
            ScrollView(.vertical) {
                DayTimelineView(dayStart: day, recordings: catalog.recordings(onUTCDay: day), lanes: lanes,
                                pops: catalog.pops(onUTCDay: day), selection: selection, now: isToday ? now : nil,
                                onSelect: { select($0) }, liveSeconds: { [library] in library.liveSeconds },
                                marks: TranscriptMarks.marks(index: library.transcripts, states: model.transcription.states),
                                dimmed: dimmedFiles, canTranscribe: model.hasAPIKey && model.transcriptionSettings.enabled,
                                onTranscribe: { [model] in model.retryTranscription($0) })
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { timelineHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            // The timeline gives way before the player does: a short window scrolls the lanes, never cuts
            // off the player.
            .frame(minHeight: min(height, 120), maxHeight: min(height, 400))
            .padding(.top, 16)
            .padding(.bottom, 8)

            PlayerPanel(recording: selectedRecording,
                        lane: selectedRecording.flatMap { r in lanes.firstIndex { $0.id == r.laneID } } ?? 0,
                        player: model.player, audioURL: selectedRecording.map { library.url(for: $0.file) },
                        cacheFolder: library.folder.appendingPathComponent(".subfloor/peaks", isDirectory: true),
                        peaksFailure: $peaksFailure, searchTerms: search.terms)
                .padding(.horizontal, 18)
                .padding(.bottom, 18)
        }
        .frame(minWidth: 900, minHeight: 480, alignment: .top)
        .background(RecordingsTheme.background)
        .foregroundStyle(RecordingsTheme.text)
        .focusable()
        .focusEffectDisabled()
        .focused($keysFocused)
        // Always handled, so a key with nothing loaded is quiet rather than a beep. Space pauses whatever plays,
        // and starts only what the panel would let the play button start.
        .onKeyPress(.space, phases: .down) { _ in
            guard !searchFocused else { return .ignored }
            let player: RecordingPlayer = model.player
            if player.isPlaying { player.pause() } else if playerDisplay.playable { player.play() }
            return .handled
        }
        .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
            guard !searchFocused else { return .ignored }
            let direction = press.key == .leftArrow ? -1 : 1
            if press.modifiers.contains(.shift) {
                stepRecording(direction)
            } else if playerDisplay.seekable {
                model.player.move(jumps: direction)
            }
            return .handled
        }
        .onAppear {
            opened()
            model.recordingsWindowOpen = true
            model.recordingsWindowIsKey = controlActiveState == .key
        }
        .onChange(of: controlActiveState) { _, state in model.recordingsWindowIsKey = state == .key }
        .onChange(of: peaksFailure) { _, url in model.recordingsUnplayableFile = url?.lastPathComponent }
        .onDisappear {
            model.player.pause()
            model.recordingsWindowOpen = false
            model.recordingsWindowIsKey = false
            model.recordingsUnplayableFile = nil
        }
        .onChange(of: selectedRecording == nil) { _, gone in
            // A file deleted in Finder: the player unloads it itself; the selection goes with it.
            if gone { selection = nil }
        }
        .task(id: day) {
            // The folder can change under the window (Finder, another recorder), and nothing else watches it.
            while !Task.isCancelled {
                await library.refreshFiles()
                await library.measureMissingLengths(onUTCDay: day)
                try? await Task.sleep(for: .seconds(5))
            }
        }
        .task(id: isToday) {
            now = Date()
            guard isToday else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                now = Date()
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Button { step(-1) } label: { Image(systemName: "chevron.left").frame(width: 14) }
                .buttonStyle(ChipButtonStyle())
                .help("Previous day")
            Text(RecordingsFormat.dayTitle(day))
                .font(.system(size: 15, weight: .semibold))
                .monospacedDigit()
                .frame(minWidth: 170)
            Button { step(1) } label: { Image(systemName: "chevron.right").frame(width: 14) }
                .buttonStyle(ChipButtonStyle())
                .disabled(day >= today)
                .help("Next day")
            Button("Today") { day = RecordingsCatalog.utcDayStart(Date()); now = Date() }
                .buttonStyle(ChipButtonStyle())
                .disabled(isToday)

            Spacer(minLength: 12)

            let unheard = library.unheardCount
            HStack(spacing: 6) {
                if unheard > 0 { Circle().fill(RecordingsTheme.now).frame(width: 6, height: 6) }
                Text("\(unheard) unheard").monospacedDigit()
            }
            .font(.system(size: 12))
            .foregroundStyle(unheard > 0 ? RecordingsTheme.text : RecordingsTheme.muted)
            .help("Recordings not yet played, on every day")
            Button("Clear") { library.clear() }
                .buttonStyle(ChipButtonStyle())
                .disabled(unheard == 0)
                .help("Mark every recording heard")
            TranscribeChip()
            searchControls
            Button("Show in Finder", action: showInFinder)
                .buttonStyle(ChipButtonStyle())
                .help(selection == nil ? "Show the recordings folder" : "Show the selected recording")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    /// ⌘F: an invisible button, since the window has no menu of its own to hold the command.
    private var findShortcut: some View {
        Button("Search Transcripts") { searchFocused = true }
            .keyboardShortcut("f", modifiers: .command)
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
    }

    /// The search field, "N matches" while a query is typed, and ◀ ▶ to step through the matches across days.
    private var searchControls: some View {
        let active = search.isActive
        return HStack(spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(RecordingsTheme.muted)
                TextField("Search transcripts", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .frame(width: 130)
                    .focused($searchFocused)
                    .onSubmit { stepMatch(forward: true, fromField: true) }
                    .onKeyPress(.escape) {
                        // The first Esc clears the query; Esc in an empty field hands the keys back to the player.
                        if query.isEmpty {
                            searchFocused = false
                            keysFocused = true
                        } else {
                            query = ""
                        }
                        return .handled
                    }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color(red: 0.106, green: 0.133, blue: 0.188)))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(searchFocused ? RecordingsTheme.lanes[0].opacity(0.6)
                                                                           : Color(red: 0.165, green: 0.2, blue: 0.267)))
            if active {
                Text(RecordingsSearch.countText(matches.count))
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(matches.isEmpty ? RecordingsTheme.muted : RecordingsTheme.text)
                    .fixedSize()
            }
            Button { stepMatch(forward: false, fromField: false) } label: { Image(systemName: "chevron.left").frame(width: 14) }
                .buttonStyle(ChipButtonStyle())
                .disabled(matches.isEmpty)
                .help("Previous match")
            Button { stepMatch(forward: true, fromField: false) } label: { Image(systemName: "chevron.right").frame(width: 14) }
                .buttonStyle(ChipButtonStyle())
                .disabled(matches.isEmpty)
                .help("Next match")
        }
    }

    /// The panel's rule for the selected recording, for the keys. Read only from the key handlers, never from
    /// `body`, so the window does not re-render with the player.
    private var playerDisplay: WaveformDisplay {
        let player: RecordingPlayer = model.player
        guard let r = selectedRecording else {
            return WaveformDisplay(drawsPeaks: false, message: nil, seekable: false, playable: false)
        }
        let loaded = player.file == r.file
        return WaveformDisplay.decide(loaded: loaded, hasEnvelope: false, loadError: loaded ? player.loadError : nil,
                                      peaksFailed: peaksFailure == library.url(for: r.file),
                                      duration: loaded ? player.duration : 0)
    }

    // MARK: Actions

    /// Today, or the day of the newest unheard recording when today has none, so what is new is in view.
    /// A recording the player still holds (the window was closed with it loaded) stays selected.
    private func opened() {
        now = Date()
        let catalog = library.catalog
        let today = RecordingsCatalog.utcDayStart(now)
        if catalog.recordings(onUTCDay: today).isEmpty,
           let newest = catalog.unheardFiles.compactMap({ catalog.recording($0)?.start }).max() {
            day = RecordingsCatalog.utcDayStart(newest)
        } else {
            day = today
        }
        if let file = model.player.file, catalog.recording(file) != nil { selection = file }
        keysFocused = true
    }

    /// Works the matches and the faded files out again. A blank query leaves both empty: everything is lit.
    private func refreshSearch() {
        let search = search
        guard search.isActive else {
            if !matches.isEmpty { matches = [] }
            if !dimmedFiles.isEmpty { dimmedFiles = [] }
            return
        }
        let catalog = library.catalog, index = library.transcripts
        matches = search.matches(catalog: catalog, index: index)
        dimmedFiles = search.dimmed(catalog.allRecordings, index: index, keeping: selection)
    }

    /// ◀ ▶ and Return in the field: the next or previous match, on whatever day it falls. The day is set first,
    /// then the match is picked as a click on it would. From the field (Return), focus stays there so Return
    /// keeps stepping; a click on ◀ ▶ hands the keys to the player, as a click on a marker does.
    private func stepMatch(forward: Bool, fromField: Bool) {
        let origin = RecordingsSearch.stepOrigin(matches, selected: selectedRecording, dayStart: day, forward: forward)
        guard let target = RecordingsSearch.step(matches, from: origin, forward: forward) else { return }
        day = RecordingsCatalog.utcDayStart(target.start)
        if !fromField { searchFocused = false }
        select(target, takeFocus: !fromField)
    }

    private func step(_ days: Int) {
        day = min(day.addingTimeInterval(Double(days) * 86_400), today)
    }

    /// A marker selects its recording and loads it into the player; empty space clears both, so the player
    /// never plays something the window no longer points at.
    ///
    /// The window takes keyboard focus for the player unless `takeFocus` is false (a step from the search field).
    private func select(_ recording: CatalogRecording?, takeFocus: Bool = true) {
        guard let recording else {
            selection = nil
            model.player.unload()
            return
        }
        guard !recording.inProgress else { return }
        selection = recording.file
        if model.player.file != recording.file { model.player.load(recording) }
        if takeFocus { keysFocused = true }
    }

    /// ⇧← / ⇧→: the previous or next recording on the shown day, in start order, as a click on it would pick
    /// it. One in progress cannot be played, so it is stepped over. With nothing selected on this day, → takes
    /// the first and ← the last.
    private func stepRecording(_ direction: Int) {
        let playable = library.catalog.recordings(onUTCDay: day).filter { !$0.inProgress }
        guard !playable.isEmpty else { return }
        if let i = playable.firstIndex(where: { $0.file == selection }) {
            let j = i + direction
            if playable.indices.contains(j) { select(playable[j]) }
        } else {
            select(direction > 0 ? playable[0] : playable[playable.count - 1])
        }
    }

    private func showInFinder() {
        if let file = selectedRecording?.file {
            NSWorkspace.shared.activateFileViewerSelecting([library.url(for: file)])
        } else {
            model.revealRecordings()
        }
    }
}

/// The mockup's chip buttons: dark, rounded, quiet until hovered or pressed. `on` fills the chosen one in amber,
/// like the selected jump chip.
struct ChipButtonStyle: ButtonStyle {
    var on = false
    var monospaced = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let amber = RecordingsTheme.lanes[0]
        configuration.label
            .font(.system(size: 12, design: monospaced ? .monospaced : .default))
            .foregroundStyle(on ? amber : Color(red: 0.73, green: 0.77, blue: 0.83))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 7).fill(on ? amber.opacity(0.16) : Color(red: 0.106, green: 0.133, blue: 0.188))
                .opacity(configuration.isPressed ? 0.6 : 1))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(on ? amber.opacity(0.5) : Color(red: 0.165, green: 0.2, blue: 0.267)))
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(Rectangle())
    }
}
