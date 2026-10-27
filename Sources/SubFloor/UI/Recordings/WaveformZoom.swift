import CoreGraphics

/// How much of a recording the waveform shows. At 1 the whole file fits the width; zoomed in, the window
/// follows the playhead, so what is playing stays in view, but never runs past either end of the file, so the
/// width is always filled with recording. Kept apart from the view so the mapping is testable without a window.
struct WaveformZoom: Equatable {
    static let maxScale: Double = 600     // a 1.5 h file zooms down to ~9 s across
    var scale: Double = 1                 // 1 = whole file

    /// The visible span in seconds, centred on `playhead` but kept inside 0...duration.
    func visibleRange(duration: Double, playhead: Double) -> ClosedRange<Double> {
        guard duration > 0, duration.isFinite else { return 0...0 }
        let span = duration / min(max(scale, 1), Self.maxScale)
        let centred = (playhead.isFinite ? playhead : 0) - span / 2
        let lower = min(max(centred, 0), duration - span)
        return lower...(lower + span)
    }

    /// The second of the file under `x` (0 at the leading edge), with x kept on the view.
    func seconds(atX x: CGFloat, width: CGFloat, duration: Double, playhead: Double) -> Double {
        let range = visibleRange(duration: duration, playhead: playhead)
        guard width > 0 else { return range.lowerBound }
        let fraction = min(max(Double(x / width), 0), 1)
        return range.lowerBound + fraction * (range.upperBound - range.lowerBound)
    }

    /// Clamped to 1...maxScale: no further out than the whole file, and in to about a 10 ms bin a point on the
    /// longest recordings.
    mutating func zoom(by factor: Double) {
        guard factor.isFinite, factor > 0 else { return }
        scale = min(max(scale * factor, 1), Self.maxScale)
    }
}
