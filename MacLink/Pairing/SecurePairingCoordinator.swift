import CryptoKit
import Foundation
import Observation

enum SecurePairingStatus: Equatable, Sendable {
    case idle
    case qrReady
    case verifyingPhone
    case awaitingApproval
    case paired
    case failed
}

@MainActor
@Observable
final class SecurePairingCoordinator {
    private(set) var status: SecurePairingStatus = .idle
    private(set) var qrPayload: String?
    private(set) var verificationCode: String?
    private(set) var pairedPhone: PairedPhoneRecord?
    private(set) var errorMessage: String?

    var sendMessage: ((Data) -> Void)?

    private let macDeviceID: UUID
    private let macName: String
    private let pairedPhoneStore: PairedPhoneStore
    private var session: Session?

    private struct Session {
        let pairingID: UUID
        var secret: Data
        let expiresAt: Int64
        let expectedPhone: PhonePresence
        let identity: MacPairingIdentity
        var phonePublicKeyDER: Data?
        var transcript: Data?
    }

    init(
        macDeviceID: UUID,
        macName: String,
        pairedPhoneStore: PairedPhoneStore = PairedPhoneStore()
    ) {
        self.macDeviceID = macDeviceID
        self.macName = macName
        self.pairedPhoneStore = pairedPhoneStore
    }

    func begin(for phone: PhonePresence) {
        do {
            let identity = try MacPairingIdentity()
            let secret = try PairingProtocol.secureRandomData(count: PairingProtocol.secretLength)
            let expiresAt = Int64(
                (Date().timeIntervalSince1970 + PairingProtocol.pairingWindowSeconds) * 1_000
            )
            let pairingID = UUID()
            let payload = PairingQRPayload(
                pairingID: pairingID,
                macDeviceID: macDeviceID,
                macName: macName,
                macPublicKeyFingerprint: identity.publicKeyFingerprint,
                secret: secret,
                expiresAt: expiresAt
            )
            session = Session(
                pairingID: pairingID,
                secret: secret,
                expiresAt: expiresAt,
                expectedPhone: phone,
                identity: identity
            )
            qrPayload = try payload.encodedString()
            verificationCode = nil
            errorMessage = nil
            status = .qrReady
        } catch {
            fail(error)
        }
    }

    func restorePairing(for phone: PhonePresence) {
        do {
            guard let record = try pairedPhoneStore.load(deviceID: phone.deviceID) else {
                if status == .paired { reset() }
                return
            }
            pairedPhone = record
            status = .paired
            errorMessage = nil
        } catch {
            fail(error)
        }
    }

