import Observation

@MainActor
@Observable
final class ConnectionModel {
    private(set) var phase: ConnectionPhase = .stopped
    private(set) var lastError: String?

    var isSearching: Bool {
        phase != .stopped && phase != .connected
    }

    func startDiscovery() {
        transition(to: .discovering)
    }

    func stop() {
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
}

