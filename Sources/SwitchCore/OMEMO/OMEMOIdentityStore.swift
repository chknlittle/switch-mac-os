import Foundation
import Martin
import MartinOMEMO

final class SwitchSignalIdentityKeyStore: SignalIdentityKeyStoreProtocol, ContextAware, OMEMOContextBacked {
    weak var context: Context?

    func keyPair() -> SignalIdentityKeyPairProtocol? {
        stateRepository?.localIdentityKeyPair()
    }

    func localRegistrationId() -> UInt32 {
        stateRepository?.localRegistrationId() ?? 0
    }

    func save(identity: SignalAddress, key: SignalIdentityKeyProtocol?) -> Bool {
        guard let key else { return false }
        if let pair = key as? SignalIdentityKeyPairProtocol {
            stateRepository?.saveLocalIdentityKeyPair(pair)
        }
        guard let publicKey = key.publicKey else { return false }
        let fp = publicKey.map { String(format: "%02x", $0) }.joined()
        stateRepository?.upsertIdentity(address: identity, fingerprint: fp, keyData: key.serialized(), own: true)
        return true
    }

    func isTrusted(identity: SignalAddress, key: SignalIdentityKeyProtocol?) -> Bool {
        stateRepository?.isTrusted(address: identity, publicKeyData: key?.publicKey) ?? false
    }

    func save(identity: SignalAddress, publicKeyData: Data?) -> Bool {
        guard let publicKeyData else { return false }
        let fp = publicKeyData.map { String(format: "%02x", $0) }.joined()
        stateRepository?.upsertIdentity(address: identity, fingerprint: fp, keyData: publicKeyData, own: false)
        return true
    }

    func isTrusted(identity: SignalAddress, publicKeyData: Data?) -> Bool {
        stateRepository?.isTrusted(address: identity, publicKeyData: publicKeyData) ?? false
    }

    func setStatus(_ status: IdentityStatus, forIdentity: SignalAddress) -> Bool {
        stateRepository?.setStatus(status, for: forIdentity) ?? false
    }

    func setStatus(active: Bool, forIdentity: SignalAddress) -> Bool {
        stateRepository?.setStatus(active: active, for: forIdentity) ?? false
    }

    func identities(forName: String) -> [Identity] {
        stateRepository?.identities(for: forName) ?? []
    }

    func identityFingerprint(forAddress address: SignalAddress) -> String? {
        stateRepository?.identityFingerprint(for: address)
    }
}
