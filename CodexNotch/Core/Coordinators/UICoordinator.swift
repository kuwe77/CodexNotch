import AppKit
import SwiftUI
import Combine
import CoreGraphics

@MainActor
public final class UICoordinator: ObservableObject {
    public static let shared = UICoordinator()

    @Published var isExpanded: Bool = false
    @Published private(set) var hasNotch: Bool = false
    @Published private(set) var isVisible: Bool = true

    private var notchPanel: NotchPanel?
    private var menuBarController: MenuBarController?
    private var screenObserver: AnyCancellable?
    private var cancellables = Set<AnyCancellable>()

    private init() {}

    public func setupUI() {
        setupScreenObserver()

        let screen = NotchDisplaySelector.targetScreen()

        // Check for notch, preferred display, or force mode
        hasNotch = screen.map { NotchDetector.hasNotch(screen: $0) } ?? false

        if shouldShowNotchPanel(on: screen), let screen {
            setupNotchPanel(on: screen)
        }

        // Always setup menu bar as fallback/additional control
        setupMenuBar()
    }

    private func setupScreenObserver() {
        guard screenObserver == nil else { return }

        screenObserver = NotificationCenter.default
            .publisher(for: NSApplication.didChangeScreenParametersNotification)
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.handleScreenParametersChanged()
                }
            }
    }

    private func setupNotchPanel(on screen: NSScreen) {
        let frame = notchFrame(for: screen)

        let panel = NotchPanel(contentRect: frame)
        panel.setContent {
            if AppModeConfig.current == .codexNotch {
                CodexNotchContentView()
                    .environmentObject(TelemetryCoordinator.shared)
            } else {
                NotchContentView()
                    .environmentObject(MCPCoordinator.shared)
            }
        }

        // Add to the notch space for proper layering
        panel.addToNotchSpace()

        // Show the panel
        panel.orderFrontRegardless()

        notchPanel = panel
    }

    private func notchFrame(for screen: NSScreen) -> NSRect {
        let screenFrame = screen.frame

        // Window is fixed size, positioned at top center
        let windowX = screenFrame.origin.x + (screenFrame.width - windowSize.width) / 2
        let windowY = screenFrame.origin.y + screenFrame.height - windowSize.height

        return NSRect(
            x: windowX,
            y: windowY,
            width: windowSize.width,
            height: windowSize.height
        )
    }

    private func shouldShowNotchPanel(on screen: NSScreen?) -> Bool {
        guard let screen else { return false }

        return NotchDisplaySelector.isPreferredScreen(screen)
            || NotchDetector.hasNotch(screen: screen)
            || AppSettings.shared.forceNotchMode
    }

    private func handleScreenParametersChanged() {
        let screen = NotchDisplaySelector.targetScreen()
        hasNotch = screen.map { NotchDetector.hasNotch(screen: $0) } ?? false

        guard shouldShowNotchPanel(on: screen), let screen else {
            removeNotchPanel()
            return
        }

        if let notchPanel {
            notchPanel.setFrame(notchFrame(for: screen), display: true, animate: false)
            notchPanel.orderFrontRegardless()
        } else {
            setupNotchPanel(on: screen)
        }
    }

    private func removeNotchPanel() {
        notchPanel?.removeFromNotchSpace()
        notchPanel?.close()
        notchPanel = nil
    }

    private func setupMenuBar() {
        menuBarController = MenuBarController()
        menuBarController?.setup()
    }

    public func show() {
        isVisible = true
        notchPanel?.orderFront(nil)
    }

    public func hide() {
        isVisible = false
        notchPanel?.orderOut(nil)
    }

    public func cleanup() {
        removeNotchPanel()
        screenObserver?.cancel()
        screenObserver = nil
    }
}

@MainActor
private enum NotchDisplaySelector {
    static func targetScreen() -> NSScreen? {
        preferredScreen()
            ?? builtInScreen()
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    static func isPreferredScreen(_ screen: NSScreen) -> Bool {
        guard let preferredName = normalizedPreferredName else { return false }
        return normalized(screen.localizedName).contains(preferredName)
    }

    private static func preferredScreen() -> NSScreen? {
        guard normalizedPreferredName != nil else { return nil }
        return NSScreen.screens.first(where: isPreferredScreen)
    }

    private static var normalizedPreferredName: String? {
        let value = normalized(AppSettings.shared.preferredDisplayName)
        return value.isEmpty ? nil : value
    }

    private static func builtInScreen() -> NSScreen? {
        NSScreen.screens.first { screen in
            guard let displayID = displayID(for: screen) else { return false }
            return CGDisplayIsBuiltin(displayID) != 0
        }
    }

    private static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return CGDirectDisplayID(number.uint32Value)
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
