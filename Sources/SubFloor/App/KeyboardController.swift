import AppKit

/// App-wide keys that work whenever no text field is being edited:
/// ←/→ step VFO (⇧ ×10), [ / ] cycle mode, Space run/stop, / quick tune.
@MainActor
final class KeyboardController {
    static let shared = KeyboardController()
    private var monitor: Any?

    enum Action: Equatable {
        case step(Int)
        case cycleMode(Int)
        case toggleRun
        case openQuickTune
    }

    func install(model: AppModel) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak model] event in
            guard let model else { return event }
            let handled = MainActor.assumeIsolated { Self.handle(event, model: model) }
            return handled ? nil : event
        }
    }

    /// Pure key → action decision, separated from NSEvent/model so the guards are unit-testable.
    nonisolated static func decide(keyCode: UInt16, characters: String?, modifiers: NSEvent.ModifierFlags,
                                   isEditingText: Bool, quickTuneVisible: Bool,
                                   isMainWindow: Bool = true, isRepeat: Bool = false) -> Action? {
        if !isMainWindow || isEditingText || quickTuneVisible { return nil }
        let flags = modifiers.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) || flags.contains(.control) || flags.contains(.option) { return nil }
        let multiplier = flags.contains(.shift) ? 10 : 1
        switch keyCode {
        case 123: return .step(-multiplier)
        case 124: return .step(multiplier)
        case 49: return isRepeat ? nil : .toggleRun
        default: break
        }
        switch characters {
        case "[": return .cycleMode(-1)
        case "]": return .cycleMode(1)
        case "/": return .openQuickTune
        default: return nil
        }
    }

    private static func handle(_ event: NSEvent, model: AppModel) -> Bool {
        // Only the main SubFloor window: not NSOpenPanel/other panels, not Settings.
        let window = event.window
        let isMain = window != nil && !(window is NSPanel) && window?.title == "SubFloor"
        let action = decide(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers,
                            modifiers: event.modifierFlags,
                            isEditingText: NSApp.keyWindow?.firstResponder is NSText,
                            quickTuneVisible: model.quickTuneVisible,
                            isMainWindow: isMain, isRepeat: event.isARepeat)
        switch action {
        case .step(let n): model.stepVFO(n)
        case .cycleMode(let d): model.cycleMode(d)
        case .toggleRun: model.toggleRun()
        case .openQuickTune: model.quickTuneVisible = true
        case nil: return false
        }
        return true
    }
}
