import CryptoKit
import Foundation
import Security

enum PairingProtocol {
    static let version = 1
    static let qrPrefix = "maclink-pairing-v1:"
    static let secretLength = 32
    static let nonceLength = 32
    static let pairingWindowSeconds: TimeInterval = 120

    static func canonicalData(_ parts: [String]) -> Data {
        var result = Data()
        for part in parts {
            let bytes = Data(part.utf8)
            var length = UInt32(bytes.count).bigEndian
            withUnsafeBytes(of: &length) { result.append(contentsOf: $0) }
            result.append(bytes)
        }
        return result
    }

    static func secureRandomData(count: Int) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, count, bytes.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw PairingError.keyGenerationFailed(status)
        }
        return data
    }

    static func verificationCode(for transcript: Data) -> String {
        let digest = SHA256.hash(data: transcript)
        let value = digest.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return String(format: "%06d", value % 1_000_000)
    }
}

struct PairingQRPayload: Codable, Equatable, Sendable {
    let kind: String
    let version: Int
    let pairingID: UUID
    let macDeviceID: UUID
    let macName: String
    let macPublicKeyFingerprint: String
    let secret: String
    let expiresAt: Int64

    private enum CodingKeys: String, CodingKey {
        case kind
        case version
        case pairingID = "pairingId"
        case macDeviceID = "macDeviceId"
        case macName
        case macPublicKeyFingerprint
        case secret
        case expiresAt
    }

    init(
        pairingID: UUID,
        macDeviceID: UUID,
        macName: String,
        macPublicKeyFingerprint: Data,
        secret: Data,
        expiresAt: Int64
    ) {
        self.kind = "pairing_qr"
        self.version = PairingProtocol.version
        self.pairingID = pairingID
        self.macDeviceID = macDeviceID
        self.macName = macName
        self.macPublicKeyFingerprint = macPublicKeyFingerprint.base64URLEncodedString()
        self.secret = secret.base64URLEncodedString()
        self.expiresAt = expiresAt
    }

    func encodedString() throws -> String {
        PairingProtocol.qrPrefix + (try JSONEncoder().encode(self)).base64URLEncodedString()
    }

    static func decode(_ value: String) throws -> PairingQRPayload {
        guard value.hasPrefix(PairingProtocol.qrPrefix),
              let data = Data(base64URLEncoded: String(value.dropFirst(PairingProtocol.qrPrefix.count))) else {
            throw PairingError.invalidQRPayload
        }
        let payload = try JSONDecoder().decode(Self.self, from: data)
        guard payload.kind == "pairing_qr",
              payload.version == PairingProtocol.version,
              Data(base64URLEncoded: payload.secret)?.count == PairingProtocol.secretLength,
              Data(base64URLEncoded: payload.macPublicKeyFingerprint)?.count == SHA256.byteCount else {
            throw PairingError.invalidQRPayload
        }
        return payload
    }
}

struct PairingRequest: Codable, Sendable {
    let kind: String
    let version: Int
    let pairingID: UUID
    let macDeviceID: UUID
    let phoneDeviceID: UUID
    let phoneName: String
    let phonePublicKey: String
    let phoneNonce: String
    let secretProof: String

    private enum CodingKeys: String, CodingKey {
        case kind
        case version
        case pairingID = "pairingId"
        case macDeviceID = "macDeviceId"
        case phoneDeviceID = "phoneDeviceId"
        case phoneName
        case phonePublicKey
        case phoneNonce
        case secretProof
    }

    var proofData: Data {
        PairingProtocol.canonicalData([
            "maclink-pairing-request-v1",
            pairingID.uuidString.lowercased(),
            macDeviceID.uuidString.lowercased(),
            phoneDeviceID.uuidString.lowercased(),
            phoneName,
            phonePublicKey,
            phoneNonce,
        ])
    }
}

struct PairingChallenge: Codable, Sendable {
    let kind = "pairing_challenge"
    let version = PairingProtocol.version
    let pairingID: UUID
    let macPublicKey: String
    let macNonce: String
    let macSignature: String

    private enum CodingKeys: String, CodingKey {
        case kind
        case version
        case pairingID = "pairingId"
        case macPublicKey
        case macNonce
        case macSignature
    }
}

struct PairingProof: Codable, Sendable {
    let kind: String
    let version: Int
    let pairingID: UUID
    let phoneDeviceID: UUID
    let phoneSignature: String

    private enum CodingKeys: String, CodingKey {
        case kind
        case version
        case pairingID = "pairingId"
        case phoneDeviceID = "phoneDeviceId"
        case phoneSignature
    }
}

struct PairingResult: Codable, Sendable {
    let kind = "pairing_result"
    let version = PairingProtocol.version
    let pairingID: UUID
    let approved: Bool
    let macSignature: String

    private enum CodingKeys: String, CodingKey {
        case kind
        case version
        case pairingID = "pairingId"
        case approved
        case macSignature
    }
}

struct PairingFailure: Codable, Sendable {
    let kind = "pairing_error"
    let version = PairingProtocol.version
    let code: String
}

struct PairedPhoneRecord: Codable, Equatable, Sendable {
    let deviceID: UUID
    let deviceName: String
    let publicKey: String
    let pairedAt: Int64
}

extension Data {
    init?(base64URLEncoded value: String) {
        var base64 = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64.append(String(repeating: "=", count: (4 - base64.count % 4) % 4))
        self.init(base64Encoded: base64)
    }

    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

enum PairingError: Error, LocalizedError {
    case invalidQRPayload
    case invalidMessage
    case pairingExpired
    case identityMismatch
    case proofFailed
    case noActivePairing
    case keyGenerationFailed(OSStatus)
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidQRPayload: "The pairing QR code is invalid."
        case .invalidMessage: "The phone sent an invalid pairing message."
        case .pairingExpired: "The pairing window expired. Start pairing again."
        case .identityMismatch: "The phone identity changed during pairing."
        case .proofFailed: "The device pairing proof could not be verified."
        case .noActivePairing: "There is no active pairing request."
        case .keyGenerationFailed: "MacLink could not generate secure random data."
        case .keychain: "MacLink could not access its Keychain pairing data."
        }
    }
}
