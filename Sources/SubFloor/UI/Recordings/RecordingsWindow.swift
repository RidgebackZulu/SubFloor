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

    private var library: RecordingsLibrary { model.library }
    private var today: Date { RecordingsCatalog.utcDayStart(now) }
    private var isToday: Bool { day == today }

    /// The selected recording as the catalog has it now, or nil once it is gone (deleted in Finder).
    private var selectedRecording: CatalogRecording? { selection.flatMap { library.catalog.recording($0) } }

    var body: some View {
        let catalog = library.catalog
        let lanes = catalog.lanes(onUTCDay: day)
        let height = timelineHeight ?? DayTimelineView.height(lanes: lanes.count)
        VStack(spacing: 0) {
            header
            Rectangle().fill(RecordingsTheme.line).frame(height: 1)
            ScrollView(.vertical) {
                DayTimelineView(dayStart: day, recordings: catalog.recordings(onUTCDay: day), lanes: lanes,
                                pops: catalog.pops(onUTCDay: day), selection: selection, now: isToday ? now : nil,
                                onSelect: select, liveSeconds: { [library] in library.liveSeconds })
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
                        peaksFailure: $peaksFailure)
                .padding(.horizontal, 18)
                .padding(.bottom, 18)
        }
        .frame(minWidth: 760, minHeight: 480, alignment: .top)
        .background(RecordingsTheme.background)
        .foregroundStyle(RecordingsTheme.text)
        .focusable()
        .focusEffectDisabled()
        .focused($keysFocused)
        // Always handled, so a key with nothing loaded is quiet rather than a beep. Space pauses whatever plays,
        // and starts only what the panel would let the play button start.
        .onKeyPress(.space, phases: .down) { _ in
            let player: RecordingPlayer = model.player
            if player.isPlaying { player.pause() } else if playerDisplay.playable { player.play() }
            return .handled
        }
        .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
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
            Button("Show in Finder", action: showInFinder)
                .buttonStyle(ChipButtonStyle())
                .help(selection == nil ? "Show the recordings folder" : "Show the selected recording")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
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

    private func step(_ days: Int) {
        day = min(day.addingTimeInterval(Double(days) * 86_400), today)
    }

    /// A marker selects its recording and loads it into the player; empty space clears both, so the player
    /// never plays something the window no longer points at.
    private func select(_ recording: CatalogRecording?) {
        guard let recording else {
            selection = nil
            model.player.unload()
            return
        }
        guard !recording.inProgress else { return }
        selection = recording.file
        if model.player.file != recording.file { model.player.load(recording) }
        keysFocused = true
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
