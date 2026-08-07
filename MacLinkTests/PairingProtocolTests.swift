import Foundation
import Testing
@testable import MacLink

struct PairingProtocolTests {
    @Test
    func canonicalEncodingMatchesTheCrossPlatformVector() {
        let data = PairingProtocol.canonicalData(["alpha", "β", ""])

        #expect(data.hexString == "00000005616c70686100000002ceb200000000")
        #expect(PairingProtocol.verificationCode(for: data) == "511293")
    }

    @Test
    func pairingQrPayloadRoundTrips() throws {
        let pairingID = UUID()
        let macID = UUID()
        let payload = PairingQRPayload(
            pairingID: pairingID,
            macDeviceID: macID,
            macName: "Test Mac",
            macPublicKeyFingerprint: Data(repeating: 7, count: 32),
            secret: Data(repeating: 9, count: 32),
            expiresAt: 1_786_032_934_000
        )

        let decoded = try PairingQRPayload.decode(payload.encodedString())

        #expect(decoded == payload)
        #expect(decoded.pairingID == pairingID)
        #expect(decoded.macDeviceID == macID)
    }
}

private extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
