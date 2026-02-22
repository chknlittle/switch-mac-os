import Foundation

private struct PersistedDecryptedMessageCache: Codable {
    var order: [String]
    var values: [String: String]

    static var empty: PersistedDecryptedMessageCache {
        PersistedDecryptedMessageCache(order: [], values: [:])
    }
}

final class OMEMODecryptedMessageCache {
    private let path: URL
    private let queue = DispatchQueue(label: "switch.omemo.decrypted-cache", qos: .utility)
    private let maxEntries: Int

    init(account: String, maxEntries: Int = 4000) {
        let sanitized = account.replacingOccurrences(of: "/", with: "_")
        self.path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".switch-mac-os", isDirectory: true)
            .appendingPathComponent("omemo", isDirectory: true)
            .appendingPathComponent("decrypted-\(sanitized).json")
        self.maxEntries = max(100, maxEntries)
    }

    func save(body: String, for messageId: String) {
        guard !messageId.isEmpty, !body.isEmpty else { return }
        queue.sync {
            var state = readStateUnlocked()

            if state.values[messageId] == nil {
                state.order.append(messageId)
            }
            state.values[messageId] = body

            while state.order.count > maxEntries {
                let removed = state.order.removeFirst()
                state.values.removeValue(forKey: removed)
            }

            writeStateUnlocked(state)
        }
    }

    func body(for messageId: String) -> String? {
        guard !messageId.isEmpty else { return nil }
        return queue.sync {
            readStateUnlocked().values[messageId]
        }
    }

    private func readStateUnlocked() -> PersistedDecryptedMessageCache {
        guard let data = try? Data(contentsOf: path) else { return .empty }
        return (try? JSONDecoder().decode(PersistedDecryptedMessageCache.self, from: data)) ?? .empty
    }

    private func writeStateUnlocked(_ state: PersistedDecryptedMessageCache) {
        let dir = path.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: path, options: [.atomic])
    }
}
