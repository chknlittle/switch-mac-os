import AppKit
import Combine
import SwitchCore
import UserNotifications

@MainActor
final class NotificationService: NSObject, ObservableObject {
    private var cancellables: Set<AnyCancellable> = []
    private weak var directoryService: SwitchDirectoryService?
    private var notificationsAvailable = false

    func setup(chatStore: ChatStore, directoryService: SwitchDirectoryService?) {
        self.directoryService = directoryService

        // UNUserNotificationCenter requires a proper .app bundle with a bundle identifier.
        // When running as a bare executable (e.g. via `swift build`), skip notification setup.
        guard Bundle.main.bundleIdentifier != nil else {
            chatStore.liveIncomingMessage
                .receive(on: DispatchQueue.main)
                .sink { [weak self] message in
                    self?.handleIncoming(message)
                }
                .store(in: &cancellables)
            return
        }

        notificationsAvailable = true
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }

        chatStore.liveIncomingMessage
            .receive(on: DispatchQueue.main)
            .sink { [weak self] message in
                self?.handleIncoming(message)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { _ in
                NSApplication.shared.dockTile.badgeLabel = nil
            }
            .store(in: &cancellables)
    }

    private func handleIncoming(_ message: ChatMessage) {
        if NSApplication.shared.isActive, isActiveChatThread(message.threadJid) {
            return
        }

        guard notificationsAvailable else { return }

        let content = UNMutableNotificationContent()
        content.title = localPart(of: message.threadJid)
        content.body = message.body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: message.id,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request)
        incrementBadge()
    }

    private func isActiveChatThread(_ threadJid: String) -> Bool {
        guard let target = directoryService?.chatTarget else { return false }
        switch target {
        case .dispatcher(let jid), .individual(let jid), .subagent(let jid):
            return jid == threadJid
        }
    }

    private func localPart(of jid: String) -> String {
        if let atIndex = jid.firstIndex(of: "@") {
            return String(jid[jid.startIndex..<atIndex])
        }
        return jid
    }

    private func incrementBadge() {
        let current = Int(NSApplication.shared.dockTile.badgeLabel ?? "0") ?? 0
        NSApplication.shared.dockTile.badgeLabel = "\(current + 1)"
    }
}

extension NotificationService: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        await MainActor.run {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }
}
