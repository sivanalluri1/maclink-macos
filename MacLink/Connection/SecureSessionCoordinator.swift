import CryptoKit
import Foundation
import Observation

enum SecureSessionStatus: Equatable, Sendable {
    case idle
    case authenticating
    case awaitingHello
    case connected
    case failed
}

@MainActor
@Observable
final class SecureSessionCoordinator {
    private(set) var status: SecureSessionStatus = .idle
    private(set) var sessionID: UUID?
    private(set) var errorMessage: String?
    private(set) var peerCapabilities: [String] = []

    var sendMessage: ((Data) -> Void)?
    var onConnected: (() -> Void)?
    var onFailure: (() -> Void)?

    private let macDeviceID: UUID
    private let macName: String
    private let identity: MacPairingIdentity?
    private let pairedPhoneStore: PairedPhoneStore
    private var expectedPhone: PhonePresence?
    private var keys: SecureSessionKeys?
    private var receiveSequence: UInt64 = 0
    private var sendSequence: UInt64 = 0

    init(
        macDeviceID: UUID,
        macName: String,
        pairedPhoneStore: PairedPhoneStore = PairedPhoneStore()
    ) {
        self.macDeviceID = macDeviceID
        self.macName = macName
        self.pairedPhoneStore = pairedPhoneStore
        self.identity = try? MacPairingIdentity()
    }

    func prepare(for phone: PhonePresence) {
        expectedPhone = phone
        keys = nil
        sessionID = nil
        receiveSequence = 0
        sendSequence = 0
        errorMessage = nil
        status = .authenticating
    }

    func reset() {
        expectedPhone = nil
        keys = nil
        sessionID = nil
        peerCapabilities = []
        receiveSequence = 0
        sendSequence = 0
        errorMessage = nil
        status = .idle
    }

