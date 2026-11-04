import Recording
import Scheduling
import SwiftUI

/// What the Schedule button shows and does, as a pure value built from the scheduler's state; the view only draws
/// it and maps the actions to scheduler calls.
struct ScheduleButtonModel: Equatable {
    enum Look: Equatable {
        case off, later, soon, recording, watching

        /// Only the coming-up state pulses.
        var pulses: Bool { self == .soon }
        /// The SF Symbol in the left part; recording draws a white dot instead.
        var symbol: String? {
            switch self {
            case .off, .later, .soon: "clock"
            case .watching: "eye"
            case .recording: nil
            }
        }
    }

    enum Action: Equatable { case turnOn, turnOff, stopRun, startEarly, none }

    let look: Look
    let tickerText: String
    let leftLabel: String
    let accessibilityLabel: String
    let leftAction: Action
    let tickerAction: Action

    init(state: ScheduleButtonState, zone: TimeZone) {
        tickerText = TickerText.text(state, zone: zone)
        switch state {
        case .off:
            look = .off; leftLabel = "Schedule"; leftAction = .turnOn; tickerAction = .none
            accessibilityLabel = "Scheduler off: click to turn it on"
        case .later:
            look = .later; leftLabel = "Schedule"; leftAction = .turnOff; tickerAction = .none
            accessibilityLabel = "Scheduler on: click to turn it off"
        case .soon:
            look = .soon; leftLabel = "Schedule"; leftAction = .turnOff; tickerAction = .startEarly
            accessibilityLabel = "Scheduler on: click to turn it off"
        case .recording(_, let elapsed, _, _):
            look = .recording; leftLabel = RecordingFormat.elapsed(Double(elapsed)); leftAction = .stopRun; tickerAction = .none
            accessibilityLabel = "Recording on schedule, \(Self.spoken(elapsed)): click to stop this recording"
        case .watching:
            look = .watching; leftLabel = "Watching"; leftAction = .stopRun; tickerAction = .none
            accessibilityLabel = "Pirate watch: click to stop watching"
        }
    }

    /// `12 minutes 4 seconds`, `1 hour 2 minutes`: zero parts left out.
    static func spoken(_ totalSeconds: Int) -> String {
        let s = max(0, totalSeconds)
        let parts = [(s / 3600, "hour"), (s / 60 % 60, "minute"), (s % 60, "second")]
            .filter { $0.0 > 0 }
            .map { "\($0.0) \($0.1)\($0.0 == 1 ? "" : "s")" }
        return parts.isEmpty ? "0 seconds" : parts.joined(separator: " ")
    }
}

