import AppKit
import Testing
@testable import SubFloor

@Suite struct KeyboardControllerTests {
    private func action(_ keyCode: UInt16, _ chars: String? = nil, _ mods: NSEvent.ModifierFlags = [],
                        editing: Bool = false, quickTune: Bool = false,
                        main: Bool = true, rep: Bool = false) -> KeyboardController.Action? {
        KeyboardController.decide(keyCode: keyCode, characters: chars, modifiers: mods,
                                  isEditingText: editing, quickTuneVisible: quickTune,
                                  isMainWindow: main, isRepeat: rep)
    }

    @Test func arrowsStep() {
        #expect(action(123) == .step(-1))
        #expect(action(124) == .step(1))
        #expect(action(123, nil, .shift) == .step(-10))
        #expect(action(124, nil, .shift) == .step(10))
    }

    @Test func bracketsCycleMode() {
        #expect(action(33, "[") == .cycleMode(-1))
        #expect(action(30, "]") == .cycleMode(1))
    }

    @Test func spaceTogglesRunAndSlashOpensQuickTune() {
        #expect(action(49, " ") == .toggleRun)
        #expect(action(44, "/") == .openQuickTune)
    }

    @Test func guardsReturnNil() {
        #expect(action(124, nil, .command) == nil)
        #expect(action(124, nil, .control) == nil)
        #expect(action(44, "/", .command) == nil)
        #expect(action(124, nil, [], editing: true) == nil)
        #expect(action(49, " ", [], editing: true) == nil)
        #expect(action(124, nil, [], quickTune: true) == nil)
        #expect(action(44, "/", [], quickTune: true) == nil)
        #expect(action(0, "a") == nil)
    }

    @Test func nonMainWindowReturnsNil() {
        #expect(action(124, nil, [], main: false) == nil)
        #expect(action(49, " ", [], main: false) == nil)
    }

    @Test func repeatIgnoredForSpaceOnly() {
        #expect(action(49, " ", [], rep: true) == nil)
        #expect(action(124, nil, [], rep: true) == .step(1))
    }

    @Test func optionExcluded() {
        #expect(action(124, nil, .option) == nil)
        #expect(action(33, "[", .option) == nil)
    }
}
