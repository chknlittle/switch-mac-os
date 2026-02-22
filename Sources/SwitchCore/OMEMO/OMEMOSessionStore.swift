import Foundation
import Martin
import MartinOMEMO

final class SwitchSignalSessionStore: SignalSessionStoreProtocol, ContextAware, OMEMOContextBacked {
    weak var context: Context?

    func sessionRecord(forAddress address: SignalAddress) -> Data? {
        stateRepository?.loadSession(address: address)
    }

    func allDevices(for name: String, activeAndTrusted: Bool) -> [Int32] {
        stateRepository?.allDevices(for: name, activeAndTrusted: activeAndTrusted) ?? []
    }

    func storeSessionRecord(_ data: Data, forAddress address: SignalAddress) -> Bool {
        stateRepository?.storeSession(address: address, data: data) ?? false
    }

    func containsSessionRecord(forAddress address: SignalAddress) -> Bool {
        stateRepository?.loadSession(address: address) != nil
    }

    func deleteSessionRecord(forAddress address: SignalAddress) -> Bool {
        stateRepository?.deleteSession(address: address) ?? false
    }

    func deleteAllSessions(for name: String) -> Bool {
        stateRepository?.deleteAllSessions(for: name) ?? false
    }
}

final class SwitchSignalSenderKeyStore: SignalSenderKeyStoreProtocol {
    func storeSenderKey(_ key: Data, address: SignalAddress?, groupId: String?) -> Bool { false }
    func loadSenderKey(forAddress address: SignalAddress?, groupId: String?) -> Data? { nil }
}
