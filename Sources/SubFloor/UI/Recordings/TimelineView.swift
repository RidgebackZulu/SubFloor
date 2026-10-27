import Recording
import SwiftUI

/// One UTC day in lanes: a lane per frequency and mode, each recording a glowing pill as long as it ran, a
/// faint row of the squelch pops that were too short to keep, and the now line on today's view.
///
/// Three layers, so the expensive one is drawn only when what it shows changes:
/// - the day itself, one `Canvas` over a value `TimelineLayout`, redrawn only when the finished recordings,
///   the pops, the selection or the width change;
/// - the live layer: the recording in progress and the now line, so neither the live-length poll nor the
///   1 s tick redraws the day;
/// - hover and clicks, with the hover state kept there, so a mouse move does not redraw the day.
///
/// Named `DayTimelineView` because SwiftUI already has a `TimelineView`, which the app uses elsewhere.
/// Everything it shows comes in as values, so it can be drawn from a hand-made catalog.
struct DayTimelineView: View {
    /// The lane titles' column, left of 00:00.
    nonisolated static let labelColumn: CGFloat = 130
    /// Room above the first lane, and right of 24:00 for its hour label.
    nonisolated static let topInset: CGFloat = 8, trailingInset: CGFloat = 20
    nonisolated static let hourLabelHeight: CGFloat = 22

    let dayStart: Date
    let recordings: [CatalogRecording]
    let lanes: [CatalogLane]
    let pops: [CatalogPop]
    var selection: String?
    /// The current time on today's view; nil on any other day, which has no now line.
    var now: Date?
    /// A finished recording was clicked, or nil for a click on empty space.
    var onSelect: (CatalogRecording?) -> Void = { _ in }

    @State private var width: CGFloat = 0

    /// The height the view needs. A day with no recordings keeps one empty lane, which says so.
    static func height(lanes: Int) -> CGFloat {
        topInset + CGFloat(max(lanes, 1)) * TimelineGeometry.laneHeight + TimelineGeometry.popRowHeight + hourLabelHeight
    }

    var body: some View {
        // Built once per change of what is shown (or of the width), never per mouse move or per draw.
        let layout = TimelineLayout(dayStart: dayStart, width: width, recordings: recordings, lanes: lanes, pops: pops,
                                    selection: selection)
        ZStack(alignment: .topLeading) {
            TimelineCanvas(layout: layout).equatable()
            if now != nil || !layout.live.isEmpty {
                LiveLayer(markers: layout.live, nowX: now.map(layout.x(for:)), bottom: layout.gridBottom)
            }
            TimelineHoverLayer(layout: layout, onSelect: onSelect)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .accessibilityElement()
        .accessibilityLabel("Recordings on \(RecordingsFormat.dayTitle(dayStart))")
        .accessibilityValue("\(recordings.count) recordings, \(pops.count) pops")
    }

    /// `18:32:19Z · 7.8 s · 11.175 MHz USB`. The length is left out until it is known.
    static func hoverText(_ r: CatalogRecording) -> String {
        var parts = [RecordingsFormat.time(r.start)]
        if let seconds = r.seconds { parts.append(RecordingsFormat.length(seconds)) }
        parts.append(RecordingsCatalog.laneTitle(frequencyHz: r.frequencyHz, mode: r.mode))
        if r.inProgress { parts.append("recording") }
        return parts.joined(separator: " · ")
    }
}

/// Where everything on the day sits, in view coordinates, as a value, so the canvas can tell when a refresh
/// changed nothing it draws.
struct TimelineLayout: Equatable {
    struct Marker: Equatable {
        var recording: CatalogRecording, rect: CGRect, lane: Int
    }

    let dayStart: Date
    /// The whole view's width; the plot runs from `labelColumn` to `width - trailingInset`.
    let width: CGFloat
    let lanes: [CatalogLane]
    let popXs: [CGFloat]
    let selection: String?
    /// The finished recordings, in drawing order: heard under unheard, and the selected one on top, so the
    /// one the listener picked is never hidden.
    let settled: [Marker]
    /// Recordings in progress, which grow with every poll. Drawn over the day on their own layer.
    let live: [Marker]

    /// Every marker, bottom to top, for hit testing.
    var markers: [Marker] { settled + live }

