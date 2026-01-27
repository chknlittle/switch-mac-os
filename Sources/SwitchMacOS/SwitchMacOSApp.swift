import AppKit
import SwiftUI
import SwitchCore

@main
struct SwitchMacOSApp: App {
    @StateObject private var model = SwitchAppModel()

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
        }
        .windowStyle(.automatic)
    }
}
