import Foundation
import Network

enum BonjourAdvertisementState: Equatable, Sendable {
    case stopped
    case starting
    case ready(port: UInt16)
    case failed(message: String)
}

@MainActor
final class BonjourAdvertiser {
    var onStateChange: ((BonjourAdvertisementState) -> Void)?
    var onPhoneDetected: ((PhonePresence) -> Void)?
    var onPhoneDisconnected: (() -> Void)?
    var onPairingMessage: ((Data) -> Void)?

    private let descriptor: BonjourServiceDescriptor
    private var listener: NWListener?
    private var phoneConnection: NWConnection?
    private static let maximumMessageSize = 1024 * 1024

    init(descriptor: BonjourServiceDescriptor) {
        self.descriptor = descriptor
    }

    func start() {
        guard listener == nil else { return }

        do {
            let parameters = NWParameters.tcp
            let webSocket = NWProtocolWebSocket.Options(.version13)
            webSocket.autoReplyPing = true
            webSocket.maximumMessageSize = Self.maximumMessageSize
            webSocket.setSubprotocols(["maclink.v1"])
            parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
            let listener = try NWListener(using: parameters, on: .any)
            listener.service = NWListener.Service(
                name: descriptor.serviceName,
                type: BonjourServiceDescriptor.serviceType,
                domain: nil,
                txtRecord: descriptor.txtRecord
            )
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    self?.accept(connection)
                }
            }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                Task { @MainActor in
                    self?.handle(state, listener: listener)
                }
            }

            self.listener = listener
            onStateChange?(.starting)
            listener.start(queue: .main)
        } catch {
            onStateChange?(.failed(message: error.localizedDescription))
        }
    }

    func stop() {
        phoneConnection?.cancel()
        phoneConnection = nil
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        onStateChange?(.stopped)
    }

    func sendPairingMessage(_ message: Data) {
        guard let connection = phoneConnection,
              message.count <= Self.maximumMessageSize else { return }
        send(message, opcode: .text, on: connection) { [weak self, weak connection] error in
            guard error != nil else { return }
            Task { @MainActor in
                guard let self, let connection else { return }
                self.disconnectPhone(connection)
            }
        }
    }

    func terminatePhoneConnection() {
        guard let phoneConnection else { return }
        disconnectPhone(phoneConnection)
    }

    private func accept(_ connection: NWConnection) {
        phoneConnection?.cancel()
        phoneConnection = connection

        connection.stateUpdateHandler = { [weak self, weak connection] state in
            Task { @MainActor in
                guard let self, let connection, connection === self.phoneConnection else { return }
                if case .failed = state {
                    self.disconnectPhone(connection)
                } else if case .cancelled = state {
                    self.disconnectPhone(connection)
                }
            }
        }
        connection.start(queue: .main)
        receive(on: connection, didHandshake: false)
    }

    private func receive(on connection: NWConnection, didHandshake: Bool) {
        connection.receiveMessage {
            [weak self, weak connection] data, context, _, error in
            Task { @MainActor in
                guard let self, let connection, connection === self.phoneConnection else { return }
                guard error == nil,
                      let data,
                      data.count <= Self.maximumMessageSize,
                      let metadata = context?.protocolMetadata(
                        definition: NWProtocolWebSocket.definition
                      ) as? NWProtocolWebSocket.Metadata else {
                    self.disconnectPhone(connection)
                    return
                }

                if metadata.opcode == .ping {
                    self.receive(on: connection, didHandshake: didHandshake)
                    return
                }
                guard metadata.opcode == .text || metadata.opcode == .binary else {
                    self.disconnectPhone(connection)
                    return
                }

                if !didHandshake {
                    guard metadata.opcode == .text,
                          let presence = try? JSONDecoder().decode(PhonePresence.self, from: data) else {
                        self.disconnectPhone(connection)
                        return
                    }

                    self.onPhoneDetected?(presence)
                    self.sendAcknowledgement(on: connection)
                    self.receive(on: connection, didHandshake: true)
                    return
                }

                self.onPairingMessage?(data)
                self.receive(on: connection, didHandshake: true)
            }
        }
    }

    private func sendAcknowledgement(on connection: NWConnection) {
        let acknowledgement = PresenceAcknowledgement(
            macDeviceID: descriptor.deviceID,
            macName: descriptor.displayName
        )
        guard let data = try? JSONEncoder().encode(acknowledgement) else {
            disconnectPhone(connection)
            return
        }
        send(data, opcode: .text, on: connection) { [weak self, weak connection] error in
            guard error != nil else { return }
            Task { @MainActor in
                guard let self, let connection else { return }
                self.disconnectPhone(connection)
            }
        }
    }

    private func send(
        _ data: Data,
        opcode: NWProtocolWebSocket.Opcode,
        on connection: NWConnection,
        completion: @escaping @Sendable (NWError?) -> Void
    ) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: opcode)
        let context = NWConnection.ContentContext(
            identifier: "maclink.websocket.message",
            metadata: [metadata]
        )
        connection.send(
            content: data,
            contentContext: context,
            isComplete: true,
            completion: .contentProcessed(completion)
        )
    }

    private func disconnectPhone(_ connection: NWConnection) {
        guard connection === phoneConnection else { return }
        connection.stateUpdateHandler = nil
        connection.cancel()
        phoneConnection = nil
        onPhoneDisconnected?()
    }

    private func handle(_ state: NWListener.State, listener: NWListener?) {
        guard listener === self.listener else { return }

        switch state {
        case .ready:
            guard let port = listener?.port?.rawValue else {
                stopWithError("Bonjour listener started without an assigned port.")
                return
            }
            onStateChange?(.ready(port: port))
        case .failed(let error):
            stopWithError(error.localizedDescription)
        case .cancelled:
            self.listener = nil
            onStateChange?(.stopped)
        default:
            break
        }
    }

    private func stopWithError(_ message: String) {
        listener?.cancel()
        listener = nil
        onStateChange?(.failed(message: message))
    }
}