/// The top bar's Schedule button: the left part is the scheduler's on/off switch (or stops a run), the ticker box
/// scrolls what's coming up and, while it pulses, starts that schedule early. Cyan is the scheduler's colour;
/// red only while it records, like the other record buttons.
struct ScheduleButton: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let cyan = Color(red: 0.36, green: 0.84, blue: 1.0)
    private static let red = Color(red: 1.0, green: 0.27, blue: 0.23)
    private static let tickerWidth: CGFloat = 250
    private static let shape = RoundedRectangle(cornerRadius: 6)

    var body: some View {
        let scheduler = model.scheduler
        let button = ScheduleButtonModel(state: scheduler.buttonState, zone: .current)
        // A narrow top bar drops the ticker first and keeps the left part.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 0) {
                left(button)
                ticker(button)
            }
            .modifier(Frame(look: button.look, reduceMotion: reduceMotion))
            .fixedSize()
            left(button)
                .modifier(Frame(look: button.look, reduceMotion: reduceMotion))
                .fixedSize()
        }
        .contextMenu { Button("Schedules…") { openWindow(id: "schedules") } }
    }

    private func perform(_ action: ScheduleButtonModel.Action) {
        switch action {
        case .turnOn: model.scheduler.isOn = true
        case .turnOff: model.scheduler.isOn = false
        case .stopRun: model.scheduler.stopRun()
        case .startEarly: model.scheduler.startEarly()
        case .none: break
        }
    }

    private func left(_ button: ScheduleButtonModel) -> some View {
        let look = button.look
        return Button { perform(button.leftAction) } label: {
            HStack(spacing: 6) {
                if let symbol = look.symbol {
                    Image(systemName: symbol)
                } else {
                    Circle().fill(Color.white).frame(width: 7, height: 7)
                }
                Text(button.leftLabel).monospacedDigit().lineLimit(1)
            }
            .font(.callout.weight(.semibold))
            .padding(.horizontal, 10)
            .frame(height: 26)
            .foregroundStyle(Self.foreground(look))
            .background(Self.fill(look))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(button.accessibilityLabel)
        .accessibilityLabel(button.accessibilityLabel)
    }

    @ViewBuilder
    private func ticker(_ button: ScheduleButtonModel) -> some View {
        let box = Ticker(text: button.tickerText, scrolls: button.look != .off && !reduceMotion)
            .frame(width: Self.tickerWidth, height: 26)
            .background(Color(red: 0.035, green: 0.047, blue: 0.067).opacity(0.85))
            .overlay(alignment: .leading) { Rectangle().fill(Self.edge(button.look)).frame(width: 1) }
            .contentShape(Rectangle())
        if button.tickerAction == .none {
            // Not clickable: plain text, so nothing dims it.
            box.accessibilityElement(children: .ignore).accessibilityLabel(button.tickerText)
                .help(button.tickerText)
        } else {
            Button { perform(button.tickerAction) } label: { box }
                .buttonStyle(.plain)
                .accessibilityLabel(button.tickerText)
                .help("Tune now and start this schedule early")
        }
    }

    private static func foreground(_ look: ScheduleButtonModel.Look) -> Color {
        switch look {
        case .off: Color.secondary
        case .later, .soon, .watching: cyan
        case .recording: Color.white
        }
    }

    private static func fill(_ look: ScheduleButtonModel.Look) -> Color {
        switch look {
        case .off: Color.white.opacity(0.06)
        case .later, .soon, .watching: cyan.opacity(0.16)
        case .recording: red
        }
    }

    private static func edge(_ look: ScheduleButtonModel.Look) -> Color {
        switch look {
        case .off: Color.white.opacity(0.15)
        case .later, .soon, .watching: cyan.opacity(0.4)
        case .recording: red.opacity(0.6)
        }
    }

    /// The button's outline, dimmed when off, and the cyan glow while it pulses.
    private struct Frame: ViewModifier {
        let look: ScheduleButtonModel.Look
        let reduceMotion: Bool

        func body(content: Content) -> some View {
            if look.pulses, !reduceMotion {
                // ~1.4 s period, as in the mockup: the glow and the outline swell together.
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                    let phase = 0.5 - 0.5 * cos(2 * .pi * context.date.timeIntervalSinceReferenceDate / 1.4)
                    framed(content, outline: ScheduleButton.cyan.opacity(0.45 + 0.55 * phase), glow: 0.32 * phase)
                }
            } else {
                framed(content, outline: outline, glow: look.pulses ? 0.2 : 0)
            }
        }

        private var outline: Color {
            switch look {
            case .off: Color.white.opacity(0.15)
            case .later: ScheduleButton.cyan.opacity(0.45)
            case .soon: ScheduleButton.cyan
            case .watching: ScheduleButton.cyan.opacity(0.7)
            case .recording: ScheduleButton.red
            }
        }

        private func framed(_ content: Content, outline: Color, glow: Double) -> some View {
            content
                .clipShape(ScheduleButton.shape)
                .overlay { ScheduleButton.shape.stroke(outline) }
                .background { ScheduleButton.shape.fill(ScheduleButton.cyan.opacity(glow)).blur(radius: 4).padding(-3) }
                .opacity(look == .off ? 0.7 : 1)
        }
    }
}

/// Monospaced 12 pt text in a clipped box. Scrolls (two copies, looping) only when the text is wider than the box
/// and `scrolls` is true; otherwise shows the start of the text.
private struct Ticker: View {
    let text: String
    let scrolls: Bool
    @State private var textWidth: CGFloat = 0

    private static let gap: CGFloat = 24
    private static let inset: CGFloat = 10
    /// Points per second; the mockup crosses a ~600 pt string in 14 s.
    private static let speed: CGFloat = 40

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
            let overflows = textWidth + Self.inset > geo.size.width
            let cycle = textWidth + Self.gap
            if scrolls, overflows, cycle > 0 {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    let offset = CGFloat(t * Double(Self.speed)).truncatingRemainder(dividingBy: cycle)
                    HStack(spacing: Self.gap) { label; label }
                        .offset(x: Self.inset - offset)
                }
            } else {
                label.offset(x: Self.inset)
            }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
        }
        .clipped()
        .background { measure }
    }

    private var label: some View {
        Text(text).font(.system(size: 12, design: .monospaced)).foregroundStyle(Color(red: 0.91, green: 0.97, blue: 1.0))
            .lineLimit(1).fixedSize()
    }

    /// An invisible copy that reports the text's natural width.
    private var measure: some View {
        label.hidden().background(GeometryReader { g in
            Color.clear.onAppear { textWidth = g.size.width }.onChange(of: g.size.width) { _, w in textWidth = w }
        })
    }
}
