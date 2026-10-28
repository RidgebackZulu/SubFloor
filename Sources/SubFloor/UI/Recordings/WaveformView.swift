import AppKit
import Recording
import SwiftUI

/// A recording's peaks, ready to draw at any zoom: the 10 ms bins, and above them each level of maxima over
/// twice as many bins as the one below. A pixel column then takes a handful of lookups however many bins it
/// covers, so redrawing the whole width costs the same for 9 s and for 1.5 h, which matters when the view
/// follows the playhead and redraws with every tick. Built off the main actor; immutable after.
final class PeakEnvelope: Sendable {
    /// `levels[0]` is the peaks; `levels[k][j]` is the loudest of bins `j << k ..< (j + 1) << k`.
    private let levels: [[UInt8]]
    /// The file's largest peak, which the drawing scales to.
    let top: UInt8
    /// The peaks' own length, for before the player has opened the file.
    let duration: Double

    var binCount: Int { levels[0].count }

    init(_ peaks: WaveformPeaks) {
        var levels = [peaks.peaks]
        while let below = levels.last, below.count > 1 {
            levels.append(stride(from: 0, to: below.count, by: 2).map { j in
                j + 1 < below.count ? max(below[j], below[j + 1]) : below[j]
            })
        }
        self.levels = levels
        top = levels.last?.first ?? 0
        duration = peaks.duration
    }

    /// The loudest bin in `range`, 0 for an empty one. Walks up the levels in aligned blocks that fit inside
    /// the range, so it is exact, not smeared over the neighbouring columns.
    func peak(bins range: Range<Int>) -> UInt8 {
        var a = max(range.lowerBound, 0)
        let b = min(range.upperBound, binCount)
        var loudest: UInt8 = 0
        while a < b {
            var level = 0
            while level + 1 < levels.count, a & ((1 << (level + 1)) - 1) == 0, a + (1 << (level + 1)) <= b { level += 1 }
            loudest = max(loudest, levels[level][a >> level])
            a += 1 << level
        }
        return loudest
    }
}

/// The selected recording's loudness, mirrored about the centre line, with the playhead over it. Click or drag
/// to seek; pinch or ⌘-scroll to zoom.
///
/// Two layers, so the 30 Hz playhead never redraws the peaks by itself: the peaks are an equatable `Canvas` over
/// the visible range, which at the whole-file zoom does not move while playing; the playhead is one thin
/// rectangle on top. Zoomed in, the range follows the playhead and the peaks redraw with it, which the
/// envelope keeps to a few lookups a column.
struct WaveformView: View {
    static let height: CGFloat = 120

    /// Nil while the peaks load, or when the file cannot be read: nothing is drawn.
    let envelope: PeakEnvelope?
    let loading: Bool
    let color: Color
    /// The file's length in seconds; 0 when nothing is loaded.
    let duration: Double
    /// Seconds into the file.
    let position: Double
    @Binding var zoom: WaveformZoom
    /// Nil when the file cannot be played: then a click does nothing.
    var onSeek: ((Double) -> Void)?

    @State private var width: CGFloat = 0
    /// The playhead when a drag began. Zoomed in, the range holds still under the mouse until the drag ends,
    /// rather than sliding away as the playhead follows it.
    @State private var dragAnchor: Double?
    @State private var lastMagnification: CGFloat?

    var body: some View {
        let range = zoom.visibleRange(duration: duration, playhead: dragAnchor ?? position)
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8).fill(RecordingsTheme.background)
            if let envelope {
                WaveformCanvas(envelope: envelope, range: range, color: color).equatable()
            }
            if loading { LoadingShimmer(color: color) }
            if duration > 0, range.upperBound > range.lowerBound, range.contains(position) {
                let x = CGFloat((position - range.lowerBound) / (range.upperBound - range.lowerBound)) * width
                Rectangle().fill(.white)
                    .frame(width: 1.5)
                    .shadow(color: .white.opacity(0.5), radius: 2)
                    .offset(x: min(max(x - 0.75, 0), max(width - 1.5, 0)))
                    .allowsHitTesting(false)
            }
        }
        .frame(height: Self.height)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .contentShape(Rectangle())
        .gesture(scrub)
        .simultaneousGesture(pinch)
        .background(CommandScrollZoom { zoom.zoom(by: $0) })
        .pointerStyle(onSeek == nil ? nil : .columnResize)
        .accessibilityElement()
        .accessibilityLabel("Waveform")
        .accessibilityValue(zoom.scale > 1 ? String(format: "Zoomed %.0f times", zoom.scale) : "Whole recording")
    }

    /// A click seeks to the point under it; a drag keeps seeking, and playing carries on from wherever it is let go.
    private var scrub: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { drag in
                guard let onSeek, duration > 0 else { return }
                let anchor = dragAnchor ?? position
                if dragAnchor == nil { dragAnchor = anchor }
                onSeek(zoom.seconds(atX: drag.location.x, width: width, duration: duration, playhead: anchor))
            }
            .onEnded { _ in dragAnchor = nil }
    }

    private var pinch: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                zoom.zoom(by: Double(value.magnification / (lastMagnification ?? 1)))
                lastMagnification = value.magnification
            }
            .onEnded { _ in lastMagnification = nil }
    }
}

