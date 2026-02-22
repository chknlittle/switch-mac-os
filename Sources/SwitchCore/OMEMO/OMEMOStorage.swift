import Foundation
import Martin
import MartinOMEMO

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

        let account = context.userBareJid

        let repository = OMEMOStateRepository(account: account)
        let hasIdentity = identityStore.keyPair() != nil

        if wipe || repository.localRegistrationId() == 0 || !hasIdentity {
            let regId = signalContext.generateRegistrationId()
            guard regId > 0 else { return false }
            repository.setLocalRegistrationId(regId)

            guard let keyPair = SignalIdentityKeyPair.generateKeyPair(context: signalContext) else {
                return false
            }

            repository.saveLocalIdentityKeyPair(keyPair)
            _ = identityStore.save(
                identity: SignalAddress(name: account.stringValue, deviceId: Int32(regId)),
                key: keyPair
            )
        }

        return true
    }
}
