import CryptoKit
import Foundation
import Martin
import MartinOMEMO

private enum OMEMOPaths {
    static func accountStorePath(account: BareJID) -> URL {
        let fm = FileManager.default
        let base = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".switch-mac-os", isDirectory: true)
            .appendingPathComponent("omemo", isDirectory: true)
        let name = account.stringValue.replacingOccurrences(of: "/", with: "_")
        return base.appendingPathComponent("\(name).json")
    }
}

private struct PersistedIdentity: Codable {
    var name: String
    var deviceId: Int32
    var fingerprint: String
    var keyBase64: String
    var own: Bool
    var statusRawValue: Int
}

private struct PersistedOMEMOState: Codable {
    var registrationId: UInt32?
    var localPublicKeyBase64: String?
    var localPrivateKeyBase64: String?
    var identities: [PersistedIdentity]
    var preKeys: [String: String]
    var signedPreKeys: [String: String]
    var sessions: [String: String]

    static var empty: PersistedOMEMOState {
        PersistedOMEMOState(
            registrationId: nil,
            localPublicKeyBase64: nil,
            localPrivateKeyBase64: nil,
            identities: [],
            preKeys: [:],
            signedPreKeys: [:],
            sessions: [:]
        )
    }
}

private final class PersistedOMEMOBackend {
    private let path: URL
    private let queue = DispatchQueue(label: "switch.omemo.store", qos: .userInitiated)

    init(account: BareJID) {
        self.path = OMEMOPaths.accountStorePath(account: account)
    }

    func readState() -> PersistedOMEMOState {
        queue.sync {
            guard let data = try? Data(contentsOf: path) else { return .empty }
            return (try? JSONDecoder().decode(PersistedOMEMOState.self, from: data)) ?? .empty
        }
    }

    func mutate(_ f: (inout PersistedOMEMOState) -> Void) {
        queue.sync {
            var state = readStateUnlocked()
            f(&state)
            writeStateUnlocked(state)
        }
    }

    private func readStateUnlocked() -> PersistedOMEMOState {
        guard let data = try? Data(contentsOf: path) else { return .empty }
        return (try? JSONDecoder().decode(PersistedOMEMOState.self, from: data)) ?? .empty
    }

