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
    private(set) var secureSession: SecureSessionCoordinator

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
        let secureSession = SecureSessionCoordinator(
            macDeviceID: descriptor.deviceID,
            macName: descriptor.displayName
        )
        self.advertiser = advertiser
        self.pairing = pairing
        self.secureSession = secureSession
        advertiser.onStateChange = { [weak self] state in
            self?.handleAdvertisementState(state)
        }
        advertiser.onPhoneDetected = { [weak self] phone in
            self?.handlePhoneDetected(phone)
        }
        advertiser.onPhoneDisconnected = { [weak self] in
            self?.handlePhoneDisconnected()
        }
        advertiser.onPairingMessage = { [weak pairing, weak secureSession] data in
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let kind = object["kind"] as? String else { return }
            if kind == "session_client_hello" || kind == "secure_frame" {
                secureSession?.handle(data)
            } else {
                pairing?.handle(data)
            }
        }
        pairing.sendMessage = { [weak advertiser] data in
            advertiser?.sendPairingMessage(data)
        }
        secureSession.sendMessage = { [weak advertiser] data in
            advertiser?.sendPairingMessage(data)
        }
        secureSession.onConnected = { [weak self] in
            guard let self else { return }
            if self.phase == .authenticating {
                self.transition(to: .syncing)
                self.transition(to: .connected)
            }
        }
        secureSession.onFailure = { [weak advertiser] in
            advertiser?.terminatePhoneConnection()
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
        secureSession.reset()
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
        if pairing.status == .paired, let detectedPhone {
            secureSession.prepare(for: detectedPhone)
        }
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
        if pairing.status == .paired {
            if phase == .connecting {
                transition(to: .authenticating)
            }
            secureSession.prepare(for: phone)
        }
    }

    private func handlePhoneDisconnected() {
        detectedPhone = nil
        secureSession.reset()
        // Scanning is handled by a separate activity on Android. A transient TCP
        // disconnect must not invalidate the QR that the phone is still scanning.
        if pairing.status != .paired && pairing.status != .qrReady {
            pairing.reset()
        }
        if phase == .connecting || phase == .authenticating {
            phase = .discovering
        } else if phase == .syncing || phase == .connected {
            transition(to: .recovering)
        }
    }
}
