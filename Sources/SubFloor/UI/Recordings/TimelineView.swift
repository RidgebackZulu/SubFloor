import Recording
import SwiftUI

/// One UTC day in lanes: a lane per frequency and mode, each recording a glowing pill as long as it ran, a
/// faint row of the squelch pops that were too short to keep, and the now line on today's view. One `Canvas`,
/// so a day of a few hundred recordings is one draw rather than a few hundred views.
///
/// Named `DayTimelineView` because SwiftUI already has a `TimelineView`, which the app uses elsewhere.
/// Everything it shows comes in as values, so it can be drawn from a hand-made catalog.
struct DayTimelineView: View {
    /// The lane titles' column, left of 00:00.
    static let labelColumn: CGFloat = 130
    /// Room above the first lane, and right of 24:00 for its hour label.
    static let topInset: CGFloat = 8, trailingInset: CGFloat = 20
    static let hourLabelHeight: CGFloat = 22

    let dayStart: Date
    let recordings: [CatalogRecording]
    let lanes: [CatalogLane]
    let pops: [CatalogPop]
    var selection: String?
    /// The current time on today's view; nil on any other day, which has no now line.
    var now: Date?
    /// A finished recording was clicked, or nil for a click on empty space.
    var onSelect: (CatalogRecording?) -> Void = { _ in }

    @State private var hover: Hover?
    @State private var width: CGFloat = 0

    private struct Hover: Equatable {
        var point: CGPoint, text: String
    }

    private struct Marker {
        var recording: CatalogRecording, rect: CGRect, color: Color
    }

    /// The height the view needs. A day with no recordings keeps one empty lane, which says so.
    static func height(lanes: Int) -> CGFloat {
        topInset + CGFloat(max(lanes, 1)) * TimelineGeometry.laneHeight + TimelineGeometry.popRowHeight + hourLabelHeight
    }