    init(dayStart: Date, width: CGFloat, recordings: [CatalogRecording], lanes: [CatalogLane], pops: [CatalogPop],
         selection: String?) {
        self.dayStart = dayStart
        self.width = width
        self.lanes = lanes
        self.selection = selection
        let g = TimelineGeometry(dayStart: dayStart, width: Self.plotWidth(width))
        popXs = pops.map { DayTimelineView.labelColumn + g.x(for: $0.at) }
        let laneIndex = Dictionary(lanes.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        func rank(_ r: CatalogRecording) -> Int {
            r.file == selection ? 2 : r.heard ? 0 : 1
        }
        let all: [Marker] = recordings.enumerated()
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .compactMap { _, r in
                guard let lane = laneIndex[r.laneID] else { return nil }
                let rect = g.markerRect(start: r.start, seconds: r.seconds ?? 0, lane: lane)
                    .offsetBy(dx: DayTimelineView.labelColumn, dy: DayTimelineView.topInset)
                return Marker(recording: r, rect: rect, lane: lane)
            }
        settled = all.filter { !$0.recording.inProgress }
        live = all.filter(\.recording.inProgress)
    }

    var geometry: TimelineGeometry { TimelineGeometry(dayStart: dayStart, width: Self.plotWidth(width)) }

    func x(for date: Date) -> CGFloat { DayTimelineView.labelColumn + geometry.x(for: date) }

    var lanesBottom: CGFloat { DayTimelineView.topInset + CGFloat(max(lanes.count, 1)) * TimelineGeometry.laneHeight }
    var gridBottom: CGFloat { lanesBottom + TimelineGeometry.popRowHeight }

    /// The marker under `point`; a recording in progress only when `selectableOnly` is false.
    func marker(at point: CGPoint, selectableOnly: Bool) -> Marker? {
        let candidates = selectableOnly ? markers.filter { !$0.recording.inProgress } : markers
        guard let file = geometry.recording(at: point, in: candidates.map { ($0.recording.file, $0.rect) }) else { return nil }
        return candidates.last { $0.recording.file == file }
    }

    private static func plotWidth(_ width: CGFloat) -> CGFloat {
        max(width - DayTimelineView.labelColumn - DayTimelineView.trailingInset, 1)
    }
}

/// The day: lanes, hour ticks, pops and the finished recordings.
private struct TimelineCanvas: View, Equatable {
    let layout: TimelineLayout

    /// What it draws; the recordings in progress are the live layer's.
    nonisolated static func == (a: Self, b: Self) -> Bool {
        let (l, r) = (a.layout, b.layout)
        return l.dayStart == r.dayStart && l.width == r.width && l.lanes == r.lanes && l.popXs == r.popXs
            && l.selection == r.selection && l.settled == r.settled
    }

    var body: some View {
        Canvas { ctx, _ in draw(in: &ctx) }
    }

    private func draw(in ctx: inout GraphicsContext) {
        let g = layout.geometry
        let x0 = DayTimelineView.labelColumn
        let popsMid = layout.lanesBottom + TimelineGeometry.popRowHeight / 2

        // Lane strips and titles.
        for (i, lane) in layout.lanes.enumerated() {
            let top = DayTimelineView.topInset + CGFloat(i) * TimelineGeometry.laneHeight
            let strip = CGRect(x: x0, y: top + 3, width: g.width, height: TimelineGeometry.laneHeight - 6)
            ctx.fill(Path(roundedRect: strip, cornerRadius: 7), with: .color(RecordingsTheme.panel))
            let mid = strip.midY
            ctx.fill(Path(ellipseIn: CGRect(x: 12, y: mid - 3.5, width: 7, height: 7)), with: .color(RecordingsTheme.lane(i)))
            drawFitted(lane.title, in: &ctx, at: CGPoint(x: 26, y: mid), maxWidth: x0 - 26 - 10)
        }
        if layout.lanes.isEmpty {
            let strip = CGRect(x: x0, y: DayTimelineView.topInset + 3, width: g.width, height: TimelineGeometry.laneHeight - 6)
            ctx.fill(Path(roundedRect: strip, cornerRadius: 7), with: .color(RecordingsTheme.panel.opacity(0.6)))
            ctx.draw(Text("No recordings on this day").font(.system(size: 12)).foregroundStyle(RecordingsTheme.muted),
                     at: CGPoint(x: strip.midX, y: strip.midY))
        }

        // Hour ticks over the strips, stronger every 6 h; labels every 3 h.
        for h in 0...24 {
            let x = x0 + g.x(for: layout.dayStart.addingTimeInterval(Double(h) * 3600))
            var line = Path()
            line.move(to: CGPoint(x: x, y: DayTimelineView.topInset))
            line.addLine(to: CGPoint(x: x, y: layout.gridBottom))
            ctx.stroke(line, with: .color(.white.opacity(h % 6 == 0 ? 0.11 : 0.045)), lineWidth: 1)
            if h % 3 == 0 {
                ctx.draw(Text(String(format: "%02d", h)).font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(RecordingsTheme.muted),
                         at: CGPoint(x: x, y: layout.gridBottom + DayTimelineView.hourLabelHeight / 2 + 1))
            }
        }

        // The pops row: it was listening, even when nothing was worth keeping. A fill per dot: dots this close
        // overlap, and one path of a thousand overlapping dots fills ten times slower.
        let count = layout.popXs.count
        ctx.draw(Text(count == 1 ? "1 pop" : "\(count) pops").font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(RecordingsTheme.muted),
                 at: CGPoint(x: 26, y: popsMid), anchor: .leading)
        for x in layout.popXs {
            ctx.fill(Path(ellipseIn: CGRect(x: x - 1.8, y: popsMid - 1.8, width: 3.6, height: 3.6)), with: .color(.white.opacity(0.25)))
        }

        drawGlows(in: ctx)
        for marker in layout.settled {
            let selected = marker.recording.file == layout.selection
            if selected { drawSelectedGlow(marker, in: ctx) }
            MarkerPaint.draw(marker, selected: selected, in: ctx)
        }
    }

