import AppKit
import MetalKit
import SubFloorCore

struct SpectrumInteraction {
    var zoom: @MainActor (_ factor: Double, _ anchorFraction: Double) -> Void
    var pan: @MainActor (_ deltaFraction: Double) -> Void
    var click: @MainActor (_ fraction: Double) -> Void
    var reset: @MainActor () -> Void
    /// The pointer in unit coordinates (nil: it left), and the view's size in points.
    var hover: @MainActor (_ unitPoint: CGPoint?, _ viewSize: CGSize) -> Void
    /// The passband's draggable edges in view fractions (nil: that edge does not drag).
    var passbandEdges: @MainActor () -> (lower: Double?, upper: Double?)?
    var dragEdge: @MainActor (_ upper: Bool, _ fraction: Double) -> Void
    /// The modem box's grab tab, horizontally, in view fractions (nil: no box).
    var boxGrabRect: @MainActor () -> (lower: Double, upper: Double)?
    /// The modem box body in view fractions (nil: no box, or an inactive one).
    var boxRange: @MainActor () -> (lower: Double, upper: Double)?
    var dragBox: @MainActor (_ deltaFraction: Double) -> Void
    var clickInBox: @MainActor (_ fraction: Double) -> Void
    /// A right click (or ⌃-click) anywhere: Signal ID's card for the signal there. The pointer in unit coordinates,
    /// and the view's size in points.
    var rightClick: @MainActor (_ unitPoint: CGPoint, _ viewSize: CGSize) -> Void
}

/// Mouse/trackpad: a click anywhere tunes (on a passband edge or inside the modem box too), drag
/// pans, pinch or ⌥-scroll (or a plain mouse wheel) zooms, two-finger scroll pans, a passband edge
/// dragged sets the bandwidth, double-click resets the view. A right click (or ⌃-click) anywhere opens
/// Signal ID's card, and inside the modem box locks the modem cursor as well. The modem box drags by its
/// grab tab (see `SpectrumHitTest` for the order).
final class SpectrumMTKView: MTKView {
    var interaction: SpectrumInteraction?

    private enum Drag {
        case none
        case pending(start: CGPoint)
        /// A press on a passband edge: a drag sets the bandwidth, a click tunes.
        case pendingEdge(upper: Bool, start: CGPoint)
        case pan(last: CGPoint)
        case edge(upper: Bool)
        case box(last: CGPoint)
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

    private func hit(_ p: CGPoint) -> SpectrumHit {
        guard let interaction else { return .elsewhere }
        return SpectrumHitTest.hit(x: Double(p.x), y: Double(p.y), width: Double(bounds.width),
                                   grabTab: interaction.boxGrabRect(), box: interaction.boxRange(),
                                   passbandEdges: interaction.passbandEdges())
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
        if event.modifierFlags.contains(.control) {
            drag = .none
            rightClick(p)
            return
        }
        switch hit(p) {
        case .boxGrabTab:
            drag = .box(last: p)
            NSCursor.closedHand.set()
        case .passbandEdge(let upper): drag = .pendingEdge(upper: upper, start: p)
        case .boxBody, .elsewhere: drag = .pending(start: p)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        rightClick(point(event))
    }

    /// Opens the ID card at the click; inside the modem box also locks the modem cursor there (or unlocks it, on
    /// the cursor).
    private func rightClick(_ p: CGPoint) {
        if case .boxBody = hit(p) { interaction?.clickInBox(fraction(p)) }
        interaction?.rightClick(unit(p), bounds.size)
    }

    override func mouseDragged(with event: NSEvent) {
        let p = point(event)
        switch drag {
        case .pending(let start) where hypot(p.x - start.x, p.y - start.y) > 3:
            interaction?.pan(-Double((p.x - start.x) / max(bounds.width, 1)))
            drag = .pan(last: p)
        case .pendingEdge(let upper, let start) where hypot(p.x - start.x, p.y - start.y) > 3:
            interaction?.dragEdge(upper, fraction(p))
            drag = .edge(upper: upper)
        case .pan(let last):
            interaction?.pan(-Double((p.x - last.x) / max(bounds.width, 1)))
            drag = .pan(last: p)
        case .edge(let upper):
            interaction?.dragEdge(upper, fraction(p))
        case .box(let last):
            interaction?.dragBox(Double((p.x - last.x) / max(bounds.width, 1)))
            drag = .box(last: p)
        default:
            break
        }
        interaction?.hover(unit(p), bounds.size)
    }

    override func mouseUp(with event: NSEvent) {
        switch drag {
        case .pending, .pendingEdge:
            if event.clickCount == 2 {
                interaction?.reset()
            } else {
                interaction?.click(fraction(point(event)))
            }
        case .box:
            updateCursor(point(event))
        default:
            break
        }
        drag = .none
    }

    override func mouseMoved(with event: NSEvent) {
        let p = point(event)
        updateCursor(p)
        interaction?.hover(unit(p), bounds.size)
    }

    /// Open hand over the modem box's grab tab, resize over a passband edge, crosshair elsewhere.
    private func updateCursor(_ p: CGPoint) {
        switch hit(p) {
        case .boxGrabTab: NSCursor.openHand.set()
        case .passbandEdge: NSCursor.resizeLeftRight.set()
        case .boxBody, .elsewhere: NSCursor.crosshair.set()
        }
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
        interaction?.hover(nil, bounds.size)
    }
}
