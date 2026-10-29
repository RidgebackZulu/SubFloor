import Recording
import SwiftUI

/// One UTC day in lanes: a lane per frequency and mode, each recording a glowing pill as long as it ran, a
/// faint row of the squelch pops that were too short to keep, and the now line on today's view. Pills that
/// would touch are stacked in rows within their lane, so each stays whole, hoverable and clickable.
///
/// Three layers, so the expensive one is drawn only when what it shows changes:
/// - the day itself, one `Canvas` over a value `TimelineLayout`, redrawn only when the finished recordings,
///   the pops, the selection or the width change;
/// - the live layer: the recording in progress and the now line, so neither the live-length poll nor the
///   1 s tick redraws the day. The live length comes in as `liveSeconds`, read only there, so its growth
///   does not even rebuild the layout;
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
    /// The recording in progress's length now, or nil to draw it as long as `recordings` says. Read only by
    /// the live layer and the hover, so the 5 Hz growth redraws one marker.
    var liveSeconds: @MainActor () -> Double? = { nil }
    /// The transcript badge of each recording that has one, by file.
    var marks: [String: TranscriptMark] = [:]
    /// Recordings drawn faded because a search leaves them out.
    var dimmed: Set<String> = []
    /// Whether the context menu's Transcribe can do anything (a key is saved and transcription is on).
    var canTranscribe = false
    /// The context menu's Transcribe or Transcribe Again, with the recording's file.
    var onTranscribe: (String) -> Void = { _ in }

    @State private var width: CGFloat = 0

    /// The height the view needs when no lane stacks its markers. A day with no recordings keeps one empty
    /// lane, which says so. The view sets its own height, which can be more: `TimelineLayout.height`.
    static func height(lanes: Int) -> CGFloat {
        topInset + CGFloat(max(lanes, 1)) * TimelineGeometry.laneHeight + TimelineGeometry.popRowHeight + hourLabelHeight
    }

    var body: some View {
        // Built once per change of what is shown (or of the width), never per mouse move or per draw.
        let layout = TimelineLayout(dayStart: dayStart, width: width, recordings: recordings, lanes: lanes, pops: pops,
                                    selection: selection, marks: marks, dimmed: dimmed)
        ZStack(alignment: .topLeading) {
            TimelineCanvas(layout: layout).equatable()
            if now != nil || !layout.live.isEmpty {
                LiveLayer(layout: layout, liveSeconds: liveSeconds, nowX: now.map(layout.x(for:)))
            }
            TimelineHoverLayer(layout: layout, liveSeconds: liveSeconds, canTranscribe: canTranscribe,
                               onSelect: onSelect, onTranscribe: onTranscribe)
        }
        .frame(height: layout.height, alignment: .topLeading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .accessibilityElement()
        .accessibilityLabel("Recordings on \(RecordingsFormat.dayTitle(dayStart))")
        .accessibilityValue("\(recordings.count) recordings, \(pops.count) pops")
    }

    /// `18:32:19Z · 7.8 s · 11.175 MHz USB`, then `voice`, `possible noise` or `couldn't transcribe: <reason>`
    /// for a recording with a transcript mark. The length is left out until it is known.
    static func hoverText(_ r: CatalogRecording, mark: TranscriptMark? = nil) -> String {
        var parts = [RecordingsFormat.time(r.start)]
        if let seconds = r.seconds { parts.append(RecordingsFormat.length(seconds)) }
        parts.append(RecordingsCatalog.laneTitle(frequencyHz: r.frequencyHz, mode: r.mode))
        if r.inProgress { parts.append("recording") }
        switch mark {
        case .voice?: parts.append("voice")
        case .possibleNoise?: parts.append("possible noise")
        case .failed(let reason)?: parts.append("couldn't transcribe: \(reason)")
        case nil: break
        }
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
    /// Each lane's top and height: taller than one row where its markers are stacked.
    let laneTops: [CGFloat]
    let laneHeights: [CGFloat]
    let popXs: [CGFloat]
    let selection: String?
    /// The transcript badges and the faded recordings, which the canvas draws, so a change redraws it.
    let marks: [String: TranscriptMark]
    let dimmed: Set<String>
    /// The finished recordings, in drawing order: heard under unheard, and the selected one on top, so the
    /// one the listener picked is never hidden.
    let settled: [Marker]
    /// Recordings in progress, as long as they were when they began: `live(at:)` gives them their length now.
    /// Drawn over the day on their own layer.
    let live: [Marker]

    /// Every marker, bottom to top, for hit testing, with the recording in progress at `liveSeconds`.
    func markers(liveSeconds: Double?) -> [Marker] { settled + live(at: liveSeconds) }

    init(dayStart: Date, width: CGFloat, recordings: [CatalogRecording], lanes: [CatalogLane], pops: [CatalogPop],
         selection: String?, marks: [String: TranscriptMark] = [:], dimmed: Set<String> = []) {
        self.dayStart = dayStart
        self.width = width
        self.lanes = lanes
        self.selection = selection
        self.marks = marks
        self.dimmed = dimmed
        let g = TimelineGeometry(dayStart: dayStart, width: Self.plotWidth(width))
        popXs = pops.map { DayTimelineView.labelColumn + g.x(for: $0.at) }
        let laneIndex = Dictionary(lanes.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })

        // Rows within each lane. A recording in progress keeps its row to the end of the day, since it grows
        // there, so its length never moves another marker. Until the view has measured its width every pill
        // sits at 0, so nothing is stacked: that would flash lanes as deep as the day is busy.
        let measured = width > DayTimelineView.labelColumn + DayTimelineView.trailingInset
        var row = [Int](repeating: 0, count: recordings.count)
        var depth = [Int](repeating: 1, count: lanes.count)
        if measured {
            var byLane: [Int: [Int]] = [:]
            for (i, r) in recordings.enumerated() { if let lane = laneIndex[r.laneID] { byLane[lane, default: []].append(i) } }
            for (lane, members) in byLane {
                let spans = members.map { i in
                    let r = recordings[i], span = g.markerSpan(start: r.start, seconds: r.seconds ?? 0)
                    return r.inProgress ? span.lowerBound...g.width : span
                }
                let rows = TimelineGeometry.rows(for: spans)
                for (i, r) in zip(members, rows) { row[i] = r }
                depth[lane] = (rows.max() ?? 0) + 1
            }
        }
        laneHeights = depth.map { TimelineGeometry.laneHeight(rows: $0) }
        var top = DayTimelineView.topInset
        laneTops = laneHeights.map { h in defer { top += h }; return top }

        func rank(_ r: CatalogRecording) -> Int {
            r.file == selection ? 2 : r.heard ? 0 : 1
        }
        let tops = laneTops
        let all: [Marker] = recordings.enumerated()
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .compactMap { i, r in
                guard let lane = laneIndex[r.laneID] else { return nil }
                let rect = g.markerRect(start: r.start, seconds: r.seconds ?? 0, laneTop: tops[lane], row: row[i])
                    .offsetBy(dx: DayTimelineView.labelColumn, dy: 0)
                return Marker(recording: r, rect: rect, lane: lane)
            }
        settled = all.filter { !$0.recording.inProgress }
        live = all.filter(\.recording.inProgress)
    }

    var geometry: TimelineGeometry { TimelineGeometry(dayStart: dayStart, width: Self.plotWidth(width)) }

    func x(for date: Date) -> CGFloat { DayTimelineView.labelColumn + geometry.x(for: date) }

    var lanesBottom: CGFloat {
        guard let top = laneTops.last, let height = laneHeights.last else {
            return DayTimelineView.topInset + TimelineGeometry.laneHeight   // the one empty lane
        }
        return top + height
    }
    var gridBottom: CGFloat { lanesBottom + TimelineGeometry.popRowHeight }
    /// The whole view's height, hour labels included.
    var height: CGFloat { gridBottom + DayTimelineView.hourLabelHeight }

    /// The recordings in progress at `seconds` long (nil: as they began), on the rows they were given.
    func live(at seconds: Double?) -> [Marker] {
        guard let seconds else { return live }
        let g = geometry
        return live.map { m in
            var m = m
            m.recording.seconds = seconds
            let span = g.markerSpan(start: m.recording.start, seconds: seconds)
            m.rect = CGRect(x: DayTimelineView.labelColumn + span.lowerBound, y: m.rect.minY,
                            width: span.upperBound - span.lowerBound, height: m.rect.height)
            return m
        }
    }

    /// The marker under `point`; a recording in progress only when `selectableOnly` is false.
    func marker(at point: CGPoint, selectableOnly: Bool, liveSeconds: Double? = nil) -> Marker? {
        let candidates = selectableOnly ? settled : markers(liveSeconds: liveSeconds)
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
        return l.dayStart == r.dayStart && l.width == r.width && l.lanes == r.lanes && l.laneTops == r.laneTops
            && l.laneHeights == r.laneHeights && l.popXs == r.popXs && l.selection == r.selection && l.settled == r.settled
            && l.marks == r.marks && l.dimmed == r.dimmed
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
            let strip = CGRect(x: x0, y: layout.laneTops[i] + 3, width: g.width, height: layout.laneHeights[i] - 6)
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
            MarkerPaint.draw(marker, selected: selected, mark: layout.marks[marker.recording.file],
                             dimmed: layout.dimmed.contains(marker.recording.file), in: ctx)
        }
    }

    /// The soft glow under every marker but the selected one: a blurred copy of the pills. Two blurred layers
    /// for the whole day (the pills, and the unheard dots) rather than one or two per marker, so a busy day
    /// costs two blurs, not hundreds. Inside them the pills go as one path per lane and brightness, which
    /// measured twice as fast as a fill per pill. (The pops are the opposite: a thousand overlapping dots in
    /// one path fill ten times slower than one by one.)
    private func drawGlows(in ctx: GraphicsContext) {
        var heard: [Int: Path] = [:], bright: [Int: Path] = [:], dots: [Int: Path] = [:]
        for m in layout.settled where m.recording.file != layout.selection && !layout.dimmed.contains(m.recording.file) {
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
enum MarkerPaint {
    /// The unheard dot, above the pill's leading edge.
    static func dotRect(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: rect.minY - 6.5, width: 4.5, height: 4.5)
    }

    /// The transcript badge, above the pill's trailing edge; right of the unheard dot on a pill too short to
    /// keep them apart.
    static func badgeRect(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.width < 12 ? rect.minX + 6 : rect.maxX - 4.5, y: rect.minY - 6.5, width: 4.5, height: 4.5)
    }

    /// The badge's green: voice was heard.
    static let voiceGreen = Color(red: 0x4d / 255, green: 0xdb / 255, blue: 0x78 / 255)

    /// - Parameters:
    ///   - mark: the recording's transcript badge, nil for none (a recording in progress never has one).
    ///   - dimmed: a search leaves it out: drawn at 0.2 opacity, over the heard 0.6.
    static func draw(_ marker: TimelineLayout.Marker, selected: Bool, mark: TranscriptMark? = nil, dimmed: Bool = false,
                     in ctx: GraphicsContext) {
        let r = marker.recording, rect = marker.rect, c = RecordingsTheme.lane(marker.lane)
        let pill = Path(roundedRect: rect, cornerRadius: min(5, rect.width / 2))
        var ctx = ctx
        if dimmed {
            ctx.opacity = 0.2
        } else if r.heard && !r.inProgress && !selected {
            ctx.opacity = 0.6
        }

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
        if !r.inProgress, let mark { drawBadge(mark, rect: rect, in: ctx) }
    }

    /// Green dot for voice, a grey ring for possible noise, an orange dot for a failure.
    private static func drawBadge(_ mark: TranscriptMark, rect: CGRect, in ctx: GraphicsContext) {
        let badge = badgeRect(rect)
        switch mark {
        case .voice: ctx.fill(Path(ellipseIn: badge), with: .color(voiceGreen))
        case .possibleNoise: ctx.stroke(Path(ellipseIn: badge.insetBy(dx: 0.5, dy: 0.5)), with: .color(.gray), lineWidth: 1)
        case .failed: ctx.fill(Path(ellipseIn: badge), with: .color(.orange))
        }
    }
}

