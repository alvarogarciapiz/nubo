import Foundation
import Security

public struct PairedCredential: Codable, Equatable, Sendable {
    public let peerID: UUID
    public let peerName: String
    public let sharedSecret: Data

    public init(peerID: UUID, peerName: String, sharedSecret: Data) {
        self.peerID = peerID
        self.peerName = peerName
        self.sharedSecret = sharedSecret
    }
}

public protocol CredentialStore: Sendable {
    func save(_ credential: PairedCredential) async throws
    func credential(for peerID: UUID) async throws -> PairedCredential?
    func remove(peerID: UUID) async throws
}

public enum CredentialStoreError: Error {
    case encodingFailed
    case keychain(OSStatus)
}

public actor KeychainCredentialStore: CredentialStore {
    private let service: String

    public init(service: String = "com.lvrpiz.nubo.pairing") {
        self.service = service
    }

    public func save(_ credential: PairedCredential) async throws {
        let data = try JSONEncoder().encode(credential)
        let query = baseQuery(peerID: credential.peerID)
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw CredentialStoreError.keychain(status) }
    }

    public func credential(for peerID: UUID) async throws -> PairedCredential? {
        var query = baseQuery(peerID: peerID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data else {
            throw CredentialStoreError.keychain(status)
        }
        return try JSONDecoder().decode(PairedCredential.self, from: data)
    }

    public func remove(peerID: UUID) async throws {
        let status = SecItemDelete(baseQuery(peerID: peerID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.keychain(status)
        }
    }

    private func baseQuery(peerID: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: peerID.uuidString
        ]
    }
}