    /// The soft glow under every marker but the selected one: a blurred copy of the pills. Two blurred layers
    /// for the whole day (the pills, and the unheard dots) rather than one or two per marker, so a busy day
    /// costs two blurs, not hundreds. Inside them the pills go as one path per lane and brightness, which
    /// measured twice as fast as a fill per pill. (The pops are the opposite: a thousand overlapping dots in
    /// one path fill ten times slower than one by one.)
    private func drawGlows(in ctx: GraphicsContext) {
        var heard: [Int: Path] = [:], bright: [Int: Path] = [:], dots: [Int: Path] = [:]
        for m in layout.settled where m.recording.file != layout.selection {
            let r = m.recording
            if r.heard {
                heard[m.lane, default: Path()].addRoundedRect(in: m.rect, cornerSize: CGSize(width: 6, height: 6))
            } else {
                bright[m.lane, default: Path()].addRoundedRect(in: m.rect, cornerSize: CGSize(width: 6, height: 6))
            }
            if !r.heard { dots[m.lane, default: Path()].addEllipse(in: MarkerPaint.dotRect(m.rect).insetBy(dx: -1, dy: -1)) }
        }
        ctx.drawLayer { layer in
            layer.addFilter(.blur(radius: 4))
            // Heard: the 0.35 glow at the heard markers' 60% opacity.
            for (lane, path) in heard { layer.fill(path, with: .color(RecordingsTheme.lane(lane).opacity(0.21))) }
            for (lane, path) in bright { layer.fill(path, with: .color(RecordingsTheme.lane(lane).opacity(0.6))) }
        }
        ctx.drawLayer { layer in
            layer.addFilter(.blur(radius: 2))
            for (lane, path) in dots { layer.fill(path, with: .color(RecordingsTheme.lane(lane))) }
        }
    }

    private func drawSelectedGlow(_ m: TimelineLayout.Marker, in ctx: GraphicsContext) {
        ctx.drawLayer { glow in
            glow.addFilter(.blur(radius: 8))
            glow.fill(Path(roundedRect: m.rect.insetBy(dx: -2, dy: -2), cornerRadius: 6),
                      with: .color(RecordingsTheme.lane(m.lane).opacity(0.95)))
        }
    }

    /// A lane title in the label column, a size smaller when a long frequency would run into 00:00.
    private func drawFitted(_ title: String, in ctx: inout GraphicsContext, at point: CGPoint, maxWidth: CGFloat) {
        for size in [11.5, 10.5, 9.5] as [CGFloat] {
            let text = ctx.resolve(Text(title).font(.system(size: size, design: .monospaced)).foregroundStyle(RecordingsTheme.text))
            if text.measure(in: CGSize(width: 1000, height: 100)).width <= maxWidth || size == 9.5 {
                ctx.draw(text, at: point, anchor: .leading)
                return
            }
        }
    }
}

/// How one marker looks, shared by the day canvas and the live layer.
private enum MarkerPaint {
    /// The unheard dot, above the pill's leading edge.
    static func dotRect(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: rect.minY - 6.5, width: 4.5, height: 4.5)
    }