    var body: some View {
        Canvas { ctx, size in draw(in: &ctx, size: size) }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let point):
                    hover = marker(at: point, selectableOnly: false).map { Hover(point: point, text: Self.hoverText($0.recording)) }
                case .ended:
                    hover = nil
                }
            }
            .onTapGesture(coordinateSpace: .local) { point in
                // A recording in progress is still being written: a click on it does nothing, rather than
                // dropping the selection the listener has.
                if let hit = marker(at: point, selectableOnly: false), hit.recording.inProgress { return }
                onSelect(marker(at: point, selectableOnly: true)?.recording)
            }
            .overlay(alignment: hover.map { $0.point.x > width / 2 } == true ? .topTrailing : .topLeading) {
                if let hover { hoverLabel(hover) }
            }
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

    // MARK: Layout

    private func geometry(_ width: CGFloat) -> TimelineGeometry {
        TimelineGeometry(dayStart: dayStart, width: max(width - Self.labelColumn - Self.trailingInset, 1))
    }

    /// The markers in view coordinates, in drawing order: heard under unheard, the recording in progress over
    /// those, and the selected one on top, so the one the listener picked is never hidden.
    private func markers(width: CGFloat) -> [Marker] {
        let g = geometry(width)
        let laneIndex = Dictionary(lanes.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        func rank(_ r: CatalogRecording) -> Int {
            r.file == selection ? 3 : r.inProgress ? 2 : r.heard ? 0 : 1
        }
        return recordings.enumerated()
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .compactMap { _, r in
                guard let lane = laneIndex[r.laneID] else { return nil }
                let rect = g.markerRect(start: r.start, seconds: r.seconds ?? 0, lane: lane)
                    .offsetBy(dx: Self.labelColumn, dy: Self.topInset)
                return Marker(recording: r, rect: rect, color: RecordingsTheme.lane(lane))
            }
    }

    private func marker(at point: CGPoint, selectableOnly: Bool) -> Marker? {
        let all = markers(width: width).filter { !selectableOnly || !$0.recording.inProgress }
        guard let file = geometry(width).recording(at: point, in: all.map { ($0.recording.file, $0.rect) }) else { return nil }
        return all.last { $0.recording.file == file }
    }

    private var lanesBottom: CGFloat {
        Self.topInset + CGFloat(max(lanes.count, 1)) * TimelineGeometry.laneHeight
    }

    // MARK: Drawing

    private func draw(in ctx: inout GraphicsContext, size: CGSize) {
        let g = geometry(size.width)
        let x0 = Self.labelColumn
        let popsMid = lanesBottom + TimelineGeometry.popRowHeight / 2
        let gridBottom = lanesBottom + TimelineGeometry.popRowHeight

        // Lane strips and titles.
        for (i, lane) in lanes.enumerated() {
            let top = Self.topInset + CGFloat(i) * TimelineGeometry.laneHeight
            let strip = CGRect(x: x0, y: top + 3, width: g.width, height: TimelineGeometry.laneHeight - 6)
            ctx.fill(Path(roundedRect: strip, cornerRadius: 7), with: .color(RecordingsTheme.panel))
            let color = RecordingsTheme.lane(i)
            let mid = strip.midY
            ctx.fill(Path(ellipseIn: CGRect(x: 12, y: mid - 3.5, width: 7, height: 7)), with: .color(color))
            drawFitted(lane.title, in: &ctx, at: CGPoint(x: 26, y: mid), maxWidth: x0 - 26 - 10, color: RecordingsTheme.text)
        }
        if lanes.isEmpty {
            let strip = CGRect(x: x0, y: Self.topInset + 3, width: g.width, height: TimelineGeometry.laneHeight - 6)
            ctx.fill(Path(roundedRect: strip, cornerRadius: 7), with: .color(RecordingsTheme.panel.opacity(0.6)))
            ctx.draw(Text("No recordings on this day").font(.system(size: 12)).foregroundStyle(RecordingsTheme.muted),
                     at: CGPoint(x: strip.midX, y: strip.midY))
        }

        // Hour ticks over the strips, stronger every 6 h; labels every 3 h.
        for h in 0...24 {
            let x = x0 + g.x(for: dayStart.addingTimeInterval(Double(h) * 3600))
            var line = Path()
            line.move(to: CGPoint(x: x, y: Self.topInset))
            line.addLine(to: CGPoint(x: x, y: gridBottom))
            ctx.stroke(line, with: .color(.white.opacity(h % 6 == 0 ? 0.11 : 0.045)), lineWidth: 1)
            if h % 3 == 0 {
                ctx.draw(Text(String(format: "%02d", h)).font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(RecordingsTheme.muted),
                         at: CGPoint(x: x, y: gridBottom + Self.hourLabelHeight / 2 + 1))
            }
        }

        // The pops row: it was listening, even when nothing was worth keeping.
        let popLabel = pops.count == 1 ? "1 pop" : "\(pops.count) pops"
        ctx.draw(Text(popLabel).font(.system(size: 11, design: .monospaced)).foregroundStyle(RecordingsTheme.muted),
                 at: CGPoint(x: 26, y: popsMid), anchor: .leading)
        for pop in pops {
            let x = x0 + g.x(for: pop.at)
            ctx.fill(Path(ellipseIn: CGRect(x: x - 1.8, y: popsMid - 1.8, width: 3.6, height: 3.6)), with: .color(.white.opacity(0.25)))
        }

        for marker in markers(width: size.width) { draw(marker, in: ctx) }

        if let now {
            let x = x0 + g.x(for: now)
            var line = Path()
            line.move(to: CGPoint(x: x, y: Self.topInset - 2))
            line.addLine(to: CGPoint(x: x, y: gridBottom))
            ctx.drawLayer { glow in
                glow.addFilter(.blur(radius: 3))
                glow.stroke(line, with: .color(RecordingsTheme.now.opacity(0.6)), lineWidth: 2)
            }
            ctx.stroke(line, with: .color(RecordingsTheme.now), lineWidth: 1)
            ctx.fill(Path(ellipseIn: CGRect(x: x - 2.5, y: Self.topInset - 4.5, width: 5, height: 5)), with: .color(RecordingsTheme.now))
        }
    }

    /// A lane title in the label column, a size smaller when a long frequency would run into 00:00.
    private func drawFitted(_ title: String, in ctx: inout GraphicsContext, at point: CGPoint, maxWidth: CGFloat, color: Color) {
        for size in [11.5, 10.5, 9.5] as [CGFloat] {
            let text = ctx.resolve(Text(title).font(.system(size: size, design: .monospaced)).foregroundStyle(color))
            if text.measure(in: CGSize(width: 1000, height: 100)).width <= maxWidth || size == 9.5 {
                ctx.draw(text, at: point, anchor: .leading)
                return
            }
        }
    }

    private func draw(_ marker: Marker, in ctx: GraphicsContext) {
        let r = marker.recording, rect = marker.rect, c = marker.color
        let selected = r.file == selection
        let pill = Path(roundedRect: rect, cornerRadius: min(5, rect.width / 2))
        var ctx = ctx
        if r.heard && !r.inProgress && !selected { ctx.opacity = 0.6 }

        // The glow: a blurred copy underneath, stronger for the selected one.
        ctx.drawLayer { glow in
            glow.addFilter(.blur(radius: selected ? 8 : 4))
            let spread = selected ? rect.insetBy(dx: -2, dy: -2) : rect
            glow.fill(Path(roundedRect: spread, cornerRadius: 6), with: .color(c.opacity(selected ? 0.95 : r.heard ? 0.35 : 0.6)))
        }

        if r.inProgress {
            // Striped: still being written, so it cannot be opened yet.
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
        if !r.heard && !r.inProgress {
            let dot = CGRect(x: rect.minX, y: rect.minY - 6.5, width: 4.5, height: 4.5)
            ctx.drawLayer { glow in
                glow.addFilter(.blur(radius: 2))
                glow.fill(Path(ellipseIn: dot.insetBy(dx: -1, dy: -1)), with: .color(c))
            }
            ctx.fill(Path(ellipseIn: dot), with: .color(c))
        }
    }

    private func hoverLabel(_ hover: Hover) -> some View {
        let right = hover.point.x > width / 2
        return Text(hover.text)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(RecordingsTheme.text)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(RecordingsTheme.panel.opacity(0.96)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.white.opacity(0.12)))
            .fixedSize()
            .offset(x: right ? hover.point.x - width - 12 : hover.point.x + 12, y: hover.point.y + 14)
            .allowsHitTesting(false)
    }
}
