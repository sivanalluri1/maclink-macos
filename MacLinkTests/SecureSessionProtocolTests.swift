import CryptoKit
import Foundation
import Testing
@testable import MacLink

struct SecureSessionProtocolTests {
    @Test
    func hkdfMatchesTheCrossPlatformVector() {
        let material = SecureSessionProtocol.hkdfFixtureMaterial(
            inputKeyMaterial: Data(0..<32),
            salt: Data(32..<64),
            label: "maclink-client-to-mac-key-v1",
            outputByteCount: 32
        )
        #expect(material.map { String(format: "%02x", $0) }.joined() ==
            "542fb5dd0756a26b7478320c830c9609278e20465b9ea9a0ef1e9db96a1f10a5")
    }

    @Test
    func sequenceProducesUniqueTwelveByteNonces() throws {
        let prefix = Data([0x01, 0x02, 0x03, 0x04])
        let first = try SecureSessionProtocol.nonce(prefix: prefix, sequence: 0)
        let second = try SecureSessionProtocol.nonce(prefix: prefix, sequence: 1)
        #expect(Data(first) == Data([1, 2, 3, 4, 0, 0, 0, 0, 0, 0, 0, 0]))
        #expect(Data(first) != Data(second))
    }

    @Test
    func authenticatedEncryptionRejectsTampering() throws {
        let key = SymmetricKey(size: .bits256)
        let nonce = try SecureSessionProtocol.nonce(
            prefix: Data([1, 2, 3, 4]),
            sequence: 0
        )
        let aad = Data("bound-session-metadata".utf8)
        let box = try AES.GCM.seal(
            Data("session.hello".utf8),
            using: key,
            nonce: nonce,
            authenticating: aad
        )
        do {
            _ = try AES.GCM.open(
                box,
                using: key,
                authenticating: Data("modified-session-metadata".utf8)
            )
            Issue.record("AES-GCM accepted modified authenticated metadata")
        } catch {
            #expect(error is CryptoKitError)
        }
    }
}