    func handle(_ data: Data) {
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let kind = object["kind"] as? String else {
                throw PairingError.invalidMessage
            }
            switch kind {
            case "pairing_request": try handleRequest(JSONDecoder().decode(PairingRequest.self, from: data))
            case "pairing_proof": try handleProof(JSONDecoder().decode(PairingProof.self, from: data))
            default: throw PairingError.invalidMessage
            }
        } catch {
            try? send(PairingFailure(code: "pairing_failed"))
            fail(error)
        }
    }

    func approve() {
        do {
            guard let session,
                  status == .awaitingApproval,
                  let phonePublicKeyDER = session.phonePublicKeyDER,
                  let transcript = session.transcript else {
                throw PairingError.noActivePairing
            }
            let record = PairedPhoneRecord(
                deviceID: session.expectedPhone.deviceID,
                deviceName: session.expectedPhone.deviceName,
                publicKey: phonePublicKeyDER.base64URLEncodedString(),
                pairedAt: Int64(Date().timeIntervalSince1970 * 1_000)
            )
            try pairedPhoneStore.save(record)
            try sendResult(approved: true, session: session, transcript: transcript)
            pairedPhone = record
            qrPayload = nil
            verificationCode = nil
            self.session = nil
            status = .paired
        } catch {
            fail(error)
        }
    }

    func reject() {
        if let session, let transcript = session.transcript {
            try? sendResult(approved: false, session: session, transcript: transcript)
        }
        reset()
    }

    func reset() {
        session = nil
        qrPayload = nil
        verificationCode = nil
        errorMessage = nil
        pairedPhone = nil
        status = .idle
    }

    private func handleRequest(_ request: PairingRequest) throws {
        guard var session, status == .qrReady else { throw PairingError.noActivePairing }
        guard request.kind == "pairing_request",
              request.version == PairingProtocol.version,
              request.pairingID == session.pairingID,
              request.macDeviceID == macDeviceID,
              request.phoneDeviceID == session.expectedPhone.deviceID,
              request.phoneName == session.expectedPhone.deviceName,
              request.phoneName.count <= PhonePresence.maximumDeviceNameLength,
              Date().timeIntervalSince1970 * 1_000 <= Double(session.expiresAt),
              let phonePublicKeyDER = Data(base64URLEncoded: request.phonePublicKey),
              let phoneNonce = Data(base64URLEncoded: request.phoneNonce),
              phoneNonce.count == PairingProtocol.nonceLength,
              let proof = Data(base64URLEncoded: request.secretProof),
              proof.count == SHA256.byteCount else {
            throw PairingError.identityMismatch
        }

        _ = try P256.Signing.PublicKey(derRepresentation: phonePublicKeyDER)
        let key = SymmetricKey(data: session.secret)
        guard HMAC<SHA256>.isValidAuthenticationCode(
            proof,
            authenticating: request.proofData,
            using: key
        ) else { throw PairingError.proofFailed }

        let macNonce = try PairingProtocol.secureRandomData(count: PairingProtocol.nonceLength)
        let macPublicKey = session.identity.publicKeyDER.base64URLEncodedString()
        let transcript = PairingProtocol.canonicalData([
            "maclink-pairing-transcript-v1",
            session.pairingID.uuidString.lowercased(),
            macDeviceID.uuidString.lowercased(),
            request.phoneDeviceID.uuidString.lowercased(),
            macPublicKey,
            request.phonePublicKey,
            macNonce.base64URLEncodedString(),
            request.phoneNonce,
        ])
        let signature = try session.identity.privateKey.signature(for: transcript)
        let challenge = PairingChallenge(
            pairingID: session.pairingID,
            macPublicKey: macPublicKey,
            macNonce: macNonce.base64URLEncodedString(),
            macSignature: signature.derRepresentation.base64URLEncodedString()
        )

        session.secret = Data()
        session.phonePublicKeyDER = phonePublicKeyDER
        session.transcript = transcript
        self.session = session
        status = .verifyingPhone
        try send(challenge)
    }

    private func handleProof(_ proof: PairingProof) throws {
        guard let session,
              status == .verifyingPhone,
              proof.kind == "pairing_proof",
              proof.version == PairingProtocol.version,
              proof.pairingID == session.pairingID,
              proof.phoneDeviceID == session.expectedPhone.deviceID,
              let publicKeyDER = session.phonePublicKeyDER,
              let transcript = session.transcript,
              let signatureDER = Data(base64URLEncoded: proof.phoneSignature) else {
            throw PairingError.invalidMessage
        }
        let publicKey = try P256.Signing.PublicKey(derRepresentation: publicKeyDER)
        let signature = try P256.Signing.ECDSASignature(derRepresentation: signatureDER)
        guard publicKey.isValidSignature(signature, for: transcript) else {
            throw PairingError.proofFailed
        }

        verificationCode = PairingProtocol.verificationCode(for: transcript)
        status = .awaitingApproval
    }

    private func sendResult(approved: Bool, session: Session, transcript: Data) throws {
        let transcriptHash = Data(SHA256.hash(data: transcript)).base64URLEncodedString()
        let decision = approved ? "approved" : "rejected"
        let signedData = PairingProtocol.canonicalData([
            "maclink-pairing-result-v1",
            session.pairingID.uuidString.lowercased(),
            transcriptHash,
            decision,
        ])
        let signature = try session.identity.privateKey.signature(for: signedData)
        try send(PairingResult(
            pairingID: session.pairingID,
            approved: approved,
            macSignature: signature.derRepresentation.base64URLEncodedString()
        ))
    }

    private func send<T: Encodable>(_ message: T) throws {
        guard let sendMessage else { throw PairingError.noActivePairing }
        sendMessage(try JSONEncoder().encode(message))
    }

    private func fail(_ error: Error) {
        session = nil
        qrPayload = nil
        verificationCode = nil
        errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        status = .failed
    }
}