    private func writeStateUnlocked(_ state: PersistedOMEMOState) {
        let dir = path.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: path, options: [.atomic])
    }

    func localRegistrationId() -> UInt32 {
        readState().registrationId ?? 0
    }

    func setLocalRegistrationId(_ id: UInt32) {
        mutate { $0.registrationId = id }
    }

    func localIdentityKeyPair() -> SignalIdentityKeyPairProtocol? {
        let s = readState()
        guard let pubB64 = s.localPublicKeyBase64,
              let prvB64 = s.localPrivateKeyBase64,
              let pub = Data(base64Encoded: pubB64),
              let prv = Data(base64Encoded: prvB64) else {
            return nil
        }
        return SignalIdentityKeyPair(publicKey: pub, privateKey: prv)
    }

    func saveLocalIdentityKeyPair(_ pair: SignalIdentityKeyPairProtocol) {
        guard let pub = pair.publicKey?.base64EncodedString(),
              let prv = pair.privateKey?.base64EncodedString() else {
            return
        }
        mutate {
            $0.localPublicKeyBase64 = pub
            $0.localPrivateKeyBase64 = prv
        }
    }

    func identityFingerprint(for address: SignalAddress) -> String? {
        readState().identities.first { $0.name == address.name && $0.deviceId == address.deviceId }?.fingerprint
    }

    func identities(for name: String) -> [Identity] {
        readState().identities.compactMap { item in
            guard item.name == name,
                  let status = IdentityStatus(rawValue: item.statusRawValue),
                  let key = Data(base64Encoded: item.keyBase64) else {
                return nil
            }
            return Identity(
                address: SignalAddress(name: item.name, deviceId: item.deviceId),
                status: status,
                fingerprint: item.fingerprint,
                key: key,
                own: item.own
            )
        }
    }

    func upsertIdentity(address: SignalAddress, fingerprint: String, keyData: Data, own: Bool) {
        mutate { state in
            if let idx = state.identities.firstIndex(where: { $0.name == address.name && $0.deviceId == address.deviceId }) {
                state.identities[idx].fingerprint = fingerprint
                state.identities[idx].keyBase64 = keyData.base64EncodedString()
                state.identities[idx].own = own
                if state.identities[idx].statusRawValue == IdentityStatus.compromisedActive.rawValue ||
                    state.identities[idx].statusRawValue == IdentityStatus.compromisedInactive.rawValue {
                    state.identities[idx].statusRawValue = IdentityStatus.trustedActive.rawValue
                }
                return
            }

            state.identities.append(
                PersistedIdentity(
                    name: address.name,
                    deviceId: address.deviceId,
                    fingerprint: fingerprint,
                    keyBase64: keyData.base64EncodedString(),
                    own: own,
                    statusRawValue: IdentityStatus.trustedActive.rawValue
                )
            )
        }
    }

    func setStatus(_ status: IdentityStatus, for address: SignalAddress) -> Bool {
        var updated = false
        mutate { state in
            guard let idx = state.identities.firstIndex(where: { $0.name == address.name && $0.deviceId == address.deviceId }) else {
                return
            }
            state.identities[idx].statusRawValue = status.rawValue
            updated = true
        }
        return updated
    }

    func setStatus(active: Bool, for address: SignalAddress) -> Bool {
        var updated = false
        mutate { state in
            guard let idx = state.identities.firstIndex(where: { $0.name == address.name && $0.deviceId == address.deviceId }) else {
                return
            }
            guard let current = IdentityStatus(rawValue: state.identities[idx].statusRawValue) else { return }
            state.identities[idx].statusRawValue = active ? current.toActive().rawValue : current.toInactive().rawValue
            updated = true
        }
        return updated
    }

    func isTrusted(address: SignalAddress, publicKeyData: Data?) -> Bool {
        guard let publicKeyData else { return false }
        let fingerprint = fingerprint(publicKey: publicKeyData)

        if let existing = readState().identities.first(where: { $0.name == address.name && $0.deviceId == address.deviceId }) {
            if existing.fingerprint == fingerprint {
                if let status = IdentityStatus(rawValue: existing.statusRawValue) {
                    return status.trust != .compromised
                }
                return false
            }
            _ = setStatus(.compromisedActive, for: address)
            return false
        }
        return true
    }

    func currentPreKeyId() -> UInt32 {
        readState().preKeys.keys.compactMap { UInt32($0) }.max() ?? 0
    }

    func loadPreKey(id: UInt32) -> Data? {
        guard let value = readState().preKeys[String(id)] else { return nil }
        return Data(base64Encoded: value)
    }

    func storePreKey(id: UInt32, data: Data) -> Bool {
        mutate { $0.preKeys[String(id)] = data.base64EncodedString() }
        return true
    }

    func containsPreKey(id: UInt32) -> Bool {
        readState().preKeys[String(id)] != nil
    }

    func deletePreKey(id: UInt32) -> Bool {
        var changed = false
        mutate { state in
            changed = state.preKeys.removeValue(forKey: String(id)) != nil
        }
        return changed
    }

    func countSignedPreKeys() -> Int {
        readState().signedPreKeys.count
    }

    func loadSignedPreKey(id: UInt32) -> Data? {
        guard let value = readState().signedPreKeys[String(id)] else { return nil }
        return Data(base64Encoded: value)
    }

    func storeSignedPreKey(id: UInt32, data: Data) -> Bool {
        mutate { $0.signedPreKeys[String(id)] = data.base64EncodedString() }
        return true
    }

    func containsSignedPreKey(id: UInt32) -> Bool {
        readState().signedPreKeys[String(id)] != nil
    }

    func deleteSignedPreKey(id: UInt32) -> Bool {
        var changed = false
        mutate { state in
            changed = state.signedPreKeys.removeValue(forKey: String(id)) != nil
        }
        return changed
    }

    private func sessionKey(for address: SignalAddress) -> String {
        "\(address.name)|\(address.deviceId)"
    }

    func loadSession(address: SignalAddress) -> Data? {
        guard let value = readState().sessions[sessionKey(for: address)] else { return nil }
        return Data(base64Encoded: value)
    }

    func storeSession(address: SignalAddress, data: Data) -> Bool {
        mutate { $0.sessions[sessionKey(for: address)] = data.base64EncodedString() }
        return true
    }

    func deleteSession(address: SignalAddress) -> Bool {
        var changed = false
        mutate { state in
            changed = state.sessions.removeValue(forKey: sessionKey(for: address)) != nil
        }
        return changed
    }

    func deleteAllSessions(for name: String) -> Bool {
        var changed = false
        mutate { state in
            let before = state.sessions.count
            state.sessions = state.sessions.filter { !($0.key.hasPrefix("\(name)|")) }
            changed = before != state.sessions.count
        }
        return changed
    }

    func allDevices(for name: String, activeAndTrusted: Bool) -> [Int32] {
        let state = readState()
        let ids: Set<Int32> = Set(state.sessions.keys.compactMap { key in
            let parts = key.split(separator: "|", maxSplits: 1)
            guard parts.count == 2, String(parts[0]) == name else { return nil }
            return Int32(parts[1])
        })

        if !activeAndTrusted {
            return Array(ids)
        }

        return ids.filter { deviceId in
            guard let identity = state.identities.first(where: { $0.name == name && $0.deviceId == deviceId }) else {
                return true
            }
            guard let status = IdentityStatus(rawValue: identity.statusRawValue) else { return false }
            return status.isActive && status.trust != .compromised
        }
    }

    private func fingerprint(publicKey: Data) -> String {
        publicKey.map { String(format: "%02x", $0) }.joined()
    }
}

