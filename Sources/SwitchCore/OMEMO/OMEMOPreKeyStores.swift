import Foundation
import Martin
import MartinOMEMO

final class SwitchSignalPreKeyStore: SignalPreKeyStoreProtocol, ContextAware, OMEMOContextBacked {
    weak var context: Context?
    private let queue = DispatchQueue(label: "switch.omemo.prekey.delete")
    private var pendingDelete: [UInt32] = []

    func currentPreKeyId() -> UInt32 { stateRepository?.currentPreKeyId() ?? 0 }
    func loadPreKey(withId: UInt32) -> Data? { stateRepository?.loadPreKey(id: withId) }
    func storePreKey(_ data: Data, withId: UInt32) -> Bool { stateRepository?.storePreKey(id: withId, data: data) ?? false }
    func containsPreKey(withId: UInt32) -> Bool { stateRepository?.containsPreKey(id: withId) ?? false }

    func deletePreKey(withId: UInt32) -> Bool {
        queue.sync {
            pendingDelete.append(withId)
        }
        return true
    }

    func flushDeletedPreKeys() -> Bool {
        let ids: [UInt32] = queue.sync {
            defer { pendingDelete.removeAll() }
            return pendingDelete
        }
        guard !ids.isEmpty else { return false }
        return ids.contains { stateRepository?.deletePreKey(id: $0) ?? false }
    }
}

final class SwitchSignalSignedPreKeyStore: SignalSignedPreKeyStoreProtocol, ContextAware, OMEMOContextBacked {
    weak var context: Context?

    func countSignedPreKeys() -> Int { stateRepository?.countSignedPreKeys() ?? 0 }
    func loadSignedPreKey(withId: UInt32) -> Data? { stateRepository?.loadSignedPreKey(id: withId) }
    func storeSignedPreKey(_ data: Data, withId: UInt32) -> Bool { stateRepository?.storeSignedPreKey(id: withId, data: data) ?? false }
    func containsSignedPreKey(withId: UInt32) -> Bool { stateRepository?.containsSignedPreKey(id: withId) ?? false }
    func deleteSignedPreKey(withId: UInt32) -> Bool { stateRepository?.deleteSignedPreKey(id: withId) ?? false }
}
