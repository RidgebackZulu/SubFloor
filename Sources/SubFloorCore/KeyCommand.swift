import Foundation

/// What an app-wide key does, decided from the key and the app's state alone (no AppKit types, so
/// the rules are unit-testable): ←/→ step the VFO (⇧ ×10), or nudge the modem cursor to the
/// previous/next tracked signal while the modem is active; Esc unlocks the modem cursor (only while
/// the modem is active: otherwise it passes through); [ / ] cycle the mode, Space runs/stops, /
/// opens quick tune. Nothing is decided outside the main window, while text is being edited, while
/// quick tune is up, or with ⌘, ⌃ or ⌥ held.
public enum KeyCommand: Equatable, Sendable {
    case step(Int)
    case cycleMode(Int)
    case toggleRun
    case openQuickTune
    case unlockModemCursor
    case nudgeModemCursor(Int)

    /// macOS virtual key codes.
    public static let leftArrow: UInt16 = 123
    public static let rightArrow: UInt16 = 124
    public static let space: UInt16 = 49
    public static let escape: UInt16 = 53

    public static func decide(keyCode: UInt16, characters: String?, shift: Bool, command: Bool, control: Bool,
                              option: Bool, isEditingText: Bool, quickTuneVisible: Bool, modemActive: Bool,
                              isMainWindow: Bool, isRepeat: Bool) -> KeyCommand? {
        if !isMainWindow || isEditingText || quickTuneVisible { return nil }
        if command || control || option { return nil }
        let multiplier = shift ? 10 : 1
        switch keyCode {
        case leftArrow: return modemActive ? .nudgeModemCursor(-1) : .step(-multiplier)
        case rightArrow: return modemActive ? .nudgeModemCursor(1) : .step(multiplier)
        case space: return isRepeat ? nil : .toggleRun
        case escape: return modemActive ? .unlockModemCursor : nil
        default: break
        }
        switch characters {
        case "[": return .cycleMode(-1)
        case "]": return .cycleMode(1)
        case "/": return .openQuickTune
        default: return nil
        }
    }
}