/// The recording in progress and the now line, over the day. They change every poll and every second, so
/// they are drawn here, on their own, where redrawing costs one marker and one line.
private struct LiveLayer: View {
    let layout: TimelineLayout
    let liveSeconds: @MainActor () -> Double?
    /// The now line's x, on today's view only.
    let nowX: CGFloat?

    var body: some View {
        // Read here, in this layer's body, so only this layer follows the live length.
        let markers = layout.live(at: liveSeconds())
        let bottom = layout.gridBottom
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
    /// Read when the mouse moves, not in `body`, so the live length does not redraw this layer.
    let liveSeconds: @MainActor () -> Double?
    let canTranscribe: Bool
    let onSelect: (CatalogRecording?) -> Void
    let onTranscribe: (String) -> Void

    @State private var hover: Hover?

    private struct Hover: Equatable {
        var point: CGPoint, text: String
        /// The finished recording under the pointer, which the context menu is for; nil over one in progress.
        var file: String?
    }

    var body: some View {
        let right = (hover?.point.x ?? 0) > layout.width / 2
        Color.clear
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let point):
                    let next = layout.marker(at: point, selectableOnly: false, liveSeconds: liveSeconds())
                        .map { m in
                            let file = m.recording.file
                            return Hover(point: point, text: DayTimelineView.hoverText(m.recording, mark: layout.marks[file]),
                                         file: m.recording.inProgress ? nil : file)
                        }
                    if next != hover { hover = next }
                case .ended:
                    hover = nil
                }
            }
            .onTapGesture(coordinateSpace: .local) { point in
                // A recording in progress is still being written: a click on it does nothing, rather than
                // dropping the selection the listener has.
                if let hit = layout.marker(at: point, selectableOnly: false, liveSeconds: liveSeconds()),
                   hit.recording.inProgress { return }
                onSelect(layout.marker(at: point, selectableOnly: true)?.recording)
            }
            .overlay(alignment: right ? .topTrailing : .topLeading) {
                if let hover { label(hover, right: right) }
            }
            .contextMenu {
                // Built when the menu opens, from the recording the pointer is over; over nothing, no menu.
                if let file = hover?.file {
                    let transcribed = layout.marks[file].map { if case .failed = $0 { false } else { true } } ?? false
                    Button(transcribed ? "Transcribe Again" : "Transcribe") { onTranscribe(file) }
                        .disabled(!canTranscribe)
                }
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
