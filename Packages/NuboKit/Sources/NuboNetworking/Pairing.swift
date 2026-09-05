import CryptoKit
import Foundation

public struct PairingChallenge: Sendable {
    public let privateKey: P256.KeyAgreement.PrivateKey
    public let publicKey: Data
    public let nonce: Data

    public init() {
        let privateKey = P256.KeyAgreement.PrivateKey()
        self.privateKey = privateKey
        self.publicKey = privateKey.publicKey.x963Representation
        self.nonce = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
    }
}

public enum PairingError: Error {
    case invalidPeerKey
}

public enum PairingKeyAgreement {
    /// Commit before revealing keys to prevent adaptive short-code grinding.
    /// Sorted JSON binds names, IDs, version, nonces and ephemeral public keys.
    public static func commitment(for hello: PairingHello) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return Data(SHA256.hash(data: try encoder.encode(hello)))
    }

    public static func deriveSecret(
        local: PairingChallenge,
        peerPublicKey: Data,
        peerNonce: Data,
        localCommitment: Data = Data(),
        peerCommitment: Data = Data()
    ) throws -> (secret: Data, confirmationCode: String) {
        let publicKey: P256.KeyAgreement.PublicKey
        do {
            publicKey = try P256.KeyAgreement.PublicKey(x963Representation: peerPublicKey)
        } catch {
            throw PairingError.invalidPeerKey
        }
        let shared = try local.privateKey.sharedSecretFromKeyAgreement(with: publicKey)
        let parts: [Data] = local.publicKey.lexicographicallyPrecedes(peerPublicKey)
            ? [local.publicKey, peerPublicKey, local.nonce, peerNonce, localCommitment, peerCommitment]
            : [peerPublicKey, local.publicKey, peerNonce, local.nonce, peerCommitment, localCommitment]
        var transcript = Data()
        for part in parts { transcript.append(part) }
        let key = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: transcript,
            sharedInfo: Data("Nubo pairing v1".utf8),
            outputByteCount: 32
        )
        let secret = key.withUnsafeBytes { Data($0) }
        let digest = SHA256.hash(data: transcript + secret)
        let number = digest.prefix(4).reduce(UInt32.zero) { ($0 << 8) | UInt32($1) } % 1_000_000
        return (secret, String(format: "%06u", number))
    }
}
