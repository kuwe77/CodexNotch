import Foundation

public enum AppMode {
    case codexNotch
}

public enum AppModeConfig {
    public static var current: AppMode = .codexNotch
}

public protocol SettingsWindowProvider {
    func showSettingsWindow()
}
