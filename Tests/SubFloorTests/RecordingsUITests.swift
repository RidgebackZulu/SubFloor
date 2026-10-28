import CoreGraphics
import Foundation
import Testing
@testable import Recording
@testable import SubFloor

/// The Recordings window's pure parts: where a time falls on the day timeline, which marker a click lands on,
/// and how times and lengths are written.
@Suite struct RecordingsUITests {
    /// 2026-10-27 00:00:00 UTC.
    private static let day = Date(timeIntervalSince1970: 1_793_059_200)

    private func at(_ h: Double, _ m: Double = 0, _ s: Double = 0) -> Date {
        Self.day.addingTimeInterval(h * 3600 + m * 60 + s)
    }

    @Test func geometryPlacesTimesAcrossTheDay() {
        let g = TimelineGeometry(dayStart: Self.day, width: 1200)
        #expect(g.x(for: at(0)) == 0)
        #expect(g.x(for: at(12)) == 600)
        #expect(g.x(for: at(24)) == 1200)
        #expect(g.x(for: at(30)) == 1200)    // the next day
        #expect(g.x(for: at(-1)) == 0)       // the day before
    }

    @Test func shortClipsKeepAClickableWidth() {
        let g = TimelineGeometry(dayStart: Self.day, width: 1200)
        let rect = g.markerRect(start: at(7, 48, 12), seconds: 20)
        #expect(rect.width == TimelineGeometry.minMarkerWidth)
        #expect(rect.width == 6)
    }

    @Test func clipsCrossingMidnightAreClipped() {
        let g = TimelineGeometry(dayStart: Self.day, width: 1200)
        let rect = g.markerRect(start: at(23), seconds: 7200, laneTop: TimelineGeometry.laneHeight)
        #expect(rect.maxX == 1200)
        #expect(rect.minX == 1150)
        // A short clip in the last seconds keeps its width inside the day rather than being cut to nothing.
        let late = g.markerRect(start: at(23, 59, 59), seconds: 20)
        #expect(late.maxX == 1200)
        #expect(late.width == 6)
    }

    @Test func hitTestFindsTheMarker() {
        let g = TimelineGeometry(dayStart: Self.day, width: 1200)
        let a = g.markerRect(start: at(6), seconds: 1800)
        let b = g.markerRect(start: at(12), seconds: 1800, laneTop: TimelineGeometry.laneHeight)
        let markers = [(file: "a.flac", rect: a), (file: "b.flac", rect: b)]
        #expect(g.recording(at: CGPoint(x: a.midX, y: a.midY), in: markers) == "a.flac")
        #expect(g.recording(at: CGPoint(x: b.midX, y: b.midY), in: markers) == "b.flac")
        #expect(g.recording(at: CGPoint(x: a.maxX + 2, y: a.midY), in: markers) == "a.flac")   // the slop
        #expect(g.recording(at: CGPoint(x: a.midX, y: a.minY - 2), in: markers) == "a.flac")
        #expect(g.recording(at: CGPoint(x: a.maxX + 10, y: a.midY), in: markers) == nil)
        #expect(g.recording(at: CGPoint(x: a.midX, y: a.maxY + 10), in: markers) == nil)
    }

    @Test func hitTestPrefersTheTopmostMarker() {
        let g = TimelineGeometry(dayStart: Self.day, width: 1200)
        let under = g.markerRect(start: at(6), seconds: 3600)
        let over = g.markerRect(start: at(6, 30), seconds: 3600)
        let markers = [(file: "under.flac", rect: under), (file: "over.flac", rect: over)]
        #expect(g.recording(at: CGPoint(x: over.minX + 1, y: over.midY), in: markers) == "over.flac")
        // Inside one marker and within the slop of the next: the marker under the pointer wins.
        let left = g.markerRect(start: at(9), seconds: 600)
        let right = CGRect(x: left.maxX + 2, y: left.minY, width: 20, height: left.height)
        let pair = [(file: "left.flac", rect: left), (file: "right.flac", rect: right)]
        #expect(g.recording(at: CGPoint(x: left.maxX - 1, y: left.midY), in: pair) == "left.flac")
    }

    // MARK: Stacking

