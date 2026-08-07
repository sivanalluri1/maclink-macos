import SwiftUI

struct ContentView: View {
    @Environment(ConnectionModel.self) private var connection

    var body: some View {
        NavigationSplitView {
            List {
                Label("Overview", systemImage: "rectangle.grid.1x2")
                Label("Notifications", systemImage: "bell")
                    .foregroundStyle(.secondary)
                Label("Files", systemImage: "folder")
                    .foregroundStyle(.secondary)
            }
            .navigationTitle("MacLink")
            .frame(minWidth: 210)
        } detail: {
            VStack(spacing: 24) {
                Spacer()

                Image(systemName: connection.phase.systemImage)
                    .font(.system(size: 64))
                    .foregroundStyle(statusColor)
                    .symbolEffect(.pulse, isActive: connection.isSearching)

                VStack(spacing: 8) {
                    Text(connection.phase.title)
                        .font(.largeTitle.weight(.semibold))

                    Text(statusMessage)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 430)
                }

                if case .ready(let port) = connection.advertisementState {
                    Label("Visible on the local network • Port \(port)", systemImage: "bonjour")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                if let error = connection.lastError {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }

                if connection.phase == .stopped {
                    Button("Find Android Phone") {
                        connection.startDiscovery()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                } else {
                    Button("Stop") {
                        connection.stop()
                    }
                    .controlSize(.large)
                }

                Spacer()

                Text("Local-first • End-to-end encrypted")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
            .padding(40)
            .navigationTitle("Overview")
        }
    }

    private var statusMessage: String {
        switch connection.phase {
        case .stopped:
            "Pair your Android phone to mirror notifications, share files, and keep both devices in sync."
        case .discovering:
            "Waiting for MacLink Companion to find this Mac on your local network."
        case .connecting:
            "Opening a secure connection to your phone."
        case .authenticating:
            "Verifying the paired device."
        case .syncing:
            "Bringing your devices up to date."
        case .connected:
            "Your Android phone is connected securely."
        case .recovering:
            "The connection was interrupted. MacLink is reconnecting."
        }
    }

    private var statusColor: Color {
        switch connection.phase {
        case .connected: .green
        case .recovering: .orange
        case .stopped: .secondary
        default: .accentColor
        }
    }
}

#Preview {
    ContentView()
        .environment(ConnectionModel())
        .frame(width: 820, height: 560)
}
