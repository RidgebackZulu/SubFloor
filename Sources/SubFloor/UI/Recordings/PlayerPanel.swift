import Recording
import SwiftUI

/// Under the timeline: the selected recording's title line and playhead clock, its waveform to click, drag and
/// zoom, and the play button and jump chips. Space and the arrow keys are the window's (see `RecordingsWindow`).
///
/// Only the clock and the waveform read the playhead, each in its own view, so the 30 Hz position updates
/// while playing re-render those two and not the title line or the controls.
struct PlayerPanel: View {
    /// The selected recording, or nil when nothing is.
    let recording: CatalogRecording?
    /// Its lane on the shown day, for its colour.
    let lane: Int
    let player: RecordingPlayer
    /// The selected recording's file, which its peaks are read from.
    let audioURL: URL?
    /// `<recordings folder>/.subfloor/peaks`.
    let cacheFolder: URL

    @State private var envelope: PeakEnvelope?
    @State private var loadingPeaks = false
    @State private var zoom = WaveformZoom()

    /// `0.1 s` … `30 s`, `5 min`: what a jump chip says.
    nonisolated static func jumpTitle(_ seconds: Double) -> String {
        if seconds >= 60 { return "\(Int(seconds / 60)) min" }
        return seconds == seconds.rounded() ? "\(Int(seconds)) s" : "\(seconds) s"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let r = recording {
                let color = RecordingsTheme.lane(lane)
                titleLine(r)
                PlayerWaveform(recording: r, player: player, envelope: envelope, loading: loadingPeaks, color: color,
                               zoom: $zoom)
                PlayerControls(recording: r, player: player, color: color)
            } else {
                Text("Pick a recording on the timeline")
                    .foregroundStyle(RecordingsTheme.muted)
                    .frame(maxWidth: .infinity, minHeight: 90)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .background(RoundedRectangle(cornerRadius: 12).fill(RecordingsTheme.panel))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(RecordingsTheme.line))
        // A new selection cancels the read of the last one's peaks: a 1.5 h file read for the first time takes
        // seconds, and the listener may already have moved on.
        .task(id: audioURL) { await loadPeaks() }
    }

    /// `11.175 MHz USB  07:48:12.4Z  7.8 s  Auto` … and the playhead clock on the right.
    private func titleLine(_ r: CatalogRecording) -> some View {
        let length = r.seconds ?? (player.file == r.file && player.duration > 0 ? player.duration : nil)
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(RecordingsCatalog.laneTitle(frequencyHz: r.frequencyHz, mode: r.mode))
                .font(.system(size: 15, weight: .semibold))
                .padding(.trailing, 4)
            tag(RecordingsFormat.clock(r.start), monospaced: true)
            if let length { tag(RecordingsFormat.length(length), monospaced: false) }
            tag(r.auto ? "Auto" : "Manual", monospaced: false)
            Spacer(minLength: 12)
            PlayheadClock(recording: r, player: player)
        }
    }

    /// The mockup's grey tag.
    private func tag(_ text: String, monospaced: Bool) -> some View {
        Text(text)
            .font(.system(size: 12, design: monospaced ? .monospaced : .default))
            .foregroundStyle(Color(red: 0.81, green: 0.84, blue: 0.89))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(red: 0x2a / 255, green: 0x31 / 255, blue: 0x40 / 255)))
            .fixedSize()
    }

    /// Reads the selected file's peaks (from the cache when it is current) and builds the envelope, both off
    /// the main actor. A file that cannot be read leaves the waveform empty: the player says it can't play it.
    private func loadPeaks() async {
        envelope = nil
        zoom = WaveformZoom()                // a new recording starts whole
        guard let audioURL else {
            loadingPeaks = false
            return
        }
        loadingPeaks = true
        do {
            let peaks = try await WaveformPeaks.load(audioFile: audioURL, cacheFolder: cacheFolder)
            let built = await Task.detached(priority: .userInitiated) { PeakEnvelope(peaks) }.value
            guard !Task.isCancelled else { return }
            envelope = built
        } catch {
            // Cancelled (the next selection's read owns the state now), or unreadable: nothing to draw.
        }
        if !Task.isCancelled { loadingPeaks = false }
    }
}

/// `07:48:12.4Z`: the moment playing, in the recording's own UTC time. The recording's start until the player
/// has it.
private struct PlayheadClock: View {
    let recording: CatalogRecording
    let player: RecordingPlayer

    var body: some View {
        let time = player.file == recording.file ? player.playheadTime ?? recording.start : recording.start
        Text(RecordingsFormat.clock(time))
            .font(Theme.readout)
            .foregroundStyle(RecordingsTheme.lanes[0])      // the mockup's amber, whatever the lane
            .fixedSize()
            .accessibilityLabel("Playhead")
    }
}

/// The waveform as the player has it: the position, the length, and seeking, or `Can't play this file` over
/// an empty waveform when the file could not be opened.
private struct PlayerWaveform: View {
    let recording: CatalogRecording
    let player: RecordingPlayer
    let envelope: PeakEnvelope?
    let loading: Bool
    let color: Color
    @Binding var zoom: WaveformZoom

    var body: some View {
        let loaded = player.file == recording.file
        let error = loaded ? player.loadError : nil
        let duration = loaded && player.duration > 0 ? player.duration : envelope?.duration ?? 0
        let player = player
        WaveformView(envelope: error == nil ? envelope : nil, loading: loading && error == nil, color: color,
                     duration: error == nil ? duration : 0, position: loaded ? player.position : 0, zoom: $zoom,
                     onSeek: loaded && error == nil && player.duration > 0 ? { player.seek(to: $0) } : nil)
            .overlay {
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(RecordingsTheme.text)
                        .symbolRenderingMode(.multicolor)
                }
            }
    }
}

/// Play/pause, then the jump chips: how far ← and → move.
private struct PlayerControls: View {
    let recording: CatalogRecording
    let player: RecordingPlayer
    let color: Color

    var body: some View {
        let canPlay = player.file == recording.file && player.loadError == nil && player.duration > 0
        HStack(spacing: 6) {
            Button { player.togglePlay() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(RecordingsTheme.background)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(color))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canPlay)
            .opacity(canPlay ? 1 : 0.4)
            .help(player.isPlaying ? "Pause (Space)" : "Play (Space)")
            .padding(.trailing, 10)

            Text("Jump").font(.system(size: 12)).foregroundStyle(RecordingsTheme.muted).padding(.trailing, 2)
            ForEach(RecordingPlayer.jumpSizes, id: \.self) { size in
                Button(PlayerPanel.jumpTitle(size)) { player.jump = size }
                    .buttonStyle(ChipButtonStyle(on: player.jump == size, monospaced: true))
                    .help("← and → move \(PlayerPanel.jumpTitle(size))")
            }

            Spacer(minLength: 12)
            Text("Space play · ← → jump · ⇧← ⇧→ recording · ⌘-scroll zoom")
                .font(.system(size: 11))
                .foregroundStyle(RecordingsTheme.muted)
                .lineLimit(1)
                .truncationMode(.head)
        }
    }
}