/// The peaks across the visible range, one column a point: lane colour where there is signal, a grey flat line
/// where the file is silent (the squelch was shut). Scaled to the file's own loudest peak, so a recording made
/// at −17 dBFS fills the height like one at full scale.
private struct WaveformCanvas: View, Equatable {
    let envelope: PeakEnvelope
    let range: ClosedRange<Double>
    let color: Color

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.envelope === b.envelope && a.range == b.range && a.color == b.color
    }

    /// The squelched line: the mockup's `#2a3140`.
    private static let squelched = Color(red: 0x2a / 255, green: 0x31 / 255, blue: 0x40 / 255)

    var body: some View {
        Canvas { ctx, size in
            let span = range.upperBound - range.lowerBound
            guard span > 0, size.width >= 1, envelope.binCount > 0 else { return }
            let columns = Int(size.width.rounded(.up))
            let mid = size.height / 2
            let reach = mid - 6                                  // a little air above the loudest peak
            let binsPerSecond = Double(WaveformPeaks.binsPerSecond)
            let secondsPerColumn = span / Double(columns)
            var signal = Path(), silence = Path()
            for i in 0..<columns {
                let t0 = range.lowerBound + Double(i) * secondsPerColumn
                let first = Int((t0 * binsPerSecond).rounded(.down))
                guard first < envelope.binCount else { break }   // past the peaks' end: nothing there to draw
                let last = max(first + 1, Int(((t0 + secondsPerColumn) * binsPerSecond).rounded(.up)))
                let peak = envelope.peak(bins: first..<last)
                let x = CGFloat(i)
                if peak == 0 || envelope.top == 0 {
                    silence.addRect(CGRect(x: x, y: mid - 1, width: 1, height: 2))
                } else {
                    let h = max(1, CGFloat(peak) / CGFloat(envelope.top) * reach)
                    signal.addRect(CGRect(x: x, y: mid - h, width: 1, height: 2 * h))
                }
            }
            ctx.fill(silence, with: .color(Self.squelched))
            ctx.fill(signal, with: .color(color.opacity(0.85)))
        }
        .allowsHitTesting(false)
    }
}

/// While the peaks load (a long file read for the first time takes a few seconds): a thin band of the lane
/// colour sweeping along the centre line.
private struct LoadingShimmer: View {
    let color: Color
    @State private var phase: CGFloat = -0.3

    var body: some View {
        GeometryReader { geo in
            Capsule()
                .fill(LinearGradient(colors: [color.opacity(0), color.opacity(0.7), color.opacity(0)],
                                     startPoint: .leading, endPoint: .trailing))
                .frame(width: geo.size.width * 0.3, height: 2)
                .offset(x: phase * geo.size.width, y: geo.size.height / 2 - 1)
        }
        .background(alignment: .leading) {
            Rectangle().fill(color.opacity(0.12)).frame(height: 1)
        }
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) { phase = 1 }
        }
    }
}

/// ⌘-scroll over the waveform zooms it. SwiftUI has no scroll-wheel gesture, so a local event monitor watches
/// the scroll wheel and takes only ⌘-scrolls over this view; every other scroll goes on to the window's scroll
/// view as usual.
private struct CommandScrollZoom: NSViewRepresentable {
    let onZoom: (Double) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = Transparent()
        context.coordinator.view = view
        context.coordinator.onZoom = onZoom
        context.coordinator.start()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onZoom = onZoom
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Only a place to measure from: clicks go through it to the waveform.
    final class Transparent: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    @MainActor final class Coordinator {
        weak var view: NSView?
        var onZoom: (Double) -> Void = { _ in }
        private var monitor: Any?

        func start() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                let taken = MainActor.assumeIsolated { self?.handle(event) ?? false }
                return taken ? nil : event
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        private func handle(_ event: NSEvent) -> Bool {
            guard event.modifierFlags.contains(.command), let view, let window = view.window, event.window === window,
                  view.bounds.contains(view.convert(event.locationInWindow, from: nil))
            else { return false }
            // A positive delta zooms in, a negative one out. A trackpad gives points, a wheel gives lines.
            let delta = event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.01 : 0.1)
            if delta != 0 { onZoom(exp(Double(delta))) }
            return true
        }
    }
}
