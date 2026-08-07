import Foundation
import Network
import Testing
@testable import MacLink

struct PresenceHandshakeIntegrationTests {
    @Test
    @MainActor
    func acceptsPresenceAndReturnsAcknowledgement() async throws {
        let macID = UUID()
        let phoneID = UUID()
        let advertiser = BonjourAdvertiser(
            descriptor: BonjourServiceDescriptor(deviceID: macID, displayName: "Test Mac")
        )
        var advertisementState = BonjourAdvertisementState.stopped
        var detectedPhone: PhonePresence?
        advertiser.onStateChange = { advertisementState = $0 }
        advertiser.onPhoneDetected = { detectedPhone = $0 }
        advertiser.start()
        defer { advertiser.stop() }

        let port = try await waitForPort { advertisementState }
        let connection = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp
        )
        connection.start(queue: .global())
        defer { connection.cancel() }

        let presence = try PhonePresence(
            deviceID: phoneID,
            deviceName: "Integration Phone",
            appVersion: "0.1.0"
        )
        var request = try JSONEncoder().encode(presence)
        request.append(0x0A)
        connection.send(content: request, completion: .contentProcessed { _ in })

        let response = try await receiveLine(from: connection)
        let acknowledgement = try JSONSerialization.jsonObject(with: response) as? [String: Any]

        #expect(acknowledgement?["kind"] as? String == "presence_ack")
        #expect(acknowledgement?["version"] as? Int == 1)
        #expect(acknowledgement?["macDeviceId"] as? String == macID.uuidString)

        for _ in 0..<100 where detectedPhone == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(detectedPhone?.deviceID == phoneID)
        #expect(detectedPhone?.deviceName == "Integration Phone")
    }

    @MainActor
    private func waitForPort(
        state: () -> BonjourAdvertisementState
    ) async throws -> UInt16 {
        for _ in 0..<500 {
            switch state() {
            case .ready(let port): return port
            case .failed(let message): throw IntegrationTestError.failed(message)
            default: try await Task.sleep(for: .milliseconds(10))
            }
        }
        throw IntegrationTestError.timedOut
    }

    private func receiveLine(from connection: NWConnection) async throws -> Data {
        var buffer = Data()
        while buffer.count <= 8 * 1024 {
            let data: Data = try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Data, any Error>) in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 4_096) {
                    data, _, isComplete, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let data {
                        continuation.resume(returning: data)
                    } else if isComplete {
                        continuation.resume(throwing: IntegrationTestError.closed)
                    } else {
                        continuation.resume(returning: Data())
                    }
                }
            }
            buffer.append(data)
            if let newline = buffer.firstIndex(of: 0x0A) {
                return Data(buffer[..<newline])
            }
        }
        throw IntegrationTestError.oversized
    }
}

private enum IntegrationTestError: Error {
    case failed(String)
    case timedOut
    case closed
    case oversized
}
