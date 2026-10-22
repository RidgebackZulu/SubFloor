import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { Self.setDockIcon() }
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
        MainActor.assumeIsolated { model?.shutdown() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct SubFloorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()
    @AppStorage("appearance") private var appearance = "dark"

    init() { NSApplication.shared.setActivationPolicy(.regular) }

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
                .preferredColorScheme(scheme)
                .tint(Theme.accent)
                .onAppear {
                    appDelegate.model = model
                    KeyboardController.shared.install(model: model)
                    NSApp.activate()
                }
        }
        .defaultSize(width: 1440, height: 900)
        .commands { RadioCommands(model: model) }

        Settings {
            SettingsView()
                .environment(model)
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
        }
    }
}