    static func draw(_ marker: TimelineLayout.Marker, selected: Bool, in ctx: GraphicsContext) {
        let r = marker.recording, rect = marker.rect, c = RecordingsTheme.lane(marker.lane)
        let pill = Path(roundedRect: rect, cornerRadius: min(5, rect.width / 2))
        var ctx = ctx
        if r.heard && !r.inProgress && !selected { ctx.opacity = 0.6 }

        if r.inProgress {
            // Striped: still being written, so it cannot be opened yet. One recording at most, so its own layer.
            ctx.fill(pill, with: .color(c.opacity(0.22)))
            ctx.drawLayer { stripes in
                stripes.clip(to: pill)
                var lines = Path()
                var x = rect.minX - rect.height
                while x < rect.maxX {
                    lines.move(to: CGPoint(x: x, y: rect.maxY))
                    lines.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
                    x += 6
                }
                stripes.stroke(lines, with: .color(c.opacity(0.85)), lineWidth: 2.2)
            }
            ctx.stroke(pill, with: .color(c), lineWidth: 1)
        } else if r.auto {
            ctx.fill(pill, with: .linearGradient(Gradient(colors: [c, c.opacity(0.5)]),
                                                 startPoint: CGPoint(x: rect.midX, y: rect.minY),
                                                 endPoint: CGPoint(x: rect.midX, y: rect.maxY)))
        } else {
            // Manual: an outline, so a recording someone started by hand reads apart from what Auto caught.
            let inset = rect.insetBy(dx: 0.75, dy: 0.75)
            ctx.stroke(Path(roundedRect: inset, cornerRadius: min(4.5, inset.width / 2)), with: .color(c), lineWidth: 1.5)
        }

        if selected {
            ctx.stroke(Path(roundedRect: rect.insetBy(dx: -1.5, dy: -1.5), cornerRadius: min(6.5, rect.width / 2 + 1.5)),
                       with: .color(.white), lineWidth: 1.5)
        }
        if !r.heard && !r.inProgress { ctx.fill(Path(ellipseIn: dotRect(rect)), with: .color(c)) }
    }
}

/// The recording in progress and the now line, over the day. They change every poll and every second, so
/// they are drawn here, on their own, where redrawing costs one marker and one line.
private struct LiveLayer: View {
    let markers: [TimelineLayout.Marker]
    /// The now line's x, on today's view only.
    let nowX: CGFloat?
    let bottom: CGFloat

    var body: some View {
        Canvas { ctx, _ in
            for m in markers {
                ctx.drawLayer { glow in
                    glow.addFilter(.blur(radius: 4))
                    glow.fill(Path(roundedRect: m.rect, cornerRadius: 6), with: .color(RecordingsTheme.lane(m.lane).opacity(0.6)))
                }
                MarkerPaint.draw(m, selected: false, in: ctx)
            }
            guard let x = nowX else { return }
            // The 1 pt red line at the current time.
            let top = DayTimelineView.topInset
            var line = Path()
            line.move(to: CGPoint(x: x, y: top - 2))
            line.addLine(to: CGPoint(x: x, y: bottom))
            ctx.drawLayer { glow in
                glow.addFilter(.blur(radius: 3))
                glow.stroke(line, with: .color(RecordingsTheme.now.opacity(0.6)), lineWidth: 2)
            }
            ctx.stroke(line, with: .color(RecordingsTheme.now), lineWidth: 1)
            ctx.fill(Path(ellipseIn: CGRect(x: x - 2.5, y: top - 4.5, width: 5, height: 5)), with: .color(RecordingsTheme.now))
        }
        .allowsHitTesting(false)
    }
}

/// Hover and clicks over the day. The hover state lives here, so moving the mouse redraws only the label.
private struct TimelineHoverLayer: View {
    let layout: TimelineLayout
    let onSelect: (CatalogRecording?) -> Void

    @State private var hover: Hover?

    private struct Hover: Equatable {
        var point: CGPoint, text: String
    }

    var body: some View {
        let right = (hover?.point.x ?? 0) > layout.width / 2
        Color.clear
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let point):
                    let next = layout.marker(at: point, selectableOnly: false)
                        .map { Hover(point: point, text: DayTimelineView.hoverText($0.recording)) }
                    if next != hover { hover = next }
                case .ended:
                    hover = nil
                }
            }
            .onTapGesture(coordinateSpace: .local) { point in
                // A recording in progress is still being written: a click on it does nothing, rather than
                // dropping the selection the listener has.
                if let hit = layout.marker(at: point, selectableOnly: false), hit.recording.inProgress { return }
                onSelect(layout.marker(at: point, selectableOnly: true)?.recording)
            }
            .overlay(alignment: right ? .topTrailing : .topLeading) {
                if let hover { label(hover, right: right) }
            }
    }

    private func label(_ hover: Hover, right: Bool) -> some View {
        Text(hover.text)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(RecordingsTheme.text)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(RecordingsTheme.panel.opacity(0.96)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.white.opacity(0.12)))
            .fixedSize()
            .offset(x: right ? hover.point.x - layout.width - 12 : hover.point.x + 12, y: hover.point.y + 14)
            .allowsHitTesting(false)
    }
}
