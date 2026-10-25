import SubFloorCore
import SwiftUI

/// A knob seen from above: a ring of ticks and a pointer notch, turned by `rotation` degrees.
struct DialGlyph: View {
    var rotation: Double = 0
    var color: Color = Theme.dialGlow
    var ticks = 24

    var body: some View {
        Canvas { ctx, size in draw(in: &ctx, size: size) }
    }

    private func draw(in ctx: inout GraphicsContext, size: CGSize) {
        let r: CGFloat = min(size.width, size.height) / 2
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        func point(_ degrees: Double, _ radius: CGFloat) -> CGPoint {
            let a = degrees * .pi / 180
            return CGPoint(x: c.x + CGFloat(sin(a)) * radius, y: c.y - CGFloat(cos(a)) * radius)
        }
        let body = CGRect(x: c.x - r * 0.62, y: c.y - r * 0.62, width: r * 1.24, height: r * 1.24)
        ctx.stroke(Path(ellipseIn: body), with: .color(color), lineWidth: max(1, r * 0.1))
        let tickWidth = max(0.6, r * 0.06)
        for i in 0..<ticks {
            let a = Double(i) * 360 / Double(ticks) + rotation
            var p = Path()
            p.move(to: point(a, r * 0.78))
            p.addLine(to: point(a, r * 0.98))
            ctx.stroke(p, with: .color(color.opacity(0.55)), lineWidth: tickWidth)
        }
        var notch = Path()
        notch.move(to: point(0, r * 0.2))
        notch.addLine(to: point(0, r * 0.52))
        ctx.stroke(notch, with: .color(color), style: StrokeStyle(lineWidth: max(1, r * 0.14), lineCap: .round))
    }
}

/// Top-bar chip: glows green while the dial is connected; click for its status and pairing.
struct DialChip: View {
    @Environment(DialController.self) private var dial
    @State private var showDetails = false

    var body: some View {
        let on = dial.isConnected
        Button { showDetails.toggle() } label: {
            HStack(spacing: 6) {
                DialGlyph(color: on ? Theme.dialGlow : .secondary).frame(width: 15, height: 15)
                Text(label).font(.callout.weight(.medium))
                    .foregroundStyle(on ? Theme.dialGlow : .secondary)
                if let t = dial.transport {
                    Image(systemName: t == .usb ? "cable.connector" : "wave.3.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.dialGlow.opacity(0.75))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(on ? Theme.dialGlow.opacity(0.13) : Color.white.opacity(0.06)))
            .overlay(Capsule().stroke(on ? Theme.dialGlow.opacity(0.75) : Color.white.opacity(0.12), lineWidth: 1))
            .shadow(color: Theme.dialGlow.opacity(on ? 0.55 : 0), radius: on ? 7 : 0)
            .modifier(ActivityGlow(trigger: dial.activity, enabled: on))
            .animation(.easeInOut(duration: 0.4), value: on)
        }
        .buttonStyle(.plain)
        .help(on ? "SubFloor Dial connected over \(dial.transport?.rawValue ?? "")" : "SubFloor Dial: not connected")
        .popover(isPresented: $showDetails, arrowEdge: .bottom) { DialDetails().environment(dial) }
    }

    private var label: String {
        switch dial.status {
        case .connected: "Dial Connected"
        case .pairing: "Dial Pairing…"
        case .searching: "Dial"
        case .off: "Dial Off"
        }
    }
}

/// A brief brighter glow each time the dial is used.
private struct ActivityGlow: ViewModifier {
    let trigger: Int
    let enabled: Bool

    func body(content: Content) -> some View {
        content.keyframeAnimator(initialValue: 0.0, trigger: trigger) { view, glow in
            view.shadow(color: Theme.dialGlow.opacity(enabled ? glow * 0.9 : 0), radius: 4 + glow * 10)
        } keyframes: { _ in
            LinearKeyframe(1.0, duration: 0.08)
            CubicKeyframe(0.0, duration: 0.7)
        }
    }
}

private struct DialDetails: View {
    @Environment(DialController.self) private var dial

    var body: some View {
        @Bindable var dial = dial
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                DialGlyph(color: dial.isConnected ? Theme.dialGlow : .secondary).frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text("SubFloor Dial").font(.headline)
                    Text(statusText).font(.caption).foregroundStyle(dial.isConnected ? Theme.dialGlow : .secondary)
                }
            }
            if dial.isConnected {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    GridRow { Text("Step").foregroundStyle(.secondary); Text(FrequencyFormatter.short(dial.stepHz)) }
                    GridRow { Text("Knob").foregroundStyle(.secondary); Text(dial.knob == .tune ? "Tuning" : "Bandwidth") }
                    GridRow { Text("Firmware").foregroundStyle(.secondary); Text(dial.firmware) }
                }
                .font(.caption.monospacedDigit())
            }
            Divider()
            Toggle("Bluetooth", isOn: $dial.useBluetooth)
            Toggle("USB", isOn: $dial.useUSB)
            if dial.bluetoothState == .unauthorized {
                Text("SubFloor isn't allowed to use Bluetooth: System Settings › Privacy & Security › Bluetooth.")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            if dial.status == .pairing {
                Label("Waiting for a dial… On the dial: long-press the knob › Bluetooth › Pair new Mac.",
                      systemImage: "dot.radiowaves.left.and.right")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("To pair: long-press the dial's knob, choose Bluetooth › Pair new Mac, then click Pair New Dial.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Pair New Dial") { dial.pairNewDial() }
                Spacer()
                Button("Forget Dial", role: .destructive) { dial.forgetDial() }.disabled(!dial.hasKnownBluetoothDial)
            }
            Text("Knob: turn to tune · press for a coarser step · hold and turn to pick the step · long-press for settings. Touch: tap AM/LSB/USB, tap a digit to tune it, swipe to change step, tap BW to set bandwidth.")
                .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 320)
    }

