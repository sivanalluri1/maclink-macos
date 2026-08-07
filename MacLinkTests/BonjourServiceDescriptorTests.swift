import Foundation
import Testing
@testable import MacLink

struct BonjourServiceDescriptorTests {
    @Test
    func createsTheSharedServiceContract() {
        let id = UUID(uuidString: "BA751927-DF6C-4EC3-84A0-C4D9D7B707B4")!
        let descriptor = BonjourServiceDescriptor(deviceID: id, displayName: "Test Mac")
        let record = BonjourServiceDescriptor.decodeTXTRecord(descriptor.txtRecord)

        #expect(BonjourServiceDescriptor.serviceType == "_maclink._tcp")
        #expect(record["pv"] == "1")
        #expect(record["id"] == id.uuidString.lowercased())
        #expect(record["name"] == "Test Mac")
        #expect(record["pairing"] == "1")
    }

    @Test
    func limitsTheAdvertisedDisplayName() {
        let descriptor = BonjourServiceDescriptor(
            deviceID: UUID(),
            displayName: String(repeating: "a", count: 100)
        )

        let name = BonjourServiceDescriptor.decodeTXTRecord(descriptor.txtRecord)["name"]
        #expect(name?.count == 63)
    }
}

