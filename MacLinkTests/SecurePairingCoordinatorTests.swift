import CryptoKit
import Foundation
import Testing
@testable import MacLink

struct SecurePairingCoordinatorTests {
    @Test
    @MainActor
    func verifiesTheQrSecretAndMutualDeviceSignatures() throws {
        let macID = UUID()
        let phoneID = UUID()
        let phone = try PhonePresence(
            deviceID: phoneID,
            deviceName: "Test Android",
            appVersion: "0.1.0"
        )
        let coordinator = SecurePairingCoordinator(macDeviceID: macID, macName: "Test Mac")
        var outboundMessages: [Data] = []
        coordinator.sendMessage = { outboundMessages.append($0) }

        coordinator.begin(for: phone)
        let payload = try PairingQRPayload.decode(#require(coordinator.qrPayload))
        let secret = try #require(Data(base64URLEncoded: payload.secret))
        let phoneKey = P256.Signing.PrivateKey()
        let phonePublicKey = phoneKey.publicKey.derRepresentation.base64URLEncodedString()
        let phoneNonce = Data(repeating: 3, count: PairingProtocol.nonceLength)
            .base64URLEncodedString()
        var request = PairingRequest(
            kind: "pairing_request",
            version: 1,
            pairingID: payload.pairingID,
            macDeviceID: macID,
            phoneDeviceID: phoneID,
            phoneName: phone.deviceName,
            phonePublicKey: phonePublicKey,
            phoneNonce: phoneNonce,
            secretProof: ""
        )
        let proof = HMAC<SHA256>.authenticationCode(
            for: request.proofData,
            using: SymmetricKey(data: secret)
        )
        request = PairingRequest(
            kind: request.kind,
            version: request.version,
            pairingID: request.pairingID,
            macDeviceID: request.macDeviceID,
            phoneDeviceID: request.phoneDeviceID,
            phoneName: request.phoneName,
            phonePublicKey: request.phonePublicKey,
            phoneNonce: request.phoneNonce,
            secretProof: Data(proof).base64URLEncodedString()
        )

        coordinator.handle(try JSONEncoder().encode(request))

        let challenge = try JSONDecoder().decode(
            PairingChallenge.self,
            from: #require(outboundMessages.last)
        )
        let macPublicKeyDER = try #require(Data(base64URLEncoded: challenge.macPublicKey))
        #expect(Data(SHA256.hash(data: macPublicKeyDER)).base64URLEncodedString() ==
                payload.macPublicKeyFingerprint)
        let transcript = PairingProtocol.canonicalData([
            "maclink-pairing-transcript-v1",
            payload.pairingID.uuidString.lowercased(),
            macID.uuidString.lowercased(),
            phoneID.uuidString.lowercased(),
            challenge.macPublicKey,
            phonePublicKey,
            challenge.macNonce,
            phoneNonce,
        ])
        let macPublicKey = try P256.Signing.PublicKey(derRepresentation: macPublicKeyDER)
        let macSignature = try P256.Signing.ECDSASignature(
            derRepresentation: #require(Data(base64URLEncoded: challenge.macSignature))
        )
        #expect(macPublicKey.isValidSignature(macSignature, for: transcript))

        let phoneSignature = try phoneKey.signature(for: transcript)
        coordinator.handle(try JSONEncoder().encode(PairingProof(
            kind: "pairing_proof",
            version: 1,
            pairingID: payload.pairingID,
            phoneDeviceID: phoneID,
            phoneSignature: phoneSignature.derRepresentation.base64URLEncodedString()
        )))

        #expect(coordinator.status == .awaitingApproval)
        #expect(coordinator.verificationCode == PairingProtocol.verificationCode(for: transcript))
    }
}
