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
        let rect = g.markerRect(start: at(7, 48, 12), seconds: 20, lane: 0)
        #expect(rect.width == TimelineGeometry.minMarkerWidth)
        #expect(rect.width == 6)
    }

    @Test func clipsCrossingMidnightAreClipped() {
        let g = TimelineGeometry(dayStart: Self.day, width: 1200)
        let rect = g.markerRect(start: at(23), seconds: 7200, lane: 1)
        #expect(rect.maxX == 1200)
        #expect(rect.minX == 1150)
        // A short clip in the last seconds keeps its width inside the day rather than being cut to nothing.
        let late = g.markerRect(start: at(23, 59, 59), seconds: 20, lane: 0)
        #expect(late.maxX == 1200)
        #expect(late.width == 6)
    }

    @Test func hitTestFindsTheMarker() {
        let g = TimelineGeometry(dayStart: Self.day, width: 1200)
        let a = g.markerRect(start: at(6), seconds: 1800, lane: 0)
        let b = g.markerRect(start: at(12), seconds: 1800, lane: 1)
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
        let under = g.markerRect(start: at(6), seconds: 3600, lane: 0)
        let over = g.markerRect(start: at(6, 30), seconds: 3600, lane: 0)
        let markers = [(file: "under.flac", rect: under), (file: "over.flac", rect: over)]
        #expect(g.recording(at: CGPoint(x: over.minX + 1, y: over.midY), in: markers) == "over.flac")
        // Inside one marker and within the slop of the next: the marker under the pointer wins.
        let left = g.markerRect(start: at(9), seconds: 600, lane: 0)
        let right = CGRect(x: left.maxX + 2, y: left.minY, width: 20, height: left.height)
        let pair = [(file: "left.flac", rect: left), (file: "right.flac", rect: right)]
        #expect(g.recording(at: CGPoint(x: left.maxX - 1, y: left.midY), in: pair) == "left.flac")
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
}