final class SwitchSignalIdentityKeyStore: SignalIdentityKeyStoreProtocol, ContextAware {
    weak var context: Context?

    private var backend: PersistedOMEMOBackend? {
        guard let account = context?.sessionObject.userBareJid else { return nil }
        return PersistedOMEMOBackend(account: account)
    }

    func keyPair() -> SignalIdentityKeyPairProtocol? {
        backend?.localIdentityKeyPair()
    }

    func localRegistrationId() -> UInt32 {
        backend?.localRegistrationId() ?? 0
    }

    func save(identity: SignalAddress, key: SignalIdentityKeyProtocol?) -> Bool {
        guard let key else { return false }
        if let pair = key as? SignalIdentityKeyPairProtocol {
            backend?.saveLocalIdentityKeyPair(pair)
        }
        guard let publicKey = key.publicKey else { return false }
        let fp = publicKey.map { String(format: "%02x", $0) }.joined()
        backend?.upsertIdentity(address: identity, fingerprint: fp, keyData: key.serialized(), own: true)
        return true
    }

    func isTrusted(identity: SignalAddress, key: SignalIdentityKeyProtocol?) -> Bool {
        backend?.isTrusted(address: identity, publicKeyData: key?.publicKey) ?? false
    }

    func save(identity: SignalAddress, publicKeyData: Data?) -> Bool {
        guard let publicKeyData else { return false }
        let fp = publicKeyData.map { String(format: "%02x", $0) }.joined()
        backend?.upsertIdentity(address: identity, fingerprint: fp, keyData: publicKeyData, own: false)
        return true
    }

    func isTrusted(identity: SignalAddress, publicKeyData: Data?) -> Bool {
        backend?.isTrusted(address: identity, publicKeyData: publicKeyData) ?? false
    }

    func setStatus(_ status: IdentityStatus, forIdentity: SignalAddress) -> Bool {
        backend?.setStatus(status, for: forIdentity) ?? false
    }

    func setStatus(active: Bool, forIdentity: SignalAddress) -> Bool {
        backend?.setStatus(active: active, for: forIdentity) ?? false
    }

    func identities(forName: String) -> [Identity] {
        backend?.identities(for: forName) ?? []
    }

    func identityFingerprint(forAddress address: SignalAddress) -> String? {
        backend?.identityFingerprint(for: address)
    }
}

final class SwitchSignalPreKeyStore: SignalPreKeyStoreProtocol, ContextAware {
    weak var context: Context?
    private let queue = DispatchQueue(label: "switch.omemo.prekey.delete")
    private var pendingDelete: [UInt32] = []

    private var backend: PersistedOMEMOBackend? {
        guard let account = context?.sessionObject.userBareJid else { return nil }
        return PersistedOMEMOBackend(account: account)
    }

    func currentPreKeyId() -> UInt32 { backend?.currentPreKeyId() ?? 0 }
    func loadPreKey(withId: UInt32) -> Data? { backend?.loadPreKey(id: withId) }
    func storePreKey(_ data: Data, withId: UInt32) -> Bool { backend?.storePreKey(id: withId, data: data) ?? false }
    func containsPreKey(withId: UInt32) -> Bool { backend?.containsPreKey(id: withId) ?? false }

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
        return ids.contains { backend?.deletePreKey(id: $0) ?? false }
    }
}

final class SwitchSignalSignedPreKeyStore: SignalSignedPreKeyStoreProtocol, ContextAware {
    weak var context: Context?
    private var backend: PersistedOMEMOBackend? {
        guard let account = context?.sessionObject.userBareJid else { return nil }
        return PersistedOMEMOBackend(account: account)
    }

    func countSignedPreKeys() -> Int { backend?.countSignedPreKeys() ?? 0 }
    func loadSignedPreKey(withId: UInt32) -> Data? { backend?.loadSignedPreKey(id: withId) }
    func storeSignedPreKey(_ data: Data, withId: UInt32) -> Bool { backend?.storeSignedPreKey(id: withId, data: data) ?? false }
    func containsSignedPreKey(withId: UInt32) -> Bool { backend?.containsSignedPreKey(id: withId) ?? false }
    func deleteSignedPreKey(withId: UInt32) -> Bool { backend?.deleteSignedPreKey(id: withId) ?? false }
}

