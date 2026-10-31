import AppKit
import Recording
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    weak var dial: DialController?
    /// The MCP server, handed over once the main window appears; stopped on quit.
    var mcp: MCPServer?

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
            mcp?.stop()
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
    @State private var mcp: MCPServer
    @AppStorage("appearance") private var appearance = "dark"

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        let model = AppModel()
        _model = State(initialValue: model)
        _dial = State(initialValue: DialController(model: model))
        let tools = SubFloorTools(model: model)
        let mcp = MCPServer(provider: tools)
        tools.connectedClients = { [weak mcp] in mcp?.connectedClients ?? [] }
        _mcp = State(initialValue: mcp)
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
                .environment(mcp)
                .preferredColorScheme(scheme)
                .tint(Theme.accent)
                .onAppear {
                    appDelegate.model = model
                    appDelegate.dial = dial
                    if appDelegate.mcp == nil {
                        appDelegate.mcp = mcp
                        if mcp.settings.enabled { Task { await mcp.apply(mcp.settings) } }
                    }
                    dial.start()
                    KeyboardController.shared.install(model: model)
                    NSApp.activate()
                }
        }
        .defaultSize(width: 1440, height: 900)
        .commands { RadioCommands(model: model) }

        Window("Recordings", id: "recordings") {
            RecordingsWindow()
                .environment(model)
                .preferredColorScheme(.dark)   // its own fixed palette, whatever the appearance setting
                .tint(Theme.accent)
        }
        .defaultSize(width: 1100, height: 640)
        .defaultLaunchBehavior(.suppressed)   // opened from the menu or the button, never restored at launch

        Window("Bookmarks", id: "bookmarks") {
            BookmarkManagerWindow()
                .environment(model)
                .preferredColorScheme(scheme)
                .tint(Theme.accent)
        }
        .defaultSize(width: 1400, height: 640)
        .defaultLaunchBehavior(.suppressed)

        Window("MCP Server", id: "mcp") {
            MCPWindow()
                .environment(mcp)
                .preferredColorScheme(scheme)
                .tint(Theme.accent)
        }
        .defaultSize(width: 900, height: 680)
        .defaultLaunchBehavior(.suppressed)

        Settings {
            SettingsView()
                .environment(model)
                .environment(dial)
                .environment(mcp)
                .preferredColorScheme(scheme)
        }
    }
}

struct RadioCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandMenu("Radio") {
            Button(model.isRunning ? "Stop" : "Run") { model.toggleRun() }.keyboardShortcut("r")
            Button("Quick Tune…") { model.quickTuneVisible = true }.keyboardShortcut("l")
            Divider()
            Button("Add Bookmark") { model.addBookmark() }.keyboardShortcut("d")
            Button("Bookmarks…") { openWindow(id: "bookmarks") }.keyboardShortcut("b", modifiers: [.command, .option])
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
            Button(model.autoRecordEnabled ? "Turn Auto-Record Off" : "Turn Auto-Record On") { model.toggleAutoRecord() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
            Button(model.noiseReduction.enabled ? "Turn Noise Reduction Off" : "Turn Noise Reduction On") { model.toggleNoiseReduction() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(!model.noiseReductionAvailable)
            Toggle("Transcribe Recordings", isOn: Binding(get: { model.transcriptionSettings.enabled },
                                                          set: { model.transcriptionSettings.enabled = $0 }))
            Button("Recordings…") { openWindow(id: "recordings") }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            Button("Show Recordings in Finder") { model.revealRecordings() }
            Divider()
            Button("MCP Server…") { openWindow(id: "mcp") }
        }
    }
}
