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
            ScrollView {
                VStack(spacing: 24) {

                Image(systemName: connection.phase.systemImage)
                    .font(.system(size: 64))
                    .foregroundStyle(statusColor)
                    .symbolEffect(.pulse, isActive: connection.isSearching)

                VStack(spacing: 8) {
                    Text(connection.detectedPhone == nil ? connection.phase.title : "Phone Detected")
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

                if let phone = connection.detectedPhone {
                    VStack(spacing: 8) {
                        Label(phone.deviceName, systemImage: "iphone")
                            .font(.title3.weight(.semibold))
                        Text("Android • MacLink Companion \(phone.appVersion) • \(trustLabel)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                    .frame(maxWidth: 430)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                }

                pairingContent

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
                } else if connection.detectedPhone == nil {
                    Button("Stop") {
                        connection.stop()
                    }
                    .controlSize(.large)
                }

                    Text(connection.detectedPhone == nil
                         ? "Local-first • Secure pairing pending"
                         : pairingFooter)
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, minHeight: 460)
                .padding(40)
            }
            .navigationTitle("Overview")
        }
    }

    @ViewBuilder
    private var pairingContent: some View {
        switch connection.pairing.status {
        case .idle:
            if connection.detectedPhone != nil {
                Button("Start Secure Pairing") {
                    connection.beginPairing()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        case .qrReady:
            if let payload = connection.pairing.qrPayload {
                VStack(spacing: 12) {
                    PairingQRCodeView(payload: payload)
                    Text("On Android, tap Scan Pairing QR")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("Cancel Pairing", role: .cancel) { connection.rejectPairing() }
                }
            }
        case .verifyingPhone:
            ProgressView("Verifying phone identity…")
        case .awaitingApproval:
            VStack(spacing: 12) {
                Text("Confirm this code matches your phone")
                    .font(.headline)
                Text(connection.pairing.verificationCode ?? "------")
                    .font(.system(size: 38, weight: .bold, design: .monospaced))
                    .textSelection(.enabled)
                HStack {
                    Button("Reject", role: .destructive) { connection.rejectPairing() }
                    Button("Approve Phone") { connection.approvePairing() }
                        .buttonStyle(.borderedProminent)
                }
            }
        case .paired:
            Label("Secure pairing saved", systemImage: "checkmark.shield.fill")
                .font(.headline)
                .foregroundStyle(.green)
        case .failed:
            VStack(spacing: 10) {
                Text(connection.pairing.errorMessage ?? "Secure pairing failed.")
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                Button("Try Pairing Again") { connection.beginPairing() }
            }
        }
    }

    private var statusMessage: String {
        if connection.pairing.status == .paired {
            return "This phone is paired. Encrypted session transport is the next phase."
        }
        if connection.detectedPhone != nil {
            return "Your phone reached this Mac and is ready for the secure pairing phase."
        }

        return switch connection.phase {
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

    private var trustLabel: String {
        connection.pairing.status == .paired ? "Paired" : "Unpaired"
    }

    private var pairingFooter: String {
        connection.pairing.status == .paired
            ? "Paired identity • Feature traffic still disabled"
            : "Unpaired • No private data exchanged"
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
