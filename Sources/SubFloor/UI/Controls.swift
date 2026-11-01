// Controls.swift
import AppKit
import SwiftUI

struct SectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title.uppercased())
            .font(.caption.weight(.semibold))
            .tracking(0.8)
            .foregroundStyle(.secondary)
    }
}

struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(text).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range).controlSize(.small)
        }
    }
}

/// Thin vertical slider used on the spectrum's right edge.
struct VerticalSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let label: String

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                let h = geo.size.height
                let f = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
                ZStack(alignment: .bottom) {
                    Capsule().fill(.white.opacity(0.08)).frame(width: 4)
                    Capsule().fill(Theme.accent.opacity(0.7)).frame(width: 4, height: max(4, h * f))
                    Circle().fill(.white).frame(width: 12, height: 12).shadow(radius: 2).offset(y: -(h * f) + 6)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                    let nf = 1 - min(max(g.location.y / h, 0), 1)
                    value = range.lowerBound + nf * (range.upperBound - range.lowerBound)
                })
            }
            Text(label).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            Text("\(Int(value))").font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary)
        }
    }
}

/// Left and right clicks on an overlaid SwiftUI view (a control-click counts as a right click).
struct ClickCatcher: NSViewRepresentable {
    /// The NSView covers the SwiftUI view, so the tooltip is set on it (`.help` would not show).
    var toolTip: String?
    var onLeft: () -> Void
    var onRight: () -> Void
    var onHover: ((Bool) -> Void)?

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.onLeft = onLeft
        view.onRight = onRight
        view.onHover = onHover
        view.toolTip = toolTip
    }

    final class CatcherView: NSView {
        var onLeft: () -> Void = {}
        var onRight: () -> Void = {}
        var onHover: ((Bool) -> Void)?
        private var inside = false

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                           owner: self, userInfo: nil))
        }

        override func mouseEntered(with event: NSEvent) { setInside(true) }
        override func mouseExited(with event: NSEvent) { setInside(false) }
        // A flag panned out of view under the pointer gets no exit event.
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil { setInside(false) }
        }

        private func setInside(_ value: Bool) {
            guard inside != value else { return }
            inside = value
            onHover?(value)
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            event.modifierFlags.contains(.control) ? onRight() : onLeft()
        }
        override func rightMouseDown(with event: NSEvent) { onRight() }
    }
}

/// Captures scroll-wheel ticks and clicks for an overlaid SwiftUI view.
struct ScrollCatcher: NSViewRepresentable {
    var onScroll: (Int) -> Void
    var onClick: () -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onScroll = onScroll
        view.onClick = onClick
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.onScroll = onScroll
        view.onClick = onClick
    }

    final class CatcherView: NSView {
        var onScroll: (Int) -> Void = { _ in }
        var onClick: () -> Void = {}
        private var accumulated: CGFloat = 0

        override func scrollWheel(with event: NSEvent) {
            if event.hasPreciseScrollingDeltas {
                accumulated += event.scrollingDeltaY
                while abs(accumulated) >= 12 {
                    onScroll(accumulated > 0 ? 1 : -1)
                    accumulated -= accumulated > 0 ? 12 : -12
                }
            } else if event.scrollingDeltaY != 0 {
                onScroll(event.scrollingDeltaY > 0 ? 1 : -1)
            }
        }

        override func mouseDown(with event: NSEvent) { onClick() }
    }
}
