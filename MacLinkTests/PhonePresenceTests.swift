import Foundation
import Testing
@testable import MacLink

struct PhonePresenceTests {
    @Test
    func decodesAValidAndroidPresenceMessage() throws {
        let id = UUID()
        let data = Data("""
        {"kind":"device_presence","version":1,"deviceId":"\(id.uuidString)","deviceName":"Siva's Phone","platform":"android","appVersion":"0.1.0"}
        """.utf8)

        let presence = try JSONDecoder().decode(PhonePresence.self, from: data)

        #expect(presence.deviceID == id)
        #expect(presence.deviceName == "Siva's Phone")
        #expect(presence.appVersion == "0.1.0")
    }

    @Test
    func rejectsAnUnsupportedProtocolVersion() {
        let data = Data("""
        {"kind":"device_presence","version":2,"deviceId":"\(UUID().uuidString)","deviceName":"Phone","platform":"android","appVersion":"0.1.0"}
        """.utf8)

        #expect(throws: PhonePresenceError.self) {
            try JSONDecoder().decode(PhonePresence.self, from: data)
        }
    }

    @Test
    func rejectsAnOversizedDeviceName() {
        let name = String(repeating: "p", count: PhonePresence.maximumDeviceNameLength + 1)
        let data = Data("""
        {"kind":"device_presence","version":1,"deviceId":"\(UUID().uuidString)","deviceName":"\(name)","platform":"android","appVersion":"0.1.0"}
        """.utf8)

        #expect(throws: PhonePresenceError.self) {
            try JSONDecoder().decode(PhonePresence.self, from: data)
        }
    }
}
