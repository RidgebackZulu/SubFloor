import Modems
import SwiftUI

/// The cursor bench: WAVEFORM, MICRO SPECTRUM ±100 Hz and IQ of the locked signal, redrawn at up to
/// 30 fps from the engine's `CursorFrameStore` (through `CursorBenchFeed`), each with its amber
/// readout (`BenchReadouts`). Collapsible; without a locked cursor it says how to get one.
struct CursorBenchView: View {
    @Environment(AppModel.self) private var model
    @Binding var expanded: Bool
    @State private var feed = CursorBenchFeed()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button { withAnimation(.snappy) { expanded.toggle() } } label: {
                    Image(systemName: "chevron.right").rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .buttonStyle(.plain)
                SectionHeader("Bench")
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            if expanded {
                let locked = model.modemCursorAudioHz != nil
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !locked)) { _ in
                    let latest = feed.update(from: model.engine.cursorFrames, cursorLocked: locked)
                    if locked {
                        HStack(spacing: 8) {
                            BenchPane(kind: .waveform, cursorFrame: latest)
                            BenchPane(kind: .spectrum, cursorFrame: latest)
                            BenchPane(kind: .iq, cursorFrame: latest).frame(width: 150)
                        }
                    } else {
                        Text(ModemPanelFormat.benchPlaceholder)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.spectrumBackground))
                    }
                }
                .frame(height: 110)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
        }
    }
}

/// One bench pane: its title, its readout, and its trace drawn in a Canvas.
private struct BenchPane: View {
    enum Kind { case waveform, spectrum, iq }

    let kind: Kind
    /// The latest bench frame (nil: none yet).
    let cursorFrame: CursorFrame?

    private var title: String {
        switch kind {
        case .waveform: "WAVEFORM"
        case .spectrum: "MICRO SPECTRUM ±100 Hz"
        case .iq: "IQ"
        }
    }

    private var readout: String {
        guard let cursorFrame else { return "—" }
        let r = BenchReadouts(cursorFrame)
        switch kind {
        case .waveform: return r.waveform
        case .spectrum: return r.spectrum
        case .iq: return r.iq
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            Canvas { ctx, size in
                guard let frame = cursorFrame else { return }
                switch kind {
                case .waveform: Self.drawWaveform(ctx, size: size, samples: frame.waveform)
                case .spectrum: Self.drawSpectrum(ctx, size: size, db: frame.spectrumDb)
                case .iq: Self.drawIQ(ctx, size: size, points: frame.iq)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title)
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(readout)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.modemCursor)
                    .lineLimit(1)
            }
            .padding(.horizontal, 7)
            .padding(.top, 5)
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.spectrumBackground))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.08)))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    /// Unit coordinates (`BenchGeometry`) to the pane.
    private static func point(_ p: SIMD2<Double>, in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + CGFloat(p.x) * rect.width, y: rect.minY + CGFloat(p.y) * rect.height)
    }

    /// The pane below its title line.
    private static func plotRect(_ size: CGSize) -> CGRect {
        CGRect(x: 4, y: 20, width: max(size.width - 8, 1), height: max(size.height - 24, 1))
    }

    private static func polyline(_ points: [SIMD2<Double>], in rect: CGRect) -> Path {
        var path = Path()
        for (i, p) in points.enumerated() {
            if i == 0 {
                path.move(to: point(p, in: rect))
            } else {
                path.addLine(to: point(p, in: rect))
            }
        }
        return path
    }

    private static func drawWaveform(_ ctx: GraphicsContext, size: CGSize, samples: [Float]) {
        let rect = plotRect(size)
        ctx.stroke(Path { $0.move(to: CGPoint(x: rect.minX, y: rect.midY)); $0.addLine(to: CGPoint(x: rect.maxX, y: rect.midY)) },
                   with: .color(Theme.grid), lineWidth: 1)
        let points = BenchGeometry.waveform(samples)
        guard !points.isEmpty else { return }
        ctx.stroke(polyline(points, in: rect), with: .color(Theme.modemCursor), lineWidth: 1.2)
    }

    private static func drawSpectrum(_ ctx: GraphicsContext, size: CGSize, db: [Float]) {
        let rect = plotRect(size)
        ctx.stroke(Path { $0.move(to: CGPoint(x: rect.midX, y: rect.minY)); $0.addLine(to: CGPoint(x: rect.midX, y: rect.maxY)) },
                   with: .color(.white.opacity(0.25)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        let label = { (s: String) in Text(s).font(.system(size: 9, design: .monospaced)).foregroundStyle(.white.opacity(0.35)) }
        ctx.draw(label("−100"), at: CGPoint(x: rect.minX + 2, y: rect.maxY - 6), anchor: .leading)
        ctx.draw(label("+100"), at: CGPoint(x: rect.maxX - 2, y: rect.maxY - 6), anchor: .trailing)
        let points = BenchGeometry.spectrum(db)
        guard let first = points.first, let last = points.last else { return }
        let trace = polyline(points, in: rect)
        var fill = trace
        fill.addLine(to: point(SIMD2(last.x, 1), in: rect))
        fill.addLine(to: point(SIMD2(first.x, 1), in: rect))
        fill.closeSubpath()
        ctx.fill(fill, with: .color(Theme.modemCursor.opacity(0.15)))
        ctx.stroke(trace, with: .color(Theme.modemCursor), lineWidth: 1.2)
    }

    private static func drawIQ(_ ctx: GraphicsContext, size: CGSize, points: [SIMD2<Float>]) {
        let plot = plotRect(size)
        let side = min(plot.width, plot.height)
        let rect = CGRect(x: plot.midX - side / 2, y: plot.midY - side / 2, width: side, height: side)
        var axes = Path()
        axes.move(to: CGPoint(x: rect.minX, y: rect.midY))
        axes.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        axes.move(to: CGPoint(x: rect.midX, y: rect.minY))
        axes.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        ctx.stroke(axes, with: .color(Theme.grid), lineWidth: 1)
        for p in BenchGeometry.iq(points) {
            let c = point(p.point, in: rect)
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - 1.6, y: c.y - 1.6, width: 3.2, height: 3.2)),
                     with: .color(Theme.modemCursor.opacity(p.opacity)))
        }
    }
}
