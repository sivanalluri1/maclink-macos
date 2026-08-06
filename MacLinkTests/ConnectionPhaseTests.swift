import Testing
@testable import MacLink

struct ConnectionPhaseTests {
    @Test
    func supportsTheHappyPath() {
        let path: [ConnectionPhase] = [
            .stopped,
            .discovering,
            .connecting,
            .authenticating,
            .syncing,
            .connected
        ]

        for pair in zip(path, path.dropFirst()) {
            #expect(pair.0.canTransition(to: pair.1))
        }
    }

    @Test
    func rejectsSkippingAuthentication() {
        #expect(!ConnectionPhase.connecting.canTransition(to: .connected))
    }

    @Test
    func allowsStoppingFromEveryPhase() {
        for phase in ConnectionPhase.allCases {
            #expect(phase.canTransition(to: .stopped))
        }
    }

    @Test
    func recoveryReturnsToDiscovery() {
        #expect(ConnectionPhase.connected.canTransition(to: .recovering))
        #expect(ConnectionPhase.recovering.canTransition(to: .discovering))
    }
}