final class SwitchSignalSessionStore: SignalSessionStoreProtocol, ContextAware {
    weak var context: Context?
    private var backend: PersistedOMEMOBackend? {
        guard let account = context?.sessionObject.userBareJid else { return nil }
        return PersistedOMEMOBackend(account: account)
    }

    func sessionRecord(forAddress address: SignalAddress) -> Data? {
        backend?.loadSession(address: address)
    }

    func allDevices(for name: String, activeAndTrusted: Bool) -> [Int32] {
        backend?.allDevices(for: name, activeAndTrusted: activeAndTrusted) ?? []
    }

    func storeSessionRecord(_ data: Data, forAddress address: SignalAddress) -> Bool {
        backend?.storeSession(address: address, data: data) ?? false
    }

    func containsSessionRecord(forAddress address: SignalAddress) -> Bool {
        backend?.loadSession(address: address) != nil
    }

    func deleteSessionRecord(forAddress address: SignalAddress) -> Bool {
        backend?.deleteSession(address: address) ?? false
    }

    func deleteAllSessions(for name: String) -> Bool {
        backend?.deleteAllSessions(for: name) ?? false
    }
}

final class SwitchSignalSenderKeyStore: SignalSenderKeyStoreProtocol {
    func storeSenderKey(_ key: Data, address: SignalAddress?, groupId: String?) -> Bool { false }
    func loadSenderKey(forAddress address: SignalAddress?, groupId: String?) -> Data? { nil }
}

final class SwitchOMEMOStorage: SignalStorage {
    private weak var context: Context?
    private var signalContext: SignalContext?

    init(context: Context) {
        self.context = context

        let identityStore = SwitchSignalIdentityKeyStore()
        identityStore.context = context

        let sessionStore = SwitchSignalSessionStore()
        sessionStore.context = context

        let preKeyStore = SwitchSignalPreKeyStore()
        preKeyStore.context = context

        let signedStore = SwitchSignalSignedPreKeyStore()
        signedStore.context = context

        super.init(
            sessionStore: sessionStore,
            preKeyStore: preKeyStore,
            signedPreKeyStore: signedStore,
            identityKeyStore: identityStore,
            senderKeyStore: SwitchSignalSenderKeyStore()
        )
    }

    override func setup(withContext signalContext: SignalContext) {
        self.signalContext = signalContext
        _ = regenerateKeys(wipe: false)
        super.setup(withContext: signalContext)
    }

    override func regenerateKeys(wipe: Bool = false) -> Bool {
        guard let context,
              let signalContext,
              let identityStore = identityKeyStore as? SwitchSignalIdentityKeyStore else {
            return false
        }

        guard let account = context.sessionObject.userBareJid else { return false }
        let backend = PersistedOMEMOBackend(account: account)
        let hasIdentity = identityStore.keyPair() != nil

        if wipe || backend.localRegistrationId() == 0 || !hasIdentity {
            let regId = signalContext.generateRegistrationId()
            guard regId > 0 else { return false }
            backend.setLocalRegistrationId(regId)

            guard let keyPair = SignalIdentityKeyPair.generateKeyPair(context: signalContext) else {
                return false
            }

            backend.saveLocalIdentityKeyPair(keyPair)
            _ = identityStore.save(
                identity: SignalAddress(name: account.stringValue, deviceId: Int32(regId)),
                key: keyPair
            )
        }

        return true
    }
}

final class SwitchAESGCMEngine: AES_GCM_Engine {
    func encrypt(iv: Data, key: Data, message: Data, output: UnsafeMutablePointer<Data>?, tag: UnsafeMutablePointer<Data>?) -> Bool {
        guard let nonce = try? AES.GCM.Nonce(data: iv) else {
            return false
        }
        let sk = SymmetricKey(data: key)

        guard let sealed = try? AES.GCM.seal(message, using: sk, nonce: nonce) else {
            return false
        }

        output?.pointee = sealed.ciphertext
        tag?.pointee = sealed.tag
        return true
    }

    func decrypt(iv: Data, key: Data, encoded: Data, auth tag: Data?, output: UnsafeMutablePointer<Data>?) -> Bool {
        guard let nonce = try? AES.GCM.Nonce(data: iv),
              let tag else {
            return false
        }
        let sk = SymmetricKey(data: key)

        guard let sealed = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: encoded, tag: tag),
              let plain = try? AES.GCM.open(sealed, using: sk) else {
            return false
        }
        output?.pointee = plain
        return true
    }
}
