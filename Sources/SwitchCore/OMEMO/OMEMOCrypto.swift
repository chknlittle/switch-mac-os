import CryptoKit
import Foundation
import MartinOMEMO

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
