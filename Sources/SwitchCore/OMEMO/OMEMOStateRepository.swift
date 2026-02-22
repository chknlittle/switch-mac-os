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

final class OMEMOStateRepository {
    private let path: URL
    private let queue = DispatchQueue(label: "switch.omemo.store", qos: .userInitiated)

    init(account: BareJID) {
        self.path = OMEMOPaths.accountStorePath(account: account)
        normalizeLegacyAddressKeysIfNeeded()
    }

    private func readState() -> PersistedOMEMOState {
        queue.sync {
            guard let data = try? Data(contentsOf: path) else { return .empty }
            return (try? JSONDecoder().decode(PersistedOMEMOState.self, from: data)) ?? .empty
        }
    }

    private func mutate(_ f: (inout PersistedOMEMOState) -> Void) {
        queue.sync {
            var state = readStateUnlocked()
            f(&state)
            writeStateUnlocked(state)
        }
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
        let normalized = normalizeAddressName(address.name)
        return readState().identities.first { normalizeAddressName($0.name) == normalized && $0.deviceId == address.deviceId }?.fingerprint
    }

    func identities(for name: String) -> [Identity] {
        let normalizedName = normalizeAddressName(name)
        readState().identities.compactMap { item in
            guard normalizeAddressName(item.name) == normalizedName,
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
        let normalized = normalizeAddressName(address.name)
        mutate { state in
            if let idx = state.identities.firstIndex(where: { normalizeAddressName($0.name) == normalized && $0.deviceId == address.deviceId }) {
                state.identities[idx].fingerprint = fingerprint
                state.identities[idx].keyBase64 = keyData.base64EncodedString()
                state.identities[idx].own = own
                state.identities[idx].name = normalized
                if state.identities[idx].statusRawValue == IdentityStatus.compromisedActive.rawValue ||
                    state.identities[idx].statusRawValue == IdentityStatus.compromisedInactive.rawValue {
                    state.identities[idx].statusRawValue = IdentityStatus.trustedActive.rawValue
                }
                return
            }

            state.identities.append(
                PersistedIdentity(
                    name: normalized,
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
        let normalized = normalizeAddressName(address.name)
        var updated = false
        mutate { state in
            guard let idx = state.identities.firstIndex(where: { normalizeAddressName($0.name) == normalized && $0.deviceId == address.deviceId }) else {
                return
            }
            state.identities[idx].statusRawValue = status.rawValue
            updated = true
        }
        return updated
    }

    func setStatus(active: Bool, for address: SignalAddress) -> Bool {
        let normalized = normalizeAddressName(address.name)
        var updated = false
        mutate { state in
            guard let idx = state.identities.firstIndex(where: { normalizeAddressName($0.name) == normalized && $0.deviceId == address.deviceId }) else {
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
        let normalized = normalizeAddressName(address.name)

        if let existing = readState().identities.first(where: { normalizeAddressName($0.name) == normalized && $0.deviceId == address.deviceId }) {
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

    func loadSession(address: SignalAddress) -> Data? {
        let state = readState()
        let key = sessionKey(for: address)
        let legacyKey = legacySessionKey(for: address)
        guard let value = state.sessions[key] ?? state.sessions[legacyKey] else { return nil }
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
        let normalizedName = normalizeAddressName(name)
        var changed = false
        mutate { state in
            let before = state.sessions.count
            state.sessions = state.sessions.filter {
                guard let pipe = $0.key.firstIndex(of: "|") else { return true }
                let rawName = String($0.key[..<pipe])
                return normalizeAddressName(rawName) != normalizedName
            }
            changed = before != state.sessions.count
        }
        return changed
    }

    func allDevices(for name: String, activeAndTrusted: Bool) -> [Int32] {
        let normalizedName = normalizeAddressName(name)
        let state = readState()
        let ids: Set<Int32> = Set(state.sessions.keys.compactMap { key in
            let parts = key.split(separator: "|", maxSplits: 1)
            guard parts.count == 2, normalizeAddressName(String(parts[0])) == normalizedName else { return nil }
            return Int32(parts[1])
        })

        if !activeAndTrusted {
            return Array(ids)
        }

        return ids.filter { deviceId in
            guard let identity = state.identities.first(where: { normalizeAddressName($0.name) == normalizedName && $0.deviceId == deviceId }) else {
                return true
            }
            guard let status = IdentityStatus(rawValue: identity.statusRawValue) else { return false }
            return status.isActive && status.trust != .compromised
        }
    }

    private func sessionKey(for address: SignalAddress) -> String {
        "\(normalizeAddressName(address.name))|\(address.deviceId)"
    }

    private func legacySessionKey(for address: SignalAddress) -> String {
        "\(address.name)|\(address.deviceId)"
    }

    private func normalizeAddressName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let slash = trimmed.firstIndex(of: "/") else { return trimmed }
        return String(trimmed[..<slash])
    }

    private func fingerprint(publicKey: Data) -> String {
        publicKey.map { String(format: "%02x", $0) }.joined()
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

    private func normalizeLegacyAddressKeysIfNeeded() {
        queue.sync {
            var state = readStateUnlocked()
            var didChange = false

            var byIdentityKey: [String: PersistedIdentity] = [:]
            for identity in state.identities {
                let normalizedName = normalizeAddressName(identity.name)
                let key = "\(normalizedName)|\(identity.deviceId)"
                if byIdentityKey[key] == nil {
                    var normalized = identity
                    if normalized.name != normalizedName {
                        normalized.name = normalizedName
                        didChange = true
                    }
                    byIdentityKey[key] = normalized
                } else {
                    didChange = true
                }
            }
            state.identities = Array(byIdentityKey.values)

            var normalizedSessions: [String: String] = [:]
            for (key, value) in state.sessions {
                let parts = key.split(separator: "|", maxSplits: 1)
                guard parts.count == 2 else {
                    normalizedSessions[key] = value
                    continue
                }
                let normalizedName = normalizeAddressName(String(parts[0]))
                let normalizedKey = "\(normalizedName)|\(parts[1])"
                if normalizedKey != key {
                    didChange = true
                }
                if normalizedSessions[normalizedKey] == nil {
                    normalizedSessions[normalizedKey] = value
                }
            }
            state.sessions = normalizedSessions

            if !didChange {
                return
            }
            writeStateUnlocked(state)
        }
    }
}

protocol OMEMOContextBacked {
    var context: Context? { get }
}

extension OMEMOContextBacked {
    var stateRepository: OMEMOStateRepository? {
        guard let account = context?.sessionObject.userBareJid else { return nil }
        return OMEMOStateRepository(account: account)
    }
}
