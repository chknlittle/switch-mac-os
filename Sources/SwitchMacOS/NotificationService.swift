import AppKit
import Combine
import os.log
import SwitchCore
import UserNotifications

private let logger = Logger(subsystem: "com.switch.macos", category: "notifications")

@MainActor
final class NotificationService: NSObject, ObservableObject {
    private var cancellables: Set<AnyCancellable> = []
    private weak var directoryService: SwitchDirectoryService?
    private var notificationsAvailable = false

    func setup(chatStore: ChatStore, directoryService: SwitchDirectoryService?) {
        self.directoryService = directoryService

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

        // UNUserNotificationCenter requires a proper .app bundle with a bundle identifier.
        // When running as a bare executable (e.g. via `swift build`), skip system notification setup.
        guard let bundleId = Bundle.main.bundleIdentifier else {
            logger.warning("No bundle identifier - notifications disabled")
            notificationsAvailable = false
            return
        }

        logger.info("Setting up notifications for bundle: \(bundleId)")
        notificationsAvailable = true
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error = error {
                logger.error("Notification authorization error: \(error.localizedDescription)")
            } else {
                logger.info("Notification authorization granted: \(granted)")
            }
        }
    }

    private func handleIncoming(_ message: ChatMessage) {
        logger.debug("Received incoming message from \(message.threadJid)")

        if NSApplication.shared.isActive, isActiveChatThread(message.threadJid) {
            logger.debug("Skipping notification - chat is active")
            return
        }

        guard notificationsAvailable else {
            logger.warning("Notifications not available - skipping")
            return
        }

        let content = UNMutableNotificationContent()
        content.title = localPart(of: message.threadJid)
        content.body = message.body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: message.id,
            content: content,
            trigger: nil
        )

        logger.info("Posting notification: \(content.title)")
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                logger.error("Failed to add notification: \(error.localizedDescription)")
            } else {
                logger.info("Notification posted successfully")
            }
        }
        incrementBadge()
    }

    private func isActiveChatThread(_ threadJid: String) -> Bool {
        guard let target = directoryService?.chatTarget else { return false }
        return target.jid == threadJid
    }

    private func localPart(of jid: String) -> String {
        jid.split(separator: "@", maxSplits: 1).first.map(String.init) ?? jid
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
