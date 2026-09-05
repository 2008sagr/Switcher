import SwiftUI
import SwitcherCore

@main
struct SwitcherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView()
                .environmentObject(appState)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "keyboard")
                Text(appState.currentLayout)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
            }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(appState)
        }
    }
}
