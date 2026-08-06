import SwiftUI

struct SettingsView: View {
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("showNotificationPreviews") private var showNotificationPreviews = true

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch MacLink at login", isOn: $launchAtLogin)
            }

            Section("Privacy") {
                Toggle("Show notification previews", isOn: $showNotificationPreviews)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 260)
        .padding()
    }
}

