import Foundation
import Observation

@MainActor
@Observable
final class ConnectionModel {
    private(set) var phase: ConnectionPhase = .stopped
    private(set) var lastError: String?
    private(set) var advertisementState: BonjourAdvertisementState = .stopped

    private let advertiser: BonjourAdvertiser

    init(advertiser: BonjourAdvertiser? = nil) {
        let descriptor = BonjourServiceDescriptor(
            deviceID: DeviceIdentityStore().deviceID(),
            displayName: ProcessInfo.processInfo.hostName
        )
        let advertiser = advertiser ?? BonjourAdvertiser(descriptor: descriptor)
        self.advertiser = advertiser
        advertiser.onStateChange = { [weak self] state in
            self?.handleAdvertisementState(state)
        }
    }

    var isSearching: Bool {
        phase != .stopped && phase != .connected
    }

    func startDiscovery() {
        transition(to: .discovering)
        advertiser.start()
    }

    func stop() {
        advertiser.stop()
        transition(to: .stopped)
    }

    func transition(to next: ConnectionPhase) {
        guard phase.canTransition(to: next) else {
            lastError = "Invalid connection transition: \(phase.rawValue) → \(next.rawValue)"
            return
        }

        phase = next
        lastError = nil
    }

    private func handleAdvertisementState(_ state: BonjourAdvertisementState) {
        advertisementState = state

        if case .failed(let message) = state {
            lastError = message
            if phase != .stopped {
                phase = .stopped
            }
        }
    }
}
