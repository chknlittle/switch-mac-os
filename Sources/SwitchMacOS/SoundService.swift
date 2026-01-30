import AppKit
import Combine
import SwitchCore

@MainActor
final class SoundService: NSObject, ObservableObject {
    private var cancellables: Set<AnyCancellable> = []
    private weak var directoryService: SwitchDirectoryService?

    private var awaitingPromptFinishThreads: Set<String> = []
    private var finishTasks: [String: Task<Void, Never>] = [:]

    private var lastTickAt: TimeInterval = 0
    private var lastFinishAt: TimeInterval = 0

    func setup(chatStore: ChatStore, directoryService: SwitchDirectoryService?) {
        self.directoryService = directoryService
        cancellables.removeAll()

        chatStore.liveOutgoingMessage
            .receive(on: DispatchQueue.main)
            .sink { [weak self] message in
                self?.handleOutgoing(message)
            }
            .store(in: &cancellables)

        chatStore.liveIncomingMessage
            .receive(on: DispatchQueue.main)
            .sink { [weak self] message in
                self?.handleIncoming(message)
            }
            .store(in: &cancellables)
    }

    private func handleOutgoing(_ message: ChatMessage) {
        guard shouldPlayFor(threadJid: message.threadJid) else { return }
        awaitingPromptFinishThreads.insert(message.threadJid)
        cancelFinishTask(for: message.threadJid)
        playTick()
    }

    private func handleIncoming(_ message: ChatMessage) {
        guard shouldPlayFor(threadJid: message.threadJid) else { return }

        if message.meta?.type == .runStats {
            if awaitingPromptFinishThreads.contains(message.threadJid) {
                playFinish()
                awaitingPromptFinishThreads.remove(message.threadJid)
                cancelFinishTask(for: message.threadJid)
            }
            return
        }

        let isToolRelated = message.meta?.isToolRelated ?? false
        if isToolRelated {
            playTick(extraQuiet: true)
        } else {
            playTick()
        }

        guard awaitingPromptFinishThreads.contains(message.threadJid) else { return }
        if isToolRelated {
            // Tool bursts can have long gaps while the tool runs; avoid
            // scheduling a "finished" sound off tool-related messages.
            cancelFinishTask(for: message.threadJid)
        } else {
            rescheduleFinish(for: message.threadJid)
        }
    }

    private func rescheduleFinish(for threadJid: String) {
        cancelFinishTask(for: threadJid)

        finishTasks[threadJid] = Task { [weak self] in
            // A short pause after the last incoming message tends to align with
            // "prompt finished" without double-firing on tool bursts.
            try? await Task.sleep(nanoseconds: 750_000_000)
            await MainActor.run {
                guard let self else { return }
                guard self.awaitingPromptFinishThreads.contains(threadJid) else { return }
                guard self.shouldPlayFor(threadJid: threadJid) else { return }
                self.playFinish()
                self.awaitingPromptFinishThreads.remove(threadJid)
                self.finishTasks.removeValue(forKey: threadJid)
            }
        }
    }

    private func cancelFinishTask(for threadJid: String) {
        finishTasks[threadJid]?.cancel()
        finishTasks.removeValue(forKey: threadJid)
    }

    private func shouldPlayFor(threadJid: String) -> Bool {
        guard NSApplication.shared.isActive else { return false }
        return isActiveChatThread(threadJid)
    }

    private func isActiveChatThread(_ threadJid: String) -> Bool {
        guard let target = directoryService?.chatTarget else { return true }
        return target.jid == threadJid
    }

    private func playTick(extraQuiet: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastTickAt < 0.08 {
            return
        }
        lastTickAt = now
        playFirstAvailableSystemSound(names: ["Tink", "Pop"], volume: extraQuiet ? 0.08 : 0.14)
    }

    private func playFinish() {
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastFinishAt < 0.25 {
            return
        }
        lastFinishAt = now
        playFirstAvailableSystemSound(names: ["Glass", "Ping"], volume: 0.55)
    }

    private func playFirstAvailableSystemSound(names: [String], volume: Float) {
        for name in names {
            if let base = NSSound(named: NSSound.Name(name)) {
                let sound = (base.copy() as? NSSound) ?? base
                sound.volume = volume
                sound.play()
                return
            }
        }
        NSSound.beep()
    }
}
