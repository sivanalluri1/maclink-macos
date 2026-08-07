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

    private let descriptor: BonjourServiceDescriptor
    private var listener: NWListener?

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
            listener.newConnectionHandler = { connection in
                connection.cancel()
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
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        onStateChange?(.stopped)
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

