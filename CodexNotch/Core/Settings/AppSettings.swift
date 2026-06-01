import Foundation
import SwiftUI

@MainActor
public final class AppSettings: ObservableObject {
    public static let shared = AppSettings()

    @AppStorage("mcpBinaryPath") public var mcpBinaryPath: String = "/usr/local/bin/bridge4simulator-xcauto"
    @AppStorage("mcpHttpPort") public var mcpHttpPort: Int = 8765
    @AppStorage("mcpUseHTTP") public var mcpUseHTTP: Bool = true
    @AppStorage("autoStartMCP") public var autoStartMCP: Bool = true
    @AppStorage("autoRestartOnCrash") public var autoRestartOnCrash: Bool = true
    @AppStorage("maxRestartAttempts") public var maxRestartAttempts: Int = 5
    @AppStorage("showBuildNotifications") public var showBuildNotifications: Bool = true
    @AppStorage("recentToolCallsLimit") public var recentToolCallsLimit: Int = 10
    @AppStorage("forceNotchMode") public var forceNotchMode: Bool = true
    @AppStorage("telemetryOtlpPort") public var telemetryOtlpPort: Int = 4318
    @AppStorage("telemetryAutoStart") public var telemetryAutoStart: Bool = true
    @AppStorage("showMenuBarItem") public var showMenuBarItem: Bool = false
    @AppStorage("showNotchTokenCount") public var showNotchTokenCount: Bool = true
    @AppStorage("showNotchTokenBreakdown") public var showNotchTokenBreakdown: Bool = true
    @AppStorage("showNotchCost") public var showNotchCost: Bool = true
    @AppStorage("showMemeVideo") public var showMemeVideo: Bool = false
    @AppStorage("playCompletionSound") public var playCompletionSound: Bool = true
    @AppStorage("lastNotifiedCompletionId") public var lastNotifiedCompletionId: String = ""
    @AppStorage("memeGraceSeconds") public var memeGraceSeconds: Int = 30
    @AppStorage("memeVideoURL") public var memeVideoURL: String = ""
    @AppStorage("preferredDisplayName") public var preferredDisplayName: String = ""
    @AppStorage("showSourceCodex") public var showSourceCodex: Bool = true
    @AppStorage("showSourceClaudeCode") public var showSourceClaudeCode: Bool = true
    @AppStorage("showSourceUnknown") public var showSourceUnknown: Bool = false

    // Battery saver: 15 FPS on battery, 25 FPS when charging.
    @AppStorage("batterySaverEnabled") public var batterySaverEnabled: Bool = true

    // Claude Code JSONL session tracking.
    @AppStorage("enableClaudeCodeJSONL") public var enableClaudeCodeJSONL: Bool = true
    @AppStorage("showSessionDots") public var showSessionDots: Bool = true
    @AppStorage("showPermissionIndicator") public var showPermissionIndicator: Bool = true
    @AppStorage("showTodoList") public var showTodoList: Bool = true
    @AppStorage("showThinkingState") public var showThinkingState: Bool = true

    // Codex JSONL session tracking.
    @AppStorage("enableCodexJSONL") public var enableCodexJSONL: Bool = true
    @AppStorage("showCodexUsageInNotch") public var showCodexUsageInNotch: Bool = true

    // Context and display settings.
    @AppStorage("contextTokenLimit") public var contextTokenLimit: Int = 200_000
    @AppStorage("showContextProgress") public var showContextProgress: Bool = true
    /// Display mode: "list" for recent events list, "singular" for single detailed event.
    @AppStorage("toolDisplayMode") public var toolDisplayMode: String = "list"

    // Claude Usage quota tracking.
    @AppStorage("enableClaudeUsage") public var enableClaudeUsage: Bool = false
    @AppStorage("claudeUsageRefreshMode") public var claudeUsageRefreshMode: String = "smart"
    @AppStorage("claudeUsageRefreshInterval") public var claudeUsageRefreshInterval: Int = 180
    @AppStorage("showClaudeUsageInClosedNotch") public var showClaudeUsageInClosedNotch: Bool = true

    public var mcpConfiguration: MCPConfiguration {
        MCPConfiguration(
            binaryPath: mcpBinaryPath,
            httpPort: mcpHttpPort,
            transport: mcpUseHTTP ? .http : .stdio
        )
    }

    public init() {}
}
