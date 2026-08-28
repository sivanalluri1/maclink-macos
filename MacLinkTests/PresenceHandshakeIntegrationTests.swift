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
        let parameters = NWParameters.tcp
        let webSocket = NWProtocolWebSocket.Options(.version13)
        webSocket.autoReplyPing = true
        webSocket.maximumMessageSize = 1024 * 1024
        webSocket.setSubprotocols(["maclink.v1"])
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
        let endpoint = NWEndpoint.url(
            URL(string: "ws://127.0.0.1:\(port)/maclink")!
        )
        let connection = NWConnection(to: endpoint, using: parameters)
        connection.start(queue: .global())
        defer { connection.cancel() }

        let presence = try PhonePresence(
            deviceID: phoneID,
            deviceName: "Integration Phone",
            appVersion: "0.1.0"
        )
        let request = try JSONEncoder().encode(presence)
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(
            identifier: "test.websocket.message",
            metadata: [metadata]
        )
        connection.send(
            content: request,
            contentContext: context,
            isComplete: true,
            completion: .contentProcessed { _ in }
        )

        let response = try await receiveMessage(from: connection)
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

    private func receiveMessage(from connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Data, any Error>) in
            connection.receiveMessage { data, context, _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data,
                          data.count <= 8 * 1024,
                          let metadata = context?.protocolMetadata(
                            definition: NWProtocolWebSocket.definition
                          ) as? NWProtocolWebSocket.Metadata,
                          metadata.opcode == .text {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: IntegrationTestError.closed)
                }
            }
        }
    }
}

private enum IntegrationTestError: Error {
    case failed(String)
    case timedOut
    case closed
    case oversized
}
