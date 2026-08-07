import Foundation

enum ConnectionPhase: String, CaseIterable, Sendable {
    case stopped
    case discovering
    case connecting
    case authenticating
    case syncing
    case connected
    case recovering

    var title: String {
        switch self {
        case .stopped: "Not Connected"
        case .discovering: "Looking for Phone"
        case .connecting: "Connecting"
        case .authenticating: "Authenticating"
        case .syncing: "Syncing"
        case .connected: "Connected"
        case .recovering: "Reconnecting"
        }
    }

    var systemImage: String {
        switch self {
        case .connected: "checkmark.circle.fill"
        case .recovering: "arrow.clockwise.circle.fill"
        case .stopped: "iphone.slash"
        default: "network"
        }
    }

    func canTransition(to next: ConnectionPhase) -> Bool {
        switch (self, next) {
        case (.stopped, .discovering),
             (.discovering, .connecting),
             (.connecting, .discovering),
             (.connecting, .authenticating),
             (.authenticating, .syncing),
             (.syncing, .connected),
             (.connected, .recovering),
             (.recovering, .discovering):
            true
        case (_, .stopped):
            true
        default:
            false
        }
    }
}
