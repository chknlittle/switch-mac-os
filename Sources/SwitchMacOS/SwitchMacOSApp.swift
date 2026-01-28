import AppKit
import SwiftUI
import SwitchCore

@main
struct SwitchMacOSApp: App {
    @StateObject private var model = SwitchAppModel()
    @StateObject private var notificationService = NotificationService()

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
                }
        }
        .windowStyle(.automatic)
    }
}
