import DSPCore
import MetalKit
import Modems
import SubFloorCore
import SwiftUI

struct SpectrumArea: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                FrequencyRuler().frame(height: 34)
                GeometryReader { geo in
                    ZStack(alignment: .topLeading) {
                        SpectrumView()
                        SpectrumOverlay().allowsHitTesting(false)
                        SignalIDCardAnchor()
                        SplitHandle(height: geo.size.height)
                    }
                    .coordinateSpace(name: "spectrum")
                }
            }
            DBRangeControls().frame(width: 36)
        }
        .background(Theme.spectrumBackground)
    }
}

private struct SpectrumView: NSViewRepresentable {
    @Environment(AppModel.self) private var model

    final class Coordinator { var renderer: SpectrumRenderer? }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SpectrumMTKView {
        let view = SpectrumMTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.colorPixelFormat = .bgra8Unorm
        view.preferredFramesPerSecond = 120
        view.framebufferOnly = true
        view.clearColor = MTLClearColor(red: 0.035, green: 0.047, blue: 0.067, alpha: 1)
        if let device = view.device, let renderer = SpectrumRenderer(device: device, frames: model.engine.frames) {
            let model = model
            renderer.displayProvider = { model.displayState }
            context.coordinator.renderer = renderer
            view.delegate = renderer
        }
        return view
    }

    func updateNSView(_ view: SpectrumMTKView, context: Context) {
        let model = model
        view.interaction = SpectrumInteraction(
            zoom: { model.zoom(by: $0, anchor: $1) },
            pan: { model.pan(byFraction: $0) },
            click: { model.click(atFraction: $0) },
            reset: { model.resetView() },
            hover: { model.hover(at: $0, viewSize: $1) },
            passbandEdges: { model.passbandEdgeFractions },
            dragEdge: { model.dragPassbandEdge(upper: $0, fraction: $1) },
            // No grab tab: the modem decodes the receiver's passband, which follows the VFO.
            boxGrabRect: { nil },
            boxRange: { model.modemBoxFractions },
            dragBox: { _ in },
            clickInBox: { model.clickInModemBox(atFraction: $0) },
            rightClick: { model.openIDCard(atUnit: $0, viewSize: $1) })
    }
}

/// The ID card's popover, anchored at the point that was right-clicked. A second right-click is a new card: the
/// host is keyed by the card's id, so its popover opens at the new point with fresh state, and a late dismissal of
/// the old one closes nothing.
private struct SignalIDCardAnchor: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let card = model.signalID.card {
            SignalIDCardPopover(cardID: card.id, point: card.point).id(card.id)
        }
    }
}

private struct SignalIDCardPopover: View {
    @Environment(AppModel.self) private var model
    let cardID: Int
    let point: CGPoint

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .popover(isPresented: Binding(get: { model.signalID.card?.id == cardID },
                                          set: { if !$0 { model.signalID.closeCard(id: cardID) } }),
                     arrowEdge: .trailing) {
                if let card = model.signalID.card, card.id == cardID {
                    SignalIDCard(identity: card.identity, atHz: card.signalHz, pending: card.pending,
                                 measuring: card.measuring) { model.signalID.closeCard(id: cardID) }
                }
            }
            .position(x: point.x, y: point.y)
            .allowsHitTesting(false)
    }
}

/// The hover label: the frequency and level, and under them Signal ID's line when there is one.
enum HoverLabelDrawing {
    static func draw(_ ctx: GraphicsContext, in size: CGSize, at p: CGPoint, lines: [String]) {
        let texts = lines.enumerated().map { i, line in
            ctx.resolve(Text(line).font(.system(size: 11, weight: i == 0 ? .medium : .regular, design: .monospaced))
                .foregroundStyle(i == 0 ? Color.white : Theme.accent))
        }
        let sizes = texts.map { $0.measure(in: size) }
        let spacing: CGFloat = 2
        let box = CGSize(width: sizes.map(\.width).max() ?? 0,
                         height: sizes.map(\.height).reduce(0, +) + spacing * CGFloat(max(texts.count - 1, 0)))
        let origin = CGPoint(x: max(min(p.x + 10, size.width - box.width - 12), 4), y: max(p.y - box.height - 10, 4))
        ctx.fill(Path(roundedRect: CGRect(origin: origin, size: box).insetBy(dx: -6, dy: -3), cornerRadius: 5),
                 with: .color(.black.opacity(0.65)))
        var y = origin.y
        for (text, textSize) in zip(texts, sizes) {
            ctx.draw(text, at: CGPoint(x: origin.x, y: y), anchor: .topLeading)
            y += textSize.height + spacing
        }
    }
}

