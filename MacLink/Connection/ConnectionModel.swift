import Foundation
import Observation

@MainActor
@Observable
final class ConnectionModel {
    private(set) var phase: ConnectionPhase = .stopped
    private(set) var lastError: String?
    private(set) var advertisementState: BonjourAdvertisementState = .stopped
    private(set) var detectedPhone: PhonePresence?
    private(set) var pairing: SecurePairingCoordinator

    private let advertiser: BonjourAdvertiser

    init(advertiser: BonjourAdvertiser? = nil) {
        let descriptor = BonjourServiceDescriptor(
            deviceID: DeviceIdentityStore().deviceID(),
            displayName: ProcessInfo.processInfo.hostName
        )
        let advertiser = advertiser ?? BonjourAdvertiser(descriptor: descriptor)
        let pairing = SecurePairingCoordinator(
            macDeviceID: descriptor.deviceID,
            macName: descriptor.displayName
        )
        self.advertiser = advertiser
        self.pairing = pairing
        advertiser.onStateChange = { [weak self] state in
            self?.handleAdvertisementState(state)
        }
        advertiser.onPhoneDetected = { [weak self] phone in
            self?.handlePhoneDetected(phone)
        }
        advertiser.onPhoneDisconnected = { [weak self] in
            self?.handlePhoneDisconnected()
        }
        advertiser.onPairingMessage = { [weak pairing] data in
            pairing?.handle(data)
        }
        pairing.sendMessage = { [weak advertiser] data in
            advertiser?.sendPairingMessage(data)
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
        pairing.reset()
        transition(to: .stopped)
    }

    func beginPairing() {
        guard let detectedPhone else { return }
        if phase == .connecting {
            transition(to: .authenticating)
        }
        pairing.begin(for: detectedPhone)
    }

    func approvePairing() {
        pairing.approve()
    }

    func rejectPairing() {
        pairing.reject()
        if phase == .authenticating {
            phase = .connecting
        }
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
        pairing.restorePairing(for: phone)
        if phase == .discovering {
            transition(to: .connecting)
        }
    }

    private func handlePhoneDisconnected() {
        detectedPhone = nil
        // Scanning is handled by a separate activity on Android. A transient TCP
        // disconnect must not invalidate the QR that the phone is still scanning.
        if pairing.status != .paired && pairing.status != .qrReady {
            pairing.reset()
        }
        if phase == .connecting || phase == .authenticating {
            phase = .discovering
        }
    }
}
