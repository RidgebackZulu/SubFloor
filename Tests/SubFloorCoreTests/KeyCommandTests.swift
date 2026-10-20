import Testing
@testable import SubFloorCore

@Suite struct KeyCommandTests {
    private func decide(_ keyCode: UInt16, _ chars: String? = nil, shift: Bool = false, command: Bool = false,
                        control: Bool = false, option: Bool = false, editing: Bool = false,
                        quickTune: Bool = false, modem: Bool = false, main: Bool = true,
                        rep: Bool = false) -> KeyCommand? {
        KeyCommand.decide(keyCode: keyCode, characters: chars, shift: shift, command: command, control: control,
                          option: option, isEditingText: editing, quickTuneVisible: quickTune,
                          modemActive: modem, isMainWindow: main, isRepeat: rep)
    }

    @Test func arrowsStepTheVFO() {
        #expect(decide(123) == .step(-1))
        #expect(decide(124) == .step(1))
        #expect(decide(123, shift: true) == .step(-10))
        #expect(decide(124, shift: true) == .step(10))
        #expect(decide(124, rep: true) == .step(1))
    }

    @Test func arrowsNudgeTheCursorWhileTheModemIsActive() {
        #expect(decide(123, modem: true) == .nudgeModemCursor(-1))
        #expect(decide(124, modem: true) == .nudgeModemCursor(1))
        #expect(decide(124, shift: true, modem: true) == .nudgeModemCursor(1))
        #expect(decide(124, modem: true, rep: true) == .nudgeModemCursor(1))
        #expect(decide(124, command: true, modem: true) == nil)
        #expect(decide(124, editing: true, modem: true) == nil)
    }

    @Test func escapeUnlocksTheCursorOnlyWhileTheModemIsActive() {
        #expect(decide(53, "\u{1B}", modem: true) == .unlockModemCursor)
        #expect(decide(53, "\u{1B}") == nil)
        #expect(decide(53, "\u{1B}", quickTune: true, modem: true) == nil)
        #expect(decide(53, "\u{1B}", editing: true, modem: true) == nil)
        #expect(decide(53, "\u{1B}", modem: true, main: false) == nil)
    }

    @Test func otherKeys() {
        #expect(decide(33, "[") == .cycleMode(-1))
        #expect(decide(30, "]") == .cycleMode(1))
        #expect(decide(49, " ") == .toggleRun)
        #expect(decide(49, " ", rep: true) == nil)
        #expect(decide(44, "/") == .openQuickTune)
        #expect(decide(30, "]", modem: true) == .cycleMode(1))
        #expect(decide(49, " ", modem: true) == .toggleRun)
    }

    @Test func guardsReturnNil() {
        #expect(decide(124, command: true) == nil)
        #expect(decide(124, control: true) == nil)
        #expect(decide(124, option: true) == nil)
        #expect(decide(33, "[", option: true) == nil)
        #expect(decide(44, "/", command: true) == nil)
        #expect(decide(124, editing: true) == nil)
        #expect(decide(49, " ", editing: true) == nil)
        #expect(decide(124, quickTune: true) == nil)
        #expect(decide(44, "/", quickTune: true) == nil)
        #expect(decide(124, main: false) == nil)
        #expect(decide(0, "a") == nil)
    }
}