/// dB grid, frequency grid, passband, VFO line, modem box and cursor, and hover crosshair, drawn
/// above the Metal view.
private struct SpectrumOverlay: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Canvas { ctx, size in
            let vp = model.viewport
            let specH = size.height * model.spectrumFraction
            let range = max(model.dbMax - model.dbMin, 1)
            let x = { (hz: Double) in CGFloat(vp.fraction(ofHz: hz)) * size.width }

            let dbStep: Float = range > 100 ? 20 : 10
            var db = (model.dbMin / dbStep).rounded(.up) * dbStep
            while db <= model.dbMax {
                let y = CGFloat(1 - (db - model.dbMin) / range) * specH
                ctx.stroke(Path { $0.move(to: CGPoint(x: 0, y: y)); $0.addLine(to: CGPoint(x: size.width, y: y)) },
                           with: .color(Theme.grid), lineWidth: 1)
                ctx.draw(Text("\(Int(db))").font(.system(size: 9, design: .monospaced)).foregroundStyle(.white.opacity(0.35)),
                         at: CGPoint(x: 4, y: y - 7), anchor: .leading)
                db += dbStep
            }
            let step = RulerScale.step(span: vp.spanHz, width: size.width)
            for tick in RulerScale.ticks(lower: vp.lowerHz, upper: vp.upperHz, step: step) {
                ctx.stroke(Path { $0.move(to: CGPoint(x: x(tick), y: 0)); $0.addLine(to: CGPoint(x: x(tick), y: specH)) },
                           with: .color(Theme.grid), lineWidth: 1)
            }

            let pb = model.displayedPassband
            let x0 = x(pb.lowerBound), x1 = x(pb.upperBound)
            ctx.fill(Path(CGRect(x: x0, y: 0, width: max(x1 - x0, 1), height: size.height)), with: .color(Theme.passband))
            for edge in [x0, x1] {
                ctx.stroke(Path { $0.move(to: CGPoint(x: edge, y: 0)); $0.addLine(to: CGPoint(x: edge, y: specH)) },
                           with: .color(Theme.vfo.opacity(0.45)), lineWidth: 1)
            }
            let xv = x(model.vfoHz)
            ctx.stroke(Path { $0.move(to: CGPoint(x: xv, y: 0)); $0.addLine(to: CGPoint(x: xv, y: size.height)) },
                       with: .color(Theme.vfo), lineWidth: 1.5)

            if model.modemSettings.mode != nil { drawModemCursor(ctx, size: size, x: x) }

