import SwiftUI

@main
struct MacLinkApp: App {
    @State private var connectionModel = ConnectionModel()

    var body: some Scene {
        WindowGroup("MacLink") {
            ContentView()
                .environment(connectionModel)
                .frame(minWidth: 720, minHeight: 480)
        }
        .defaultSize(width: 820, height: 560)

        Settings {
            SettingsView()
                .environment(connectionModel)
        }
    }
}

