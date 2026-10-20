import AppKit
import SubFloorCore

/// App-wide keys that work whenever no text field is being edited:
/// ←/→ step VFO (⇧ ×10) or, while the modem is active, nudge the modem cursor; Esc unlocks the
/// modem cursor; [ / ] cycle mode, Space run/stop, / quick tune. The rules are `KeyCommand`'s.
@MainActor
final class KeyboardController {
    static let shared = KeyboardController()
    private var monitor: Any?

    typealias Action = KeyCommand

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
                                   isEditingText: Bool, quickTuneVisible: Bool, modemActive: Bool = false,
                                   isMainWindow: Bool = true, isRepeat: Bool = false) -> Action? {
        let flags = modifiers.intersection(.deviceIndependentFlagsMask)
        return KeyCommand.decide(keyCode: keyCode, characters: characters, shift: flags.contains(.shift),
                                 command: flags.contains(.command), control: flags.contains(.control),
                                 option: flags.contains(.option), isEditingText: isEditingText,
                                 quickTuneVisible: quickTuneVisible, modemActive: modemActive,
                                 isMainWindow: isMainWindow, isRepeat: isRepeat)
    }

    private static func handle(_ event: NSEvent, model: AppModel) -> Bool {
        // Only the main SubFloor window: not NSOpenPanel/other panels, not Settings.
        let window = event.window
        let isMain = window != nil && !(window is NSPanel) && window?.title == "SubFloor"
        let action = decide(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers,
                            modifiers: event.modifierFlags,
                            isEditingText: NSApp.keyWindow?.firstResponder is NSText,
                            quickTuneVisible: model.quickTuneVisible, modemActive: model.modemKeysActive,
                            isMainWindow: isMain, isRepeat: event.isARepeat)
        switch action {
        case .step(let n): model.stepVFO(n)
        case .cycleMode(let d): model.cycleMode(d)
        case .toggleRun: model.toggleRun()
        case .openQuickTune: model.quickTuneVisible = true
        case .unlockModemCursor: model.unlockModemCursor()
        case .nudgeModemCursor(let n): model.nudgeModemCursor(n)
        case nil: return false
        }
        return true
    }
}
