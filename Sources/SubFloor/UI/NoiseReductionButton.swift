import AppKit
import DSPCore
import SwiftUI

/// The noise-reduction chip: click to turn it on or off, the chevron (or a right-click anywhere on
/// the chip) opens a small strength pop-up. It depends only on its binding and `available`, so the
/// main window's top bar and the Recordings player share it. Fixed colours (green, black) rather
/// than the accent colour, so it looks the same in the dark Recordings window.
struct NoiseReductionButton: View {
    @Binding var settings: NoiseReductionSettings
    var available: Bool
    @State private var showStrength = false

    var body: some View {
        let on = settings.enabled
        HStack(spacing: 0) {
            Button { settings.enabled.toggle() } label: {
                Label(on ? "NR · \(settings.label)" : "NR", systemImage: "sparkles")
                    .padding(.leading, 8)
                    .padding(.trailing, 6)
                    .padding(.vertical, 3)
            }
            .buttonStyle(.plain)

            Rectangle().fill(on ? Color.black.opacity(0.25) : Color.white.opacity(0.15)).frame(width: 1)
                .padding(.vertical, 3)

            Button { showStrength.toggle() } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .padding(.leading, 5)
                    .padding(.trailing, 7)
                    .padding(.vertical, 3)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Noise reduction strength")
        }
        .fixedSize()
        .foregroundStyle(on ? Color.black : Color.secondary)
        .background { RoundedRectangle(cornerRadius: 5).fill(on ? Color.green : Color.white.opacity(0.06)) }
        .overlay { RoundedRectangle(cornerRadius: 5).stroke(on ? Color.green : Color.white.opacity(0.15)) }
        .opacity(available ? (on ? 1 : 0.6) : 0.4)
        .overlay { RightClickCatcher { if available { showStrength = true } } }
        .popover(isPresented: $showStrength, arrowEdge: .bottom) {
            NoiseReductionStrengthView(strength: $settings.strength, label: settings.label)
        }
        .disabled(!available)
        .help(!available ? "Noise reduction is for voice; it's off in WFM"
              : on ? "Noise reduction on (⌘⇧N)" : "Noise reduction off (⌘⇧N)")
        .accessibilityElement(children: .contain)
    }
}

/// The pop-up's content: title, current label, the strength slider. Moving the slider does not turn
/// noise reduction on.
struct NoiseReductionStrengthView: View {
    @Binding var strength: Double
    var label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Noise reduction").font(.callout.weight(.medium))
                Spacer(minLength: 12)
                Text(label).font(.callout).foregroundStyle(.secondary)
            }
            Slider(value: $strength, in: 0...1)
                .accessibilityLabel("Noise reduction strength")
            HStack {
                Text("Light")
                Spacer()
                Text("Strong")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(width: 220)
    }
}

/// Reports right-clicks only. Every other event falls through to the controls underneath, because the
/// view only claims the hit when the event being delivered is a right mouse-down.
private struct RightClickCatcher: NSViewRepresentable {
    var action: () -> Void

    func makeNSView(context: Context) -> CatcherView { CatcherView() }
    func updateNSView(_ view: CatcherView, context: Context) { view.action = action }

    final class CatcherView: NSView {
        var action: (() -> Void)?
        override func hitTest(_ point: NSPoint) -> NSView? {
            NSApp.currentEvent?.type == .rightMouseDown ? super.hitTest(point) : nil
        }
        override func rightMouseDown(with event: NSEvent) { action?() }
    }
}
