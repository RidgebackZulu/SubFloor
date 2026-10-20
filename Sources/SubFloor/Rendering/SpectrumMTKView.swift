import AppKit
import MetalKit

struct SpectrumInteraction {
    var zoom: @MainActor (_ factor: Double, _ anchorFraction: Double) -> Void
    var pan: @MainActor (_ deltaFraction: Double) -> Void
    var click: @MainActor (_ fraction: Double) -> Void
    var reset: @MainActor () -> Void
    var hover: @MainActor (_ unitPoint: CGPoint?) -> Void
    var passbandEdges: @MainActor () -> (lower: Double, upper: Double)?
    var dragEdge: @MainActor (_ upper: Bool, _ fraction: Double) -> Void
}

/// Mouse/trackpad: click tunes, drag pans, pinch or ⌥-scroll (or a plain mouse wheel) zooms,
/// two-finger scroll pans, passband edges drag to set bandwidth, double-click resets the view.
final class SpectrumMTKView: MTKView {
    var interaction: SpectrumInteraction?

    private enum Drag {
        case none
        case pending(start: CGPoint)
        case pan(last: CGPoint)
        case edge(upper: Bool)
    }

    private var drag: Drag = .none
    private var tracking: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    /// Point in view coordinates with y measured from the top.
    private func point(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        return CGPoint(x: p.x, y: bounds.height - p.y)
    }

    private func fraction(_ p: CGPoint) -> Double { Double(p.x / max(bounds.width, 1)) }
    private func unit(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x / max(bounds.width, 1), y: p.y / max(bounds.height, 1)) }

    private func edgeHit(_ p: CGPoint) -> Bool? {
        guard let edges = interaction?.passbandEdges() else { return nil }
        if abs(p.x - edges.upper * bounds.width) < 5 { return true }
        if abs(p.x - edges.lower * bounds.width) < 5 { return false }
        return nil
    }

    override func scrollWheel(with event: NSEvent) {
        guard let interaction else { return }
        let x = fraction(point(event))
        if event.modifierFlags.contains(.option) || !event.hasPreciseScrollingDeltas {
            let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY * 0.01 : event.scrollingDeltaY * 0.1
            interaction.zoom(exp(-Double(delta)), x)
        } else {
            let dx = abs(event.scrollingDeltaX) >= abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
            interaction.pan(-Double(dx / max(bounds.width, 1)))
        }
    }

    override func magnify(with event: NSEvent) {
        interaction?.zoom(1 / (1 + Double(event.magnification)), fraction(point(event)))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = point(event)
        if let upper = edgeHit(p) {
            drag = .edge(upper: upper)
        } else {
            drag = .pending(start: p)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = point(event)
        switch drag {
        case .pending(let start) where hypot(p.x - start.x, p.y - start.y) > 3:
            interaction?.pan(-Double((p.x - start.x) / max(bounds.width, 1)))
            drag = .pan(last: p)
        case .pan(let last):
            interaction?.pan(-Double((p.x - last.x) / max(bounds.width, 1)))
            drag = .pan(last: p)
        case .edge(let upper):
            interaction?.dragEdge(upper, fraction(p))
        default:
            break
        }
        interaction?.hover(unit(p))
    }

    override func mouseUp(with event: NSEvent) {
        if case .pending = drag {
            if event.clickCount == 2 {
                interaction?.reset()
            } else {
                interaction?.click(fraction(point(event)))
            }
        }
        drag = .none
    }

    override func mouseMoved(with event: NSEvent) {
        let p = point(event)
        (edgeHit(p) != nil ? NSCursor.resizeLeftRight : NSCursor.crosshair).set()
        interaction?.hover(unit(p))
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
        interaction?.hover(nil)
    }
}