    func handle(_ data: Data) {
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let kind = object["kind"] as? String else {
                throw SecureSessionError.invalidMessage
            }
            switch kind {
            case "session_client_hello":
                try handleClientHello(JSONDecoder().decode(SessionClientHello.self, from: data))
            case "secure_frame":
                try handleSecureFrame(JSONDecoder().decode(SecureFrame.self, from: data))
            default:
                throw SecureSessionError.invalidMessage
            }
        } catch {
            fail(error)
        }
    }

    private func handleClientHello(_ hello: SessionClientHello) throws {
        guard status == .authenticating,
              let expectedPhone,
              let identity,
              let pairedPhone = try pairedPhoneStore.load(deviceID: expectedPhone.deviceID),
              hello.kind == "session_client_hello",
              hello.version == SecureSessionProtocol.version,
              hello.protocolMin <= SecureSessionProtocol.version,
              hello.protocolMax >= SecureSessionProtocol.version,
              hello.phoneDeviceID == expectedPhone.deviceID,
              hello.macDeviceID == macDeviceID,
              let clientNonce = Data(base64URLEncoded: hello.clientNonce),
              clientNonce.count == SecureSessionProtocol.nonceLength,
              let ephemeralDER = Data(base64URLEncoded: hello.ephemeralPublicKey),
              let signatureDER = Data(base64URLEncoded: hello.signature),
              let pairedPublicKeyDER = Data(base64URLEncoded: pairedPhone.publicKey) else {
            throw SecureSessionError.notPaired
        }

        let phoneIdentity = try P256.Signing.PublicKey(derRepresentation: pairedPublicKeyDER)
        let phoneSignature = try P256.Signing.ECDSASignature(derRepresentation: signatureDER)
        guard phoneIdentity.isValidSignature(phoneSignature, for: hello.authenticationData) else {
            throw SecureSessionError.authenticationFailed
        }

        let clientEphemeral = try P256.KeyAgreement.PublicKey(derRepresentation: ephemeralDER)
        let serverEphemeral = P256.KeyAgreement.PrivateKey()
        let serverNonce = try PairingProtocol.secureRandomData(
            count: SecureSessionProtocol.nonceLength
        )
        let newSessionID = UUID()
        let transcript = PairingProtocol.canonicalData([
            SecureSessionProtocol.transcriptLabel,
            String(SecureSessionProtocol.version),
            hello.phoneDeviceID.uuidString.lowercased(),
            macDeviceID.uuidString.lowercased(),
            hello.ephemeralPublicKey,
            serverEphemeral.publicKey.derRepresentation.base64URLEncodedString(),
            hello.clientNonce,
            serverNonce.base64URLEncodedString(),
            newSessionID.uuidString.lowercased(),
            String(SecureSessionProtocol.version),
        ])
        let signature = try identity.privateKey.signature(for: transcript)
        let sharedSecret = try serverEphemeral.sharedSecretFromKeyAgreement(with: clientEphemeral)
        keys = SecureSessionKeys.derive(sharedSecret: sharedSecret, transcript: transcript)
        sessionID = newSessionID
        status = .awaitingHello

        let response = SessionServerHello(
            version: SecureSessionProtocol.version,
            sessionID: newSessionID,
            macDeviceID: macDeviceID,
            phoneDeviceID: hello.phoneDeviceID,
            ephemeralPublicKey: serverEphemeral.publicKey.derRepresentation.base64URLEncodedString(),
            serverNonce: serverNonce.base64URLEncodedString(),
            selectedProtocol: SecureSessionProtocol.version,
            signature: signature.derRepresentation.base64URLEncodedString()
        )
        try send(JSONEncoder().encode(response))
    }

    private func handleSecureFrame(_ frame: SecureFrame) throws {
        guard let keys, let sessionID,
              frame.kind == "secure_frame",
              frame.version == SecureSessionProtocol.version,
              frame.sessionID == sessionID,
              frame.direction == "client_to_mac",
              frame.contentType == "control",
              let sequence = UInt64(frame.sequence),
              sequence == receiveSequence,
              let ciphertext = Data(base64URLEncoded: frame.ciphertext),
              let tag = Data(base64URLEncoded: frame.tag),
              ciphertext.count <= SecureSessionProtocol.maximumPlaintextSize else {
            throw SecureSessionError.replayedFrame
        }
        let aad = frameAAD(
            sessionID: sessionID,
            sequence: sequence,
            direction: frame.direction,
            contentType: frame.contentType,
            plaintextSize: ciphertext.count
        )
        let box = try AES.GCM.SealedBox(
            nonce: SecureSessionProtocol.nonce(prefix: keys.clientNoncePrefix, sequence: sequence),
            ciphertext: ciphertext,
            tag: tag
        )
        let plaintext = try AES.GCM.open(box, using: keys.clientToMac, authenticating: aad)
        receiveSequence += 1
        let message = try JSONDecoder().decode(SessionControlMessage.self, from: plaintext)
        guard status == .awaitingHello,
              message.type == "session.hello",
              message.deviceID == expectedPhone?.deviceID,
              message.platform == "android",
              message.protocolVersion == SecureSessionProtocol.version else {
            throw SecureSessionError.authenticationFailed
        }
        peerCapabilities = message.capabilities
        let welcome = SessionControlMessage(
            type: "session.welcome",
            deviceID: macDeviceID,
            deviceName: macName,
            platform: "macos",
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0",
            protocolVersion: SecureSessionProtocol.version,
            capabilities: [],
            heartbeatIntervalSeconds: 20
        )
        try sendSecure(JSONEncoder().encode(welcome))
        status = .connected
        onConnected?()
    }

    private func sendSecure(_ plaintext: Data) throws {
        guard plaintext.count <= SecureSessionProtocol.maximumPlaintextSize,
              let keys, let sessionID else {
            throw SecureSessionError.payloadTooLarge
        }
        let sequence = sendSequence
        let aad = frameAAD(
            sessionID: sessionID,
            sequence: sequence,
            direction: "mac_to_client",
            contentType: "control",
            plaintextSize: plaintext.count
        )
        let box = try AES.GCM.seal(
            plaintext,
            using: keys.macToClient,
            nonce: SecureSessionProtocol.nonce(prefix: keys.macNoncePrefix, sequence: sequence),
            authenticating: aad
        )
        let frame = SecureFrame(
            version: SecureSessionProtocol.version,
            sessionID: sessionID,
            sequence: String(sequence),
            direction: "mac_to_client",
            contentType: "control",
            ciphertext: box.ciphertext.base64URLEncodedString(),
            tag: box.tag.base64URLEncodedString()
        )
        sendSequence += 1
        try send(JSONEncoder().encode(frame))
    }

    private func frameAAD(
        sessionID: UUID,
        sequence: UInt64,
        direction: String,
        contentType: String,
        plaintextSize: Int
    ) -> Data {
        PairingProtocol.canonicalData([
            SecureSessionProtocol.frameLabel,
            String(SecureSessionProtocol.version),
            sessionID.uuidString.lowercased(),
            direction,
            String(sequence),
            contentType,
            String(plaintextSize),
        ])
    }

    private func send(_ data: Data) throws {
        guard let sendMessage else { throw SecureSessionError.invalidMessage }
        sendMessage(data)
    }

    private func fail(_ error: Error) {
        keys = nil
        sessionID = nil
        errorMessage = error.localizedDescription
        status = .failed
        onFailure?()
    }
}