    /// Recordings at `starts` (seconds into the day), `seconds` long, in one lane, laid out `width` wide.
    private func layout(_ starts: [Double], seconds: Double = 20, width: CGFloat = 950, live: Int? = nil,
                        lane: String = "11175000 USB") -> TimelineLayout {
        let recordings = starts.enumerated().map { i, t in
            CatalogRecording(file: "r\(i).flac", start: Self.day.addingTimeInterval(t), seconds: seconds,
                             frequencyHz: 11_175_000, mode: "USB", auto: true, heard: false, inProgress: i == live,
                             laneID: lane)
        }
        let lanes = [CatalogLane(id: lane, frequencyHz: 11_175_000, mode: "USB", title: "11.175 MHz USB")]
        // The view's width: the plot plus the label column and the trailing inset.
        return TimelineLayout(dayStart: Self.day, width: width + DayTimelineView.labelColumn + DayTimelineView.trailingInset,
                              recordings: recordings, lanes: lanes, pops: [], selection: nil)
    }

    @Test func threeMarkersTwoMinutesApartStackInThreeRows() {
        let l = layout([68_400, 68_520, 68_640])   // 19:00, 19:02, 19:04
        let rects = l.settled.sorted { $0.recording.file < $1.recording.file }.map(\.rect)
        #expect(Set(rects.map { $0.minY }).count == 3)
        #expect(l.laneHeights == [TimelineGeometry.laneHeight(rows: 3)])
        for (i, a) in rects.enumerated() {
            #expect(a.width >= TimelineGeometry.minMarkerWidth)
            for b in rects[(i + 1)...] { #expect(!a.intersects(b)) }
        }
        // Every one is found by the hover and the click, at its middle.
        for m in l.settled {
            let mid = CGPoint(x: m.rect.midX, y: m.rect.midY)
            #expect(l.marker(at: mid, selectableOnly: true)?.recording.file == m.recording.file)
            #expect(l.marker(at: mid, selectableOnly: false)?.recording.file == m.recording.file)
        }
    }

    @Test func markersApartKeepOneRowAndTheLookOfOne() {
        let l = layout([21_600, 32_400])   // 06:00 and 09:00
        #expect(Set(l.settled.map { $0.rect.minY }).count == 1)
        #expect(l.laneHeights == [TimelineGeometry.laneHeight])
        #expect(l.laneTops == [DayTimelineView.topInset])
        // Where a lane of one row put its pills before stacking existed.
        let g = TimelineGeometry(dayStart: Self.day, width: 950)
        let first = g.markerRect(start: at(6), seconds: 20)
        #expect(l.settled.first { $0.recording.file == "r0.flac" }?.rect
                == first.offsetBy(dx: DayTimelineView.labelColumn, dy: DayTimelineView.topInset))
        #expect(first.minY == (TimelineGeometry.laneHeight - TimelineGeometry.markerHeight) / 2)
        #expect(l.height == DayTimelineView.height(lanes: 1))
    }

    @Test func rowsReuseTheFirstFreeRow() {
        // 0 and 1 overlap; 2 starts after 0 ends (with the gap), so it goes back to row 0.
        #expect(TimelineGeometry.rows(for: [0...10, 5...15, 12...20]) == [0, 1, 0])
        #expect(TimelineGeometry.rows(for: [0...10, 11...20]) == [0, 1])   // a 1 pt gap is too close
        #expect(TimelineGeometry.rows(for: [0...10, 12...20]) == [0, 0])
        #expect(TimelineGeometry.rows(for: [12...20, 0...10]) == [0, 0])   // in start order, whatever the input order
        #expect(TimelineGeometry.rows(for: []) == [])
    }

    @Test func stackingFollowsTheWidth() {
        let starts: [Double] = [68_400, 68_520]
        #expect(layout(starts, width: 950).laneHeights == [TimelineGeometry.laneHeight(rows: 2)])
        #expect(layout(starts, width: 20_000).laneHeights == [TimelineGeometry.laneHeight])   // wide enough to sit side by side
    }

