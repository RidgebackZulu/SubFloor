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
            hover: { model.hover(at: $0) },
            passbandEdges: { model.passbandEdgeFractions },
            dragEdge: { model.dragPassbandEdge(upper: $0, fraction: $1) },
            boxGrabRect: { model.modemGrabTabFractions },
            boxRange: { model.modemBoxFractions },
            dragBox: { model.dragModemBox(byFraction: $0) },
            clickInBox: { model.clickInModemBox(atFraction: $0) })
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

            let pb = model.passbandRange
            let x0 = x(pb.lowerBound), x1 = x(pb.upperBound)
            ctx.fill(Path(CGRect(x: x0, y: 0, width: max(x1 - x0, 1), height: size.height)), with: .color(Theme.passband))
            for edge in [x0, x1] {
                ctx.stroke(Path { $0.move(to: CGPoint(x: edge, y: 0)); $0.addLine(to: CGPoint(x: edge, y: specH)) },
                           with: .color(Theme.vfo.opacity(0.45)), lineWidth: 1)
            }
            let xv = x(model.vfoHz)
            ctx.stroke(Path { $0.move(to: CGPoint(x: xv, y: 0)); $0.addLine(to: CGPoint(x: xv, y: size.height)) },
                       with: .color(Theme.vfo), lineWidth: 1.5)

            if model.modemSettings.mode != nil { drawModemBox(ctx, size: size, specH: specH, x: x) }

            if let hover = model.hover {
                let p = CGPoint(x: hover.point.x * size.width, y: hover.point.y * size.height)
                ctx.stroke(Path { $0.move(to: CGPoint(x: p.x, y: 0)); $0.addLine(to: CGPoint(x: p.x, y: size.height)) },
                           with: .color(.white.opacity(0.25)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                if hover.db != nil {
                    ctx.stroke(Path { $0.move(to: CGPoint(x: 0, y: p.y)); $0.addLine(to: CGPoint(x: size.width, y: p.y)) },
                               with: .color(.white.opacity(0.18)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
                let label = FrequencyFormatter.grouped(hover.hz) + (hover.db.map { String(format: "   %.1f dB", $0) } ?? "")
                let text = ctx.resolve(Text(label).font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(.white))
                let ts = text.measure(in: size)
                let origin = CGPoint(x: min(p.x + 10, size.width - ts.width - 12), y: max(p.y - ts.height - 10, 4))
                ctx.fill(Path(roundedRect: CGRect(origin: origin, size: ts).insetBy(dx: -6, dy: -3), cornerRadius: 5),
                         with: .color(.black.opacity(0.65)))
                ctx.draw(text, at: origin, anchor: .topLeading)
            }
        }
    }

    /// The modem box (green outline at 8% fill; dashed grey while outside the capture span), its
    /// grab tab and edge labels, and the amber cursor with its audio frequency.
    private func drawModemBox(_ ctx: GraphicsContext, size: CGSize, specH: CGFloat, x: (Double) -> CGFloat) {
        let box = model.modemBox
        let active = model.modemBoxActive
        let x0 = x(box.lowerHz), x1 = x(box.upperHz)
        // Off-screen (beyond where its tab could reach in): nothing to draw.
        guard Double(x1) >= -SpectrumHitTest.minTabWidth,
              Double(x0) <= Double(size.width) + SpectrumHitTest.minTabWidth else { return }
        let color = active ? Theme.modemBox : Color.gray
        let body = CGRect(x: x0, y: 0, width: max(x1 - x0, 1), height: size.height)
        if active { ctx.fill(Path(body), with: .color(Theme.modemBox.opacity(0.08))) }
        ctx.stroke(Path(body), with: .color(color),
                   style: StrokeStyle(lineWidth: 1.5, dash: active ? [] : [5, 4]))

        let tab = SpectrumHitTest.tabExtent(lower: Double(x0), upper: Double(x1))
        let tabRect = CGRect(x: tab.lower, y: 0, width: tab.upper - tab.lower, height: SpectrumHitTest.tabHeight)
        ctx.fill(Path(roundedRect: tabRect, cornerRadius: 3), with: .color(color.opacity(active ? 0.85 : 0.5)))
        ctx.draw(Text(model.modemGrabTabLabel).font(.system(size: 10, weight: .semibold)).foregroundStyle(.black),
                 at: CGPoint(x: tabRect.midX, y: tabRect.midY))

        if x1 - x0 > 90 {
            let labelY = specH - 9
            let label = { (s: String) in Text(s).font(.system(size: 9, design: .monospaced)).foregroundStyle(color.opacity(0.9)) }
            ctx.draw(label("\(Int(ModemBox.audioLow))"), at: CGPoint(x: x0 + 4, y: labelY), anchor: .leading)
            ctx.draw(label("\(Int(ModemBox.audioHigh)) Hz"), at: CGPoint(x: x1 - 4, y: labelY), anchor: .trailing)
        }

        guard active, let audio = model.modemCursorAudioHz else { return }
        let xc = x(box.rfHz(forAudio: audio))
        ctx.stroke(Path { $0.move(to: CGPoint(x: xc, y: 0)); $0.addLine(to: CGPoint(x: xc, y: size.height)) },
                   with: .color(Theme.modemCursor), lineWidth: 1.5)
        let text = ctx.resolve(Text(FrequencyFormatter.audio(audio)).font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(Theme.modemCursor))
        let ts = text.measure(in: size)
        let origin = CGPoint(x: min(xc + 6, size.width - ts.width - 8), y: SpectrumHitTest.tabHeight + 6)
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

private struct BookmarkFlag: View {
    @Environment(AppModel.self) private var model
    let bookmark: Bookmark

    var body: some View {
        let color = Color(hex: bookmark.colorHex) ?? Theme.accent
        Button { model.select(bookmark) } label: {
            HStack(spacing: 3) {
                Image(systemName: bookmark.upconverter ? "arrow.up.arrow.down" : "flag.fill").font(.system(size: 8, weight: .bold))
                Text(bookmark.name).font(.system(size: 10, weight: .medium)).lineLimit(1)
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .foregroundStyle(.black)
            .background(Capsule().fill(color.opacity(0.9)))
        }
        .buttonStyle(.plain)
        .help("\(bookmark.name) — \(FrequencyFormatter.short(bookmark.frequencyHz)) \(bookmark.mode.label)\(bookmark.upconverter ? " via HamItUp" : "")")
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
