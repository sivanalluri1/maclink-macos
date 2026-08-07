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
    private static let maximumMessageSize = 16 * 1024

    init(descriptor: BonjourServiceDescriptor) {
        self.descriptor = descriptor
    }

    func start() {
        guard listener == nil else { return }

        do {
            let listener = try NWListener(using: .tcp, on: .any)
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
        var framed = message
        framed.append(0x0A)
        connection.send(content: framed, completion: .contentProcessed { [weak self, weak connection] error in
            guard error != nil else { return }
            Task { @MainActor in
                guard let self, let connection else { return }
                self.disconnectPhone(connection)
            }
        })
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
        receive(on: connection, buffer: Data(), didHandshake: false)
    }

    private func receive(on connection: NWConnection, buffer: Data, didHandshake: Bool) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4_096) {
            [weak self, weak connection] data, _, isComplete, error in
            Task { @MainActor in
                guard let self, let connection, connection === self.phoneConnection else { return }

                var nextBuffer = buffer
                if let data {
                    nextBuffer.append(data)
                }

                guard nextBuffer.count <= Self.maximumMessageSize else {
                    self.disconnectPhone(connection)
                    return
                }

                if !didHandshake, let newline = nextBuffer.firstIndex(of: 0x0A) {
                    let messageData = Data(nextBuffer[..<newline])
                    let remainder = Data(nextBuffer[nextBuffer.index(after: newline)...])
                    guard let presence = try? JSONDecoder().decode(PhonePresence.self, from: messageData) else {
                        self.disconnectPhone(connection)
                        return
                    }

                    self.onPhoneDetected?(presence)
                    self.sendAcknowledgement(on: connection)
                    self.receive(on: connection, buffer: remainder, didHandshake: true)
                    return
                }

                if didHandshake, let newline = nextBuffer.firstIndex(of: 0x0A) {
                    let messageData = Data(nextBuffer[..<newline])
                    let remainder = Data(nextBuffer[nextBuffer.index(after: newline)...])
                    guard !messageData.isEmpty else {
                        self.disconnectPhone(connection)
                        return
                    }
                    self.onPairingMessage?(messageData)
                    self.receive(on: connection, buffer: remainder, didHandshake: true)
                } else if isComplete || error != nil {
                    self.disconnectPhone(connection)
                } else {
                    self.receive(on: connection, buffer: nextBuffer, didHandshake: didHandshake)
                }
            }
        }
    }

    private func sendAcknowledgement(on connection: NWConnection) {
        let acknowledgement = PresenceAcknowledgement(
            macDeviceID: descriptor.deviceID,
            macName: descriptor.displayName
        )
        guard var data = try? JSONEncoder().encode(acknowledgement) else {
            disconnectPhone(connection)
            return
        }
        data.append(0x0A)
        connection.send(content: data, completion: .contentProcessed { [weak self, weak connection] error in
            guard error != nil else { return }
            Task { @MainActor in
                guard let self, let connection else { return }
                self.disconnectPhone(connection)
            }
        })
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
