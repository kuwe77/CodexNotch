import SwiftUI

@main
struct CodexNotchApp: App {
    @NSApplicationDelegateAdaptor(CodexNotchAppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            CodexNotchSettingsView()
                .environmentObject(TelemetryCoordinator.shared)
        }
    }
}
