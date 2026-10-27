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

    /// UTC midnight of the day shown.
    @State private var day = RecordingsCatalog.utcDayStart(Date())
    /// The selected recording's file. Never one in progress: that cannot be played yet.
    @State private var selection: String?
    /// Moves the now line; ticks only on today's view.
    @State private var now = Date()

    private var library: RecordingsLibrary { model.library }
    private var today: Date { RecordingsCatalog.utcDayStart(now) }
    private var isToday: Bool { day == today }

    /// The selected recording as the catalog has it now, or nil once it is gone (deleted in Finder).
    private var selectedRecording: CatalogRecording? { selection.flatMap { library.catalog.recording($0) } }

    var body: some View {
        let catalog = library.catalog
        let lanes = catalog.lanes(onUTCDay: day)
        let height = DayTimelineView.height(lanes: lanes.count)
        VStack(spacing: 0) {
            header
            Rectangle().fill(RecordingsTheme.line).frame(height: 1)
            ScrollView(.vertical) {
                DayTimelineView(dayStart: day, recordings: catalog.recordings(onUTCDay: day), lanes: lanes,
                                pops: catalog.pops(onUTCDay: day), selection: selection, now: isToday ? now : nil,
                                onSelect: select)
                    .frame(height: height)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(height, 400))
            .padding(.top, 16)
            .padding(.bottom, 8)

            playerArea
                .padding(.horizontal, 18)
                .padding(.bottom, 18)
        }
        .frame(minWidth: 760, minHeight: 360, alignment: .top)
        .background(RecordingsTheme.background)
        .foregroundStyle(RecordingsTheme.text)
        .onAppear(perform: opened)
        .onDisappear { model.player.pause() }
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

    // MARK: Player

    /// Task 6's player panel goes here, reading `selectedRecording` and `model.player`.
    @ViewBuilder private var playerArea: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let r = selectedRecording {
                Text(RecordingsCatalog.laneTitle(frequencyHz: r.frequencyHz, mode: r.mode)).font(.system(size: 15, weight: .semibold))
                Text([RecordingsFormat.clock(r.start), r.seconds.map(RecordingsFormat.length), r.auto ? "Auto" : "Manual"]
                        .compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(RecordingsTheme.muted)
            } else {
                Text("Pick a recording on the timeline").foregroundStyle(RecordingsTheme.muted)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 90, alignment: .topLeading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(RecordingsTheme.panel))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(RecordingsTheme.line))
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
    }

    private func showInFinder() {
        if let file = selectedRecording?.file {
            NSWorkspace.shared.activateFileViewerSelecting([library.url(for: file)])
        } else {
            model.revealRecordings()
        }
    }
}

/// The mockup's chip buttons: dark, rounded, quiet until hovered or pressed.
private struct ChipButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12))
            .foregroundStyle(Color(red: 0.73, green: 0.77, blue: 0.83))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color(red: 0.106, green: 0.133, blue: 0.188)
                .opacity(configuration.isPressed ? 0.6 : 1)))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color(red: 0.165, green: 0.2, blue: 0.267)))
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(Rectangle())
    }
}
