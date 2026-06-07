import AppKit
import SwiftUI
import SwitchCore

@main
struct SwitchMacOSApp: App {
    @StateObject private var model = SwitchAppModel()
    @StateObject private var notificationService = NotificationService()
    @StateObject private var soundService = SoundService()

    @MainActor static var _hotkeyMonitor: DispatcherHotkeyMonitor?

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .onAppear {
                    notificationService.setup(
                        chatStore: model.xmpp.chatStore,
                        directoryService: model.directory
                    )
                    soundService.setup(
                        chatStore: model.xmpp.chatStore,
                        directoryService: model.directory
                    )
                    let hotkeyMonitor = DispatcherHotkeyMonitor(model: model)
                    hotkeyMonitor.install()
                    // Retain for app lifetime — never uninstalled.
                    Self._hotkeyMonitor = hotkeyMonitor
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    model.xmpp.reconnectIfNeeded(reason: "app became active")
                }
                .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in
                    model.xmpp.reconnectIfNeeded(reason: "system woke from sleep")
                }
        }
        .windowStyle(.automatic)
        .commands {
            DispatcherHotkeysCommands(model: model)
        }
    }
}
