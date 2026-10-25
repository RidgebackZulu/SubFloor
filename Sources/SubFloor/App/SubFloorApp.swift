import AppKit
import Recording
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    weak var dial: DialController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            Self.setDockIcon()
            TerminationSignals.install()
        }
    }

    /// The .app from `scripts/bundle.sh` has its icon in Info.plist; under `swift run` there is no
    /// bundle, so the Dock icon is set from the SwiftPM resource next to the executable. Looked up
    /// by hand: `Bundle.module` traps when the resource bundle is missing.
    @MainActor private static func setDockIcon() {
        guard Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") == nil,
              let dir = Bundle.main.executableURL?.deletingLastPathComponent(),
              let url = Bundle(url: dir.appendingPathComponent("SubFloor_SubFloor.bundle"))?
                  .url(forResource: "AppIcon", withExtension: "png"),
              let image = NSImage(contentsOf: url)
        else { return }
        NSApp.applicationIconImage = image
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            dial?.shutdown()
            model?.shutdown()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct SubFloorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model: AppModel
    @State private var dial: DialController
    @AppStorage("appearance") private var appearance = "dark"

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        let model = AppModel()
        _model = State(initialValue: model)
        _dial = State(initialValue: DialController(model: model))
    }

    private var scheme: ColorScheme? {
        switch appearance {
        case "light": .light
        case "system": nil
        default: .dark
        }
    }

    var body: some Scene {
        Window("SubFloor", id: "main") {
            ContentView()
                .environment(model)
                .environment(dial)
                .preferredColorScheme(scheme)
                .tint(Theme.accent)
                .onAppear {
                    appDelegate.model = model
                    appDelegate.dial = dial
                    dial.start()
                    KeyboardController.shared.install(model: model)
                    NSApp.activate()
                }
        }
        .defaultSize(width: 1440, height: 900)
        .commands { RadioCommands(model: model) }

        Settings {
            SettingsView()
                .environment(model)
                .environment(dial)
                .preferredColorScheme(scheme)
        }
    }
}

struct RadioCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandMenu("Radio") {
            Button(model.isRunning ? "Stop" : "Run") { model.toggleRun() }.keyboardShortcut("r")
            Button("Quick Tune…") { model.quickTuneVisible = true }.keyboardShortcut("l")
            Divider()
            Button("Add Bookmark") { model.addBookmark() }.keyboardShortcut("d")
            Button(model.showBookmarks ? "Hide Bookmarks on Spectrum" : "Show Bookmarks on Spectrum") {
                model.showBookmarks.toggle()
            }
            .keyboardShortcut("b")
            Divider()
            Button("Toggle HamItUp") { model.setUpconverter(!model.upconverter.enabled) }.keyboardShortcut("u")
            Button("Open IQ Recording…") { model.openIQFile() }.keyboardShortcut("o")
            Button("Reset Zoom") { model.resetView() }.keyboardShortcut("0")
            Divider()
            Button(model.isRecording(.audio) ? "Stop Recording Audio" : "Record Audio") { model.toggleRecording(.audio) }
                .keyboardShortcut("a", modifiers: [.command, .shift])
            Button(model.isRecording(.iq) ? "Stop Recording IQ" : "Record IQ") { model.toggleRecording(.iq) }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            Button(model.isRecordingAll ? "Stop All Recording" : "Record Audio and IQ") { model.toggleRecordingBoth() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Button("Show Recordings in Finder") { model.revealRecordings() }
        }
    }
}
