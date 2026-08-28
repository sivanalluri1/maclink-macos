import CryptoKit
import Foundation

enum SecureSessionProtocol {
    static let version = 1
    static let clientAuthenticationLabel = "maclink-session-client-auth-v1"
    static let transcriptLabel = "maclink-session-transcript-v1"
    static let frameLabel = "maclink-secure-frame-v1"
    static let nonceLength = 32
    static let maximumPlaintextSize = 1024 * 1024

    static func nonce(prefix: Data, sequence: UInt64) throws -> AES.GCM.Nonce {
        guard prefix.count == 4 else { throw SecureSessionError.invalidMessage }
        var value = sequence.bigEndian
        var data = prefix
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        return try AES.GCM.Nonce(data: data)
    }

    static func hkdfFixtureMaterial(
        inputKeyMaterial: Data,
        salt: Data,
        label: String,
        outputByteCount: Int
    ) -> Data {
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: inputKeyMaterial),
            salt: salt,
            info: Data(label.utf8),
            outputByteCount: outputByteCount
        )
        return key.withUnsafeBytes { Data($0) }
    }
}

struct SessionClientHello: Codable, Sendable {
    let kind: String
    let version: Int
    let phoneDeviceID: UUID
    let macDeviceID: UUID
    let ephemeralPublicKey: String
    let clientNonce: String
    let protocolMin: Int
    let protocolMax: Int
    let signature: String

    private enum CodingKeys: String, CodingKey {
        case kind, version, ephemeralPublicKey, clientNonce, protocolMin, protocolMax, signature
        case phoneDeviceID = "phoneDeviceId"
        case macDeviceID = "macDeviceId"
    }

    var authenticationData: Data {
        PairingProtocol.canonicalData([
            SecureSessionProtocol.clientAuthenticationLabel,
            String(version),
            phoneDeviceID.uuidString.lowercased(),
            macDeviceID.uuidString.lowercased(),
            ephemeralPublicKey,
            clientNonce,
            String(protocolMin),
            String(protocolMax),
        ])
    }
}

struct SessionServerHello: Codable, Sendable {
    let kind = "session_server_hello"
    let version: Int
    let sessionID: UUID
    let macDeviceID: UUID
    let phoneDeviceID: UUID
    let ephemeralPublicKey: String
    let serverNonce: String
    let selectedProtocol: Int
    let signature: String

    private enum CodingKeys: String, CodingKey {
        case kind, version, ephemeralPublicKey, serverNonce, selectedProtocol, signature
        case sessionID = "sessionId"
        case macDeviceID = "macDeviceId"
        case phoneDeviceID = "phoneDeviceId"
    }
}

struct SecureFrame: Codable, Sendable {
    let kind = "secure_frame"
    let version: Int
    let sessionID: UUID
    let sequence: String
    let direction: String
    let contentType: String
    let ciphertext: String
    let tag: String

    private enum CodingKeys: String, CodingKey {
        case kind, version, sequence, direction, contentType, ciphertext, tag
        case sessionID = "sessionId"
    }
}

struct SessionControlMessage: Codable, Sendable {
    let type: String
    let deviceID: UUID
    let deviceName: String
    let platform: String
    let appVersion: String
    let protocolVersion: Int
    let capabilities: [String]
    let heartbeatIntervalSeconds: Int?

    private enum CodingKeys: String, CodingKey {
        case type, deviceName, platform, appVersion, protocolVersion, capabilities
        case deviceID = "deviceId"
        case heartbeatIntervalSeconds
    }
}

struct SecureSessionKeys: Sendable {
    let clientToMac: SymmetricKey
    let macToClient: SymmetricKey
    let clientNoncePrefix: Data
    let macNoncePrefix: Data

    static func derive(sharedSecret: SharedSecret, transcript: Data) -> Self {
        let salt = Data(SHA256.hash(data: transcript))
        func key(_ label: String) -> SymmetricKey {
            sharedSecret.hkdfDerivedSymmetricKey(
                using: SHA256.self,
                salt: salt,
                sharedInfo: Data(label.utf8),
                outputByteCount: 32
            )
        }
        func prefix(_ label: String) -> Data {
            let value = sharedSecret.hkdfDerivedSymmetricKey(
                using: SHA256.self,
                salt: salt,
                sharedInfo: Data(label.utf8),
                outputByteCount: 4
            )
            return value.withUnsafeBytes { Data($0) }
        }
        return Self(
            clientToMac: key("maclink-client-to-mac-key-v1"),
            macToClient: key("maclink-mac-to-client-key-v1"),
            clientNoncePrefix: prefix("maclink-client-nonce-v1"),
            macNoncePrefix: prefix("maclink-mac-nonce-v1")
        )
    }
}

enum SecureSessionError: Error, LocalizedError {
    case invalidMessage
    case notPaired
    case authenticationFailed
    case replayedFrame
    case payloadTooLarge

    var errorDescription: String? {
        switch self {
        case .invalidMessage: "The secure-session message is invalid."
        case .notPaired: "The phone is not paired with this Mac."
        case .authenticationFailed: "Secure-session authentication failed."
        case .replayedFrame: "A repeated or out-of-order secure frame was rejected."
        case .payloadTooLarge: "The secure-session payload is too large."
        }
    }
}