            if let hover = model.hover {
                let p = CGPoint(x: hover.point.x * size.width, y: hover.point.y * size.height)
                ctx.stroke(Path { $0.move(to: CGPoint(x: p.x, y: 0)); $0.addLine(to: CGPoint(x: p.x, y: size.height)) },
                           with: .color(.white.opacity(0.25)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                if hover.db != nil {
                    ctx.stroke(Path { $0.move(to: CGPoint(x: 0, y: p.y)); $0.addLine(to: CGPoint(x: size.width, y: p.y)) },
                               with: .color(.white.opacity(0.18)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
                var lines = [FrequencyFormatter.grouped(hover.hz) + (hover.db.map { String(format: "   %.1f dB", $0) } ?? "")]
                if let id = SignalIDText.hoverLine(identity: model.signalID.hoverIdentity, pending: model.signalID.hoverPending,
                                                   measuring: model.signalID.hoverMeasuring) {
                    lines.append(id)
                }
                HoverLabelDrawing.draw(ctx, in: size, at: p, lines: lines)
            }
        }
    }

    /// The amber modem cursor with its audio frequency (the decode window is the passband, drawn
    /// above).
    private func drawModemCursor(_ ctx: GraphicsContext, size: CGSize, x: (Double) -> CGFloat) {
        let box = model.modemBox
        let active = model.modemBoxActive
        guard active, let audio = model.modemCursorAudioHz else { return }
        let xc = x(box.rfHz(forAudio: audio))
        ctx.stroke(Path { $0.move(to: CGPoint(x: xc, y: 0)); $0.addLine(to: CGPoint(x: xc, y: size.height)) },
                   with: .color(Theme.modemCursor), lineWidth: 1.5)
        let text = ctx.resolve(Text(FrequencyFormatter.audio(audio)).font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(Theme.modemCursor))
        let ts = text.measure(in: size)
        let origin = CGPoint(x: min(xc + 6, size.width - ts.width - 8), y: 8)
        ctx.fill(Path(roundedRect: CGRect(origin: origin, size: ts).insetBy(dx: -5, dy: -2), cornerRadius: 4),
                 with: .color(.black.opacity(0.65)))
        ctx.draw(text, at: origin, anchor: .topLeading)
    }
}

/// Drag to resize the spectrum / waterfall split.
private struct SplitHandle: View {
    @Environment(AppModel.self) private var model
    let height: CGFloat

    var body: some View {
        Color.clear
            .frame(height: 8)
            .frame(maxWidth: .infinity)
            .overlay(RoundedRectangle(cornerRadius: 1.5).fill(.white.opacity(0.25)).frame(width: 36, height: 3))
            .contentShape(Rectangle())
            .offset(y: height * model.spectrumFraction - 4)
            .onHover { inside in (inside ? NSCursor.resizeUpDown : NSCursor.arrow).set() }
            .gesture(DragGesture(coordinateSpace: .named("spectrum")).onChanged { g in
                model.spectrumFraction = min(max(g.location.y / height, 0.15), 0.85)
            })
    }
}

/// Frequency labels, bookmark flags and a minimap of the captured span.
private struct FrequencyRuler: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        GeometryReader { geo in
            let vp = model.viewport
            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in
                    let step = RulerScale.step(span: vp.spanHz, width: size.width)
                    for tick in RulerScale.ticks(lower: vp.lowerHz, upper: vp.upperHz, step: step) {
                        let x = CGFloat(vp.fraction(ofHz: tick)) * size.width
                        ctx.stroke(Path { $0.move(to: CGPoint(x: x, y: size.height - 10)); $0.addLine(to: CGPoint(x: x, y: size.height - 4)) },
                                   with: .color(.white.opacity(0.35)), lineWidth: 1)
                        ctx.draw(Text(RulerScale.label(tick, step: step)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.6)),
                                 at: CGPoint(x: x, y: size.height - 17))
                    }
                    // Tracked modem signals: thin blue ticks.
                    if model.modemSettings.mode != nil && model.modemBoxActive {
                        let box = model.modemBox
                        for audioHz in model.modemTrackAudioHz {
                            let x = CGFloat(vp.fraction(ofHz: box.rfHz(forAudio: audioHz))) * size.width
                            ctx.stroke(Path { $0.move(to: CGPoint(x: x, y: size.height - 13)); $0.addLine(to: CGPoint(x: x, y: size.height - 3)) },
                                       with: .color(Theme.accent), lineWidth: 1)
                        }
                    }
                    let start = vp.startFractionOfCapture * size.width
                    let width = max(vp.widthFractionOfCapture * size.width, 3)
                    ctx.fill(Path(CGRect(x: 0, y: size.height - 3, width: size.width, height: 3)), with: .color(.white.opacity(0.06)))
                    ctx.fill(Path(CGRect(x: start, y: size.height - 3, width: width, height: 3)), with: .color(Theme.accent.opacity(0.6)))
                }
                ForEach(model.visibleBookmarks) { bookmark in
                    BookmarkFlag(bookmark: bookmark)
                        .position(x: CGFloat(vp.fraction(ofHz: bookmark.frequencyHz)) * geo.size.width, y: 9)
                }
            }
        }
        .background(Color.black.opacity(0.35))
    }
}

/// A bookmark above the spectrum: a click tunes to it (keeping the zoom), a right click opens its
/// editor.
private struct BookmarkFlag: View {
    @Environment(AppModel.self) private var model
    let bookmark: Bookmark
    @State private var editing = false

    var body: some View {
        let color = Color(hex: bookmark.colorHex) ?? Theme.accent
        HStack(spacing: 3) {
            Image(systemName: bookmark.upconverter ? "arrow.up.arrow.down" : "flag.fill").font(.system(size: 8, weight: .bold))
            Text(bookmark.name).font(.system(size: 10, weight: .medium)).lineLimit(1)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .foregroundStyle(.black)
        .background(Capsule().fill(color.opacity(0.9)))
        .overlay { ClickCatcher(toolTip: help, onLeft: { model.select(bookmark) }, onRight: { editing = true }) }
        .popover(isPresented: $editing, arrowEdge: .bottom) {
            BookmarkEditor(bookmark: bookmark) { editing = false }
        }
    }

    private var help: String {
        "\(bookmark.name) — \(FrequencyFormatter.short(bookmark.frequencyHz)) \(bookmark.mode.label) \(FrequencyFormatter.audio(bookmark.bandwidthHz))\(bookmark.upconverter ? " via HamItUp" : ""). Click to tune, right-click to edit"
    }
}

private struct DBRangeControls: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 14) {
            VerticalSlider(value: Binding(get: { Double(model.dbMax) }, set: { v in
                let r = model.dbMax - model.dbMin
                model.dbMax = Float(v)
                model.dbMin = Float(v) - r
            }), range: -100...20, label: "REF")
            VerticalSlider(value: Binding(get: { Double(model.dbMax - model.dbMin) }, set: { model.dbMin = model.dbMax - Float($0) }),
                           range: 20...160, label: "RNG")
        }
        .padding(.vertical, 14)
        .background(Color.black.opacity(0.25))
    }
}