    private var statusText: String {
        switch dial.status {
        case .connected(let t): "Connected over \(t.rawValue)"
        case .pairing: "Pairing — waiting for a dial"
        case .searching: "Not connected — searching"
        case .off: "Off"
        }
    }
}

/// "Dial Connected", centred and glowing, for a moment after the dial connects.
struct DialConnectedToast: View {
    @Environment(DialController.self) private var dial
    @State private var glow = false

    var body: some View {
        HStack(spacing: 14) {
            DialGlyph(rotation: glow ? 30 : -30).frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text("Dial Connected").font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.dialGlow)
                Text("SubFloor Dial \(dial.firmware) · \(dial.transport?.rawValue ?? "")")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .background(Capsule().fill(.ultraThinMaterial))
        .background(Capsule().fill(Theme.dialGlow.opacity(0.12)))
        .overlay(Capsule().stroke(Theme.dialGlow.opacity(0.85), lineWidth: 1.2))
        .shadow(color: Theme.dialGlow.opacity(glow ? 0.8 : 0.35), radius: glow ? 26 : 10)
        .onAppear { withAnimation(.easeInOut(duration: 0.9).repeatCount(3, autoreverses: true)) { glow = true } }
    }
}

/// Shown while the dial is being used: a ring that turns with the knob, the step and the mode.
struct DialHUD: View {
    @Environment(DialController.self) private var dial
    @Environment(AppModel.self) private var model

    var body: some View {
        let bw = dial.knob == .bandwidth
        let tint = bw ? Theme.accent : Theme.vfo
        HStack(spacing: 14) {
            ZStack {
                DialGlyph(rotation: dial.hudRotation, color: Theme.dialGlow, ticks: 36)
                    .animation(.spring(duration: 0.25), value: dial.hudRotation)
                Capsule().fill(tint).frame(width: 3, height: 9).offset(y: -27).shadow(color: tint, radius: 4)
            }
            .frame(width: 58, height: 58)
            VStack(alignment: .leading, spacing: 3) {
                Text(bw ? "BANDWIDTH" : "STEP").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                Text(bw ? FrequencyFormatter.short(model.bandwidthHz) : FrequencyFormatter.short(dial.stepHz))
                    .font(.system(size: 22, weight: .medium, design: .monospaced))
                    .foregroundStyle(tint)
                    .contentTransition(.numericText())
                    .animation(.snappy(duration: 0.2), value: dial.stepHz)
                HStack(spacing: 6) {
                    Text(model.mode.label)
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(Theme.accent.opacity(dial.lastAction == .mode ? 0.5 : 0.18)))
                        .animation(.easeOut(duration: 0.3), value: dial.lastAction)
                    Text(FrequencyFormatter.short(model.vfoHz)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 18)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 16).fill(.ultraThinMaterial))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.dialGlow.opacity(0.45), lineWidth: 1))
        .shadow(color: Theme.dialGlow.opacity(0.3), radius: 12)
        .allowsHitTesting(false)
    }
}
