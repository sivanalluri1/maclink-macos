import Foundation
import Observation

@MainActor
@Observable
final class ConnectionModel {
    private(set) var phase: ConnectionPhase = .stopped
    private(set) var lastError: String?
    private(set) var advertisementState: BonjourAdvertisementState = .stopped
    private(set) var detectedPhone: PhonePresence?

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
        advertiser.onPhoneDetected = { [weak self] phone in
            self?.handlePhoneDetected(phone)
        }
        advertiser.onPhoneDisconnected = { [weak self] in
            self?.handlePhoneDisconnected()
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
        detectedPhone = nil
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

    private func handlePhoneDetected(_ phone: PhonePresence) {
        detectedPhone = phone
        if phase == .discovering {
            transition(to: .connecting)
        }
    }

    private func handlePhoneDisconnected() {
        detectedPhone = nil
        if phase == .connecting {
            transition(to: .discovering)
        }
    }
}
