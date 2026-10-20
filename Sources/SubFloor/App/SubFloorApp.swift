import AppKit
import SwiftUI

@main
struct SubFloorApp: App {
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
        WindowGroup("SubFloor") {
            ContentView()
                .environment(model)
                .preferredColorScheme(scheme)
                .tint(Theme.accent)
                .onAppear { NSApp.activate() }
        }
        .defaultSize(width: 1440, height: 900)
    }
}
