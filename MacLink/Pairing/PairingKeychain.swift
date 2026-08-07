import CryptoKit
import Foundation
import Security

struct PairingKeychain {
    private let service = "com.sivanalluri.maclink.pairing"

    func load(account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw PairingError.keychain(status)
        }
        return data
    }

    func save(_ data: Data, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw PairingError.keychain(updateStatus)
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw PairingError.keychain(addStatus)
        }
    }
}

struct MacPairingIdentity {
    private static let account = "mac-signing-identity-v1"
    private let keychain: PairingKeychain
    let privateKey: P256.Signing.PrivateKey

    init(keychain: PairingKeychain = PairingKeychain()) throws {
        self.keychain = keychain
        if let stored = try keychain.load(account: Self.account) {
            privateKey = try P256.Signing.PrivateKey(rawRepresentation: stored)
        } else {
            let generated = P256.Signing.PrivateKey()
            try keychain.save(generated.rawRepresentation, account: Self.account)
            privateKey = generated
        }
    }

    var publicKeyDER: Data { privateKey.publicKey.derRepresentation }
    var publicKeyFingerprint: Data { Data(SHA256.hash(data: publicKeyDER)) }
}

struct PairedPhoneStore {
    private let keychain = PairingKeychain()

    func save(_ record: PairedPhoneRecord) throws {
        try keychain.save(
            JSONEncoder().encode(record),
            account: "paired-phone-\(record.deviceID.uuidString.lowercased())"
        )
    }

    func load(deviceID: UUID) throws -> PairedPhoneRecord? {
        guard let data = try keychain.load(
            account: "paired-phone-\(deviceID.uuidString.lowercased())"
        ) else { return nil }
        return try JSONDecoder().decode(PairedPhoneRecord.self, from: data)
    }
}