    @Test func aLaterLaneMovesDownUnderAStackedOne() {
        let recordings = [0.0, 60, 120].enumerated().map { i, t in
            CatalogRecording(file: "a\(i).flac", start: at(19).addingTimeInterval(t), seconds: 20, frequencyHz: 7_000_000,
                             mode: "LSB", auto: true, heard: true, inProgress: false, laneID: "7000000 LSB")
        } + [CatalogRecording(file: "b.flac", start: at(19), seconds: 20, frequencyHz: 11_175_000, mode: "USB", auto: true,
                              heard: true, inProgress: false, laneID: "11175000 USB")]
        let lanes = [CatalogLane(id: "7000000 LSB", frequencyHz: 7_000_000, mode: "LSB", title: "7.000 MHz LSB"),
                     CatalogLane(id: "11175000 USB", frequencyHz: 11_175_000, mode: "USB", title: "11.175 MHz USB")]
        let l = TimelineLayout(dayStart: Self.day, width: 1100, recordings: recordings, lanes: lanes, pops: [], selection: nil)
        #expect(l.laneTops == [DayTimelineView.topInset, DayTimelineView.topInset + TimelineGeometry.laneHeight(rows: 3)])
        let b = try! #require(l.settled.first { $0.recording.file == "b.flac" })
        #expect(b.rect.minY == l.laneTops[1] + (TimelineGeometry.laneHeight - TimelineGeometry.markerHeight) / 2)
        #expect(l.lanesBottom == l.laneTops[1] + TimelineGeometry.laneHeight)
    }

    @Test func theLiveMarkerGrowsWithoutMovingAnything() {
        // Finished at 19:00, live from 19:01: stacked under it. Its row is held to the end of the day.
        let l = layout([68_400, 68_460], seconds: 0.2, live: 1)
        let live = try! #require(l.live.first)
        let settled = try! #require(l.settled.first)
        #expect(live.rect.minY > settled.rect.minY)
        let grown = try! #require(l.live(at: 1800).first)
        #expect(grown.rect.minY == live.rect.minY)
        #expect(grown.rect.width > live.rect.width)
        #expect(grown.recording.seconds == 1800)
        // The click and the hover find it at its length now.
        let farRight = CGPoint(x: grown.rect.maxX - 2, y: grown.rect.midY)
        #expect(l.marker(at: farRight, selectableOnly: false, liveSeconds: 1800)?.recording.file == "r1.flac")
        #expect(l.marker(at: farRight, selectableOnly: false, liveSeconds: nil)?.recording.file == nil)
    }

    @Test func nothingStacksBeforeTheWidthIsKnown() {
        let l = TimelineLayout(dayStart: Self.day, width: 0, recordings: layout([0, 60, 120]).settled.map(\.recording),
                               lanes: layout([0]).lanes, pops: [], selection: nil)
        #expect(l.laneHeights == [TimelineGeometry.laneHeight])
    }

    @Test func clockFormat() {
        #expect(RecordingsFormat.clock(at(7, 48, 12.46)) == "07:48:12.4Z")
        #expect(RecordingsFormat.clock(at(23, 59, 59.99)) == "23:59:59.9Z")
        #expect(RecordingsFormat.clock(at(0)) == "00:00:00.0Z")
        #expect(RecordingsFormat.clock(at(18, 32, 19.4)) == "18:32:19.4Z")
        #expect(RecordingsFormat.time(at(18, 32, 19.9)) == "18:32:19Z")
    }

    @Test func lengthFormat() {
        #expect(RecordingsFormat.length(7.8) == "7.8 s")
        #expect(RecordingsFormat.length(48) == "48 s")
        #expect(RecordingsFormat.length(227) == "3 min 47 s")
        #expect(RecordingsFormat.length(4320) == "1 h 12 min")
        #expect(RecordingsFormat.length(1e300) == "277777777 h 47 min")   // a damaged log line: no trap
        #expect(RecordingsFormat.length(-.infinity) == "0.0 s")
    }

    @Test func dayTitleFormat() {
        #expect(RecordingsFormat.dayTitle(Self.day) == "Tue 27 Oct 2026 UTC")
    }

    // MARK: Waveform zoom

    @Test func wholeFileAtScaleOne() {
        let zoom = WaveformZoom()
        for playhead in [0.0, 37, 100] {
            #expect(zoom.visibleRange(duration: 100, playhead: playhead) == 0...100)
        }
    }

    @Test func zoomCentresOnThePlayhead() {
        let zoom = WaveformZoom(scale: 10)
        #expect(zoom.visibleRange(duration: 100, playhead: 50) == 45...55)
    }

    @Test func zoomStaysInsideTheFile() {
        let zoom = WaveformZoom(scale: 10)
        #expect(zoom.visibleRange(duration: 100, playhead: 1) == 0...10)
        #expect(zoom.visibleRange(duration: 100, playhead: 99) == 90...100)
    }

    @Test func xMapsToSeconds() {
        let zoom = WaveformZoom(scale: 10)
        #expect(zoom.seconds(atX: 0, width: 1000, duration: 100, playhead: 50) == 45)
        #expect(zoom.seconds(atX: 500, width: 1000, duration: 100, playhead: 50) == 50)
        #expect(zoom.seconds(atX: 1000, width: 1000, duration: 100, playhead: 50) == 55)
    }

    @Test func zoomIsClamped() {
        var zoom = WaveformZoom()
        zoom.zoom(by: 0.1)
        #expect(zoom.scale == 1)
        zoom.zoom(by: 1e6)
        #expect(zoom.scale == 600)
        #expect(WaveformZoom.maxScale == 600)
    }

    @Test func envelopeFindsTheLoudestBinInAnyRange() {
        let bins = (0..<1000).map { UInt8(truncatingIfNeeded: ($0 * 37 + 11) % 251) }
        let envelope = PeakEnvelope(WaveformPeaks(sampleRate: 48_000, frames: 480_000, peaks: bins))
        #expect(envelope.top == bins.max())
        #expect(envelope.duration == 10)
        for range in [0..<1, 0..<1000, 3..<4, 5..<517, 511..<513, 640..<1000, 999..<1000, 998..<2000, 1000..<1001] {
            let clipped = range.clamped(to: 0..<1000)
            #expect(envelope.peak(bins: range) == (clipped.isEmpty ? 0 : bins[clipped].max()), "bins \(range)")
        }
    }

    @Test @MainActor func jumpChipTitles() {
        #expect(RecordingPlayer.jumpSizes.map(PlayerPanel.jumpTitle) == ["0.1 s", "0.5 s", "1 s", "5 s", "30 s", "5 min"])
    }

    // MARK: What the waveform shows

    @Test func unreadablePeaksShowCantPlayAndBlockPlay() {
        // AVAudioPlayer opened the file, but its peaks could not be read: it counts as unplayable.
        let d = WaveformDisplay.decide(loaded: true, hasEnvelope: false, loadError: nil, peaksFailed: true, duration: 168)
        #expect(d.message == "Can't play this file")
        #expect(!d.drawsPeaks && !d.seekable && !d.playable)
    }

    @Test func playerLoadErrorShowsCantPlayAndBlocksPlay() {
        // The player could not open the file.
        let open = WaveformDisplay.decide(loaded: true, hasEnvelope: true, loadError: "Can't play this file", peaksFailed: false,
                                          duration: 0)
        #expect(open.message == "Can't play this file")
        #expect(!open.drawsPeaks && !open.seekable && !open.playable)
        // It stopped decoding mid-play: the length is known and the peaks were read, and still it does not play.
        let midPlay = WaveformDisplay.decide(loaded: true, hasEnvelope: true, loadError: "Can't play this file",
                                             peaksFailed: false, duration: 168)
        #expect(midPlay.message == "Can't play this file")
        #expect(!midPlay.drawsPeaks && !midPlay.seekable && !midPlay.playable)
    }

    @Test func readableFileDrawsSeeksAndPlays() {
        let ready = WaveformDisplay.decide(loaded: true, hasEnvelope: true, loadError: nil, peaksFailed: false, duration: 168)
        #expect(ready == WaveformDisplay(drawsPeaks: true, message: nil, seekable: true, playable: true))
        // Peaks still loading: it plays and seeks meanwhile, with nothing drawn yet.
        let loading = WaveformDisplay.decide(loaded: true, hasEnvelope: false, loadError: nil, peaksFailed: false, duration: 168)
        #expect(loading == WaveformDisplay(drawsPeaks: false, message: nil, seekable: true, playable: true))
    }

    // MARK: The Recordings button's badge

    @Test func badgeText() {
        #expect(RecordingsBadge.text(-1) == nil)
        #expect(RecordingsBadge.text(0) == nil)
        #expect(RecordingsBadge.text(1) == "1")
        #expect(RecordingsBadge.text(7) == "7")
        #expect(RecordingsBadge.text(99) == "99")
        #expect(RecordingsBadge.text(100) == "99+")
        #expect(RecordingsBadge.text(12_345) == "99+")
    }
}
