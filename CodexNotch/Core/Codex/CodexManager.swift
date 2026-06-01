//
//  CodexManager.swift
//  CodexNotch
//
//  Created for OpenAI Codex CLI JSONL session integration
//

import Foundation
import Combine
import AppKit

// MARK: - Debug Logging (uses shared debugLog from ClaudeCodeManager)
// Note: debugLog is defined in ClaudeCodeManager.swift and available app-wide

@MainActor
final class CodexManager: ObservableObject {
    static let shared = CodexManager()

    // MARK: - Published Properties

    @Published private(set) var availableSessions: [CodexSession] = []
    @Published var selectedSession: CodexSession?
    @Published private(set) var state: CodexState = CodexState()

    /// Per-session state tracking
    @Published private(set) var sessionStates: [String: CodexState] = [:]
    @Published private(set) var lastTaskCompletion: CodexTaskCompletion?

    /// Track when we last had activity (for grace period)
    private var lastActivityTime: Date = Date.distantPast
    private let activityGracePeriod: TimeInterval = 1.0

    /// True if any session has activity
    var hasAnySessionActivity: Bool {
        pruneStaleActiveTurns()

        for sessionState in sessionStates.values {
            if sessionState.isActive {
                lastActivityTime = Date()
                return true
            }
        }
        if state.isActive {
            lastActivityTime = Date()
            return true
        }

        let timeSinceLastActivity = Date().timeIntervalSince(lastActivityTime)
        if timeSinceLastActivity < activityGracePeriod {
            return true
        }

        return false
    }

    var currentRateLimits: CodexRateLimits {
        if state.rateLimits.hasData {
            return state.rateLimits
        }

        if let selectedId = selectedSession?.id,
           let selectedState = sessionStates[selectedId],
           selectedState.rateLimits.hasData {
            return selectedState.rateLimits
        }

        for session in availableSessions {
            if let sessionState = sessionStates[session.id],
               sessionState.rateLimits.hasData {
                return sessionState.rateLimits
            }
        }

        return sessionStates.values
            .sorted {
                ($0.lastUpdateTime ?? .distantPast) > ($1.lastUpdateTime ?? .distantPast)
            }
            .first { $0.rateLimits.hasData }?
            .rateLimits ?? .empty
    }

    // MARK: - Private Properties

    private let codexDir: URL = {
        if let pw = getpwuid(getuid()), let home = pw.pointee.pw_dir {
            let homePath = String(cString: home)
            return URL(fileURLWithPath: homePath).appendingPathComponent(".codex")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }()

    private var sessionsDir: URL { codexDir.appendingPathComponent("sessions") }

    private var sessionScanTimer: Timer?
    private var sessionWatchers: [String: DispatchSourceFileSystemObject] = [:]
    private var sessionFileHandles: [String: FileHandle] = [:]
    private var sessionReadPositions: [String: UInt64] = [:]
    private var isLoadingHistoryBySession: [String: Bool] = [:]

    /// Track pending function calls for timing
    private var pendingFunctionCalls: [String: [String: Date]] = [:]  // sessionId -> (callId -> startTime)
    private var activeTurnSessionIds: Set<String> = []
    private var activeTurnLastEventTimes: [String: Date] = [:]
    private let staleActiveTurnTimeout: TimeInterval = 15 * 60

    /// Timer to detect idle state
    private var idleCheckTimer: Timer?
    private let idleCheckDelay: TimeInterval = 3.0

    // MARK: - Date Formatters

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    // MARK: - Initialization

    private init() {
        debugLog("[Codex] ========================================")
        debugLog("[Codex] CodexManager initializing...")
        debugLog("[Codex] Codex dir: \(codexDir.path)")
        debugLog("[Codex] Sessions dir: \(sessionsDir.path)")
        debugLog("[Codex] ========================================")
        startSessionScanning()
    }

    // MARK: - Public Methods

    /// Scan for active Codex sessions
    func scanForSessions() {
        let fm = FileManager.default
        var sessions: [CodexSession] = []

        debugLog("[Codex] Scanning for sessions...")

        guard fm.fileExists(atPath: sessionsDir.path) else {
            debugLog("[Codex] Sessions directory does not exist")
            availableSessions = []
            return
        }

        // Codex stores sessions as: ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl
        // Keep quiet long-running Codex Desktop turns visible instead of dropping them after a few minutes.
        let recentThreshold = Date().addingTimeInterval(-12 * 60 * 60)

        let enumerator = fm.enumerator(
            at: sessionsDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )

        while let fileURL = enumerator?.nextObject() as? URL {
            guard fileURL.pathExtension == "jsonl",
                  fileURL.lastPathComponent.hasPrefix("rollout-") else {
                continue
            }

            let attrs = try? fm.attributesOfItem(atPath: fileURL.path)
            let modDate = attrs?[.modificationDate] as? Date ?? .distantPast

            if modDate > recentThreshold {
                // Parse session_meta from file to get session info
                if let session = parseSessionFromFile(fileURL) {
                    debugLog("[Codex] Found session: \(session.displayName) (id: \(session.id.prefix(8))...)")
                    sessions.append(session)
                }
            }
        }

        // Sort by timestamp (most recent first)
        sessions.sort { $0.timestamp > $1.timestamp }

        debugLog("[Codex] Total sessions found: \(sessions.count)")
        availableSessions = sessions

        // Auto-select first session if none selected
        if selectedSession == nil && sessions.count == 1 {
            selectSession(sessions[0])
        }

        // Clear selected session if no longer available
        if let selected = selectedSession,
           !sessions.contains(where: { $0.id == selected.id }) {
            selectedSession = nil
            state = CodexState()
        }

        // Watch all sessions
        let currentSessionIds = Set(sessions.map { $0.id })

        for session in sessions {
            if sessionWatchers[session.id] == nil {
                startWatchingSession(session)
            }
        }

        // Stop watching sessions that are no longer active
        let watchedIds = Array(sessionWatchers.keys)
        for watchedId in watchedIds where !currentSessionIds.contains(watchedId) {
            stopWatchingSession(id: watchedId)
        }
    }

    /// Select a session to monitor
    func selectSession(_ session: CodexSession) {
        guard session != selectedSession else { return }

        debugLog("[Codex] Selecting session: \(session.displayName)")
        selectedSession = session

        // Copy session state to main state
        if let sessionState = sessionStates[session.id] {
            state = sessionState
        } else {
            state = CodexState()
            state.cwd = session.cwd
            state.sessionId = session.id
            state.gitBranch = session.gitBranch ?? ""
        }
    }

    /// Manually refresh state
    func refresh() {
        scanForSessions()
    }

    // MARK: - Session Scanning

    private func startSessionScanning() {
        scanForSessions()
        sessionScanTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.scanForSessions()
            }
        }
    }

    private func parseSessionFromFile(_ file: URL) -> CodexSession? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }

        guard let firstLine = readFirstJSONLLine(from: handle),
              let lineData = firstLine.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
              let type = json["type"] as? String,
              type == "session_meta",
              let payload = json["payload"] as? [String: Any],
              let sessionId = payload["id"] as? String,
              let cwd = payload["cwd"] as? String else {
            return nil
        }

        let cliVersion = payload["cli_version"] as? String ?? "unknown"
        let modelProvider = payload["model_provider"] as? String ?? "openai"

        var gitBranch: String?
        var gitCommit: String?
        if let git = payload["git"] as? [String: Any] {
            gitBranch = git["branch"] as? String
            gitCommit = git["commit_hash"] as? String
        }

        var timestamp = Date()
        if let timestampStr = json["timestamp"] as? String {
            timestamp = Self.iso8601Formatter.date(from: timestampStr) ?? Date()
        } else if let payloadTimestamp = payload["timestamp"] as? String {
            timestamp = Self.iso8601Formatter.date(from: payloadTimestamp) ?? Date()
        }

        return CodexSession(
            id: sessionId,
            cwd: cwd,
            cliVersion: cliVersion,
            modelProvider: modelProvider,
            gitBranch: gitBranch,
            gitCommit: gitCommit,
            timestamp: timestamp,
            jsonlFile: file
        )
    }

    private func readFirstJSONLLine(from handle: FileHandle) -> String? {
        var data = Data()
        let chunkSize = 64 * 1024
        let maxBytes = 5 * 1024 * 1024
        let newline = UInt8(ascii: "\n")

        while data.count < maxBytes {
            let chunk = handle.readData(ofLength: chunkSize)
            if chunk.isEmpty { break }

            data.append(chunk)
            if let newlineIndex = data.firstIndex(of: newline) {
                data = data.prefix(upTo: newlineIndex)
                break
            }
        }

        return String(data: data, encoding: .utf8)
    }

    // MARK: - Session Watching

    private func startWatchingSession(_ session: CodexSession) {
        debugLog("[Codex] startWatchingSession: \(session.displayName)")
        guard sessionWatchers[session.id] == nil else {
            debugLog("[Codex]   - Already watching")
            return
        }

        let jsonlFile = session.jsonlFile

        var sessionState = CodexState()
        sessionState.cwd = session.cwd
        sessionState.sessionId = session.id
        sessionState.gitBranch = session.gitBranch ?? ""
        sessionState.isConnected = true
        sessionStates[session.id] = sessionState

        do {
            let handle = try FileHandle(forReadingFrom: jsonlFile)
            handle.seekToEndOfFile()
            sessionFileHandles[session.id] = handle
            sessionReadPositions[session.id] = handle.offsetInFile
            loadRecentHistoryForSession(from: jsonlFile, sessionId: session.id)
        } catch {
            debugLog("[Codex] Error opening file: \(error)")
            return
        }

        let fd = open(jsonlFile.path, O_EVTONLY)
        guard fd >= 0 else {
            debugLog("[Codex] Failed to open file descriptor")
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend],
            queue: .main
        )

        source.setEventHandler { [weak self] in
            self?.readNewSessionData(sessionId: session.id)
        }

        source.setCancelHandler {
            close(fd)
        }

        source.resume()
        sessionWatchers[session.id] = source
    }

    private func stopWatchingSession(id sessionId: String) {
        sessionWatchers[sessionId]?.cancel()
        sessionWatchers.removeValue(forKey: sessionId)
        sessionFileHandles[sessionId]?.closeFile()
        sessionFileHandles.removeValue(forKey: sessionId)
        sessionReadPositions.removeValue(forKey: sessionId)
        sessionStates.removeValue(forKey: sessionId)
        pendingFunctionCalls.removeValue(forKey: sessionId)
        isLoadingHistoryBySession.removeValue(forKey: sessionId)
        activeTurnSessionIds.remove(sessionId)
        activeTurnLastEventTimes.removeValue(forKey: sessionId)
    }

    private func loadRecentHistoryForSession(from file: URL, sessionId: String) {
        let maxBytesToRead: UInt64 = 50 * 1024

        guard let handle = try? FileHandle(forReadingFrom: file) else { return }
        defer { try? handle.close() }

        let fileSize = handle.seekToEndOfFile()
        let startPosition = fileSize > maxBytesToRead ? fileSize - maxBytesToRead : 0
        handle.seek(toFileOffset: startPosition)

        guard let data = try? handle.readToEnd(),
              let content = String(data: data, encoding: .utf8) else { return }

        let lines = content.components(separatedBy: .newlines)
        let linesToProcess = startPosition > 0 ? Array(lines.dropFirst().suffix(100)) : Array(lines.suffix(100))

        isLoadingHistoryBySession[sessionId] = true
        for line in linesToProcess where !line.isEmpty {
            parseJSONLLine(line, sessionId: sessionId)
        }
        isLoadingHistoryBySession[sessionId] = false

        // Clear stale tool rows after history loading, but preserve running turn activity.
        if var sessionState = sessionStates[sessionId] {
            sessionState.activeTools.removeAll()
            sessionState.isThinking = isActiveTurnFresh(sessionId)
            sessionStates[sessionId] = sessionState

            if selectedSession?.id == sessionId {
                state.isThinking = isActiveTurnFresh(sessionId)
                state.activeTools.removeAll()
            }
        }
        pendingFunctionCalls[sessionId]?.removeAll()
    }

    private func readNewSessionData(sessionId: String) {
        guard let handle = sessionFileHandles[sessionId],
              let lastPosition = sessionReadPositions[sessionId] else { return }

        handle.seek(toFileOffset: lastPosition)
        let newData = handle.readDataToEndOfFile()
        sessionReadPositions[sessionId] = handle.offsetInFile

        guard !newData.isEmpty,
              let content = String(data: newData, encoding: .utf8) else { return }

        objectWillChange.send()

        let lines = content.components(separatedBy: .newlines)
        for line in lines where !line.isEmpty {
            parseJSONLLine(line, sessionId: sessionId)
        }

        if var sessionState = sessionStates[sessionId] {
            sessionState.lastUpdateTime = Date()
            sessionStates[sessionId] = sessionState
        }

        resetIdleTimer()
    }

    private func resetIdleTimer() {
        idleCheckTimer?.invalidate()
        idleCheckTimer = Timer.scheduledTimer(withTimeInterval: idleCheckDelay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.markAllSessionsIdle()
            }
        }
    }

    private func markAllSessionsIdle() {
        objectWillChange.send()
        for sessionId in sessionStates.keys {
            if var sessionState = sessionStates[sessionId] {
                sessionState.isThinking = isActiveTurnFresh(sessionId)
                sessionStates[sessionId] = sessionState
            }
        }
        if let selectedId = selectedSession?.id {
            state.isThinking = isActiveTurnFresh(selectedId)
        } else {
            state.isThinking = false
        }
    }

    // MARK: - JSONL Parsing

    private func parseJSONLLine(_ line: String, sessionId: String) {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        guard var sessionState = sessionStates[sessionId] else { return }

        let type = json["type"] as? String ?? ""
        let eventDate = parseEventDate(json) ?? Date()
        touchActiveTurnIfNeeded(sessionId, at: eventDate)

        switch type {
        case "session_meta":
            // Already parsed during session discovery
            break

        case "turn_context":
            if let payload = json["payload"] as? [String: Any] {
                if let model = payload["model"] as? String {
                    sessionState.model = model
                }
                if let cwd = payload["cwd"] as? String {
                    sessionState.cwd = cwd
                }
            }

        case "event_msg":
            if let payload = json["payload"] as? [String: Any] {
                parseEventMsg(payload, sessionState: &sessionState, sessionId: sessionId, eventDate: eventDate)
            }

        case "response_item":
            if let payload = json["payload"] as? [String: Any] {
                parseResponseItem(payload, sessionState: &sessionState, sessionId: sessionId, eventDate: eventDate)
            }

        default:
            break
        }

        sessionStates[sessionId] = sessionState

        // Sync to main state if selected
        if selectedSession?.id == sessionId {
            state = sessionState
        }

        objectWillChange.send()
    }

    private func parseEventDate(_ json: [String: Any]) -> Date? {
        guard let timestamp = json["timestamp"] as? String else { return nil }
        return Self.iso8601Formatter.date(from: timestamp)
    }

    private func markTurnActive(_ sessionId: String, sessionState: inout CodexState, at date: Date) {
        activeTurnSessionIds.insert(sessionId)
        activeTurnLastEventTimes[sessionId] = date
        sessionState.isThinking = true
    }

    private func markTurnFinished(_ sessionId: String, sessionState: inout CodexState) {
        activeTurnSessionIds.remove(sessionId)
        activeTurnLastEventTimes.removeValue(forKey: sessionId)
        pendingFunctionCalls[sessionId]?.removeAll()
        sessionState.activeTools.removeAll()
        sessionState.isThinking = false
    }

    private func touchActiveTurnIfNeeded(_ sessionId: String, at date: Date) {
        guard activeTurnSessionIds.contains(sessionId) else { return }
        activeTurnLastEventTimes[sessionId] = date
    }

    private func pruneStaleActiveTurns(now: Date = Date()) {
        for sessionId in activeTurnSessionIds {
            _ = isActiveTurnFresh(sessionId, now: now)
        }
    }

    private func isActiveTurnFresh(_ sessionId: String, now: Date = Date()) -> Bool {
        guard activeTurnSessionIds.contains(sessionId) else { return false }

        guard let lastEventTime = activeTurnLastEventTimes[sessionId] else {
            return true
        }

        if now.timeIntervalSince(lastEventTime) <= staleActiveTurnTimeout {
            return true
        }

        activeTurnSessionIds.remove(sessionId)
        activeTurnLastEventTimes.removeValue(forKey: sessionId)
        pendingFunctionCalls[sessionId]?.removeAll()
        return false
    }

    private func parseEventMsg(
        _ payload: [String: Any],
        sessionState: inout CodexState,
        sessionId: String,
        eventDate: Date
    ) {
        guard let eventType = payload["type"] as? String else { return }

        switch eventType {
        case "task_started", "user_message":
            markTurnActive(sessionId, sessionState: &sessionState, at: eventDate)

        case "task_complete":
            markTurnFinished(sessionId, sessionState: &sessionState)
            publishTaskCompletionIfLive(payload: payload, sessionId: sessionId)

        case "agent_message":
            if payload["phase"] as? String == "final_answer" {
                markTurnFinished(sessionId, sessionState: &sessionState)
            }

        case "token_count":
            let info = payload["info"] as? [String: Any]

            if let totalUsage = info?["total_token_usage"] as? [String: Any] {
                sessionState.tokenUsage.inputTokens = totalUsage["input_tokens"] as? Int ?? 0
                sessionState.tokenUsage.cachedInputTokens = totalUsage["cached_input_tokens"] as? Int ?? 0
                sessionState.tokenUsage.outputTokens = totalUsage["output_tokens"] as? Int ?? 0
                sessionState.tokenUsage.reasoningOutputTokens = totalUsage["reasoning_output_tokens"] as? Int ?? 0
                sessionState.tokenUsage.totalTokens = totalUsage["total_tokens"] as? Int ?? 0

                if let contextWindow = info?["model_context_window"] as? Int {
                    sessionState.tokenUsage.modelContextWindow = contextWindow
                }

                debugLog("[Codex] Token update: in=\(sessionState.tokenUsage.inputTokens) out=\(sessionState.tokenUsage.outputTokens) total=\(sessionState.tokenUsage.totalTokens)")
            }

            // Parse rate limits
            if let rateLimitsPayload = payload["rate_limits"] as? [String: Any]
                ?? info?["rate_limits"] as? [String: Any] {
                let primary = parseRateLimitWindow(rateLimitsPayload["primary"])
                let secondary = parseRateLimitWindow(rateLimitsPayload["secondary"])
                let limitId = rateLimitsPayload["limit_id"] as? String
                let rateLimits = CodexRateLimits.normalized(
                    primary: primary,
                    secondary: secondary,
                    limitId: limitId
                )

                if rateLimits.hasData && shouldApplyRateLimits(rateLimits, to: sessionState.rateLimits) {
                    sessionState.rateLimits = rateLimits
                    sessionState.rateLimitUsedPercent = rateLimits.primary?.clampedUsedPercent
                        ?? rateLimits.secondary?.clampedUsedPercent
                        ?? 0
                }
            }

        case "agent_reasoning":
            markTurnActive(sessionId, sessionState: &sessionState, at: eventDate)
            if let text = payload["text"] as? String {
                sessionState.lastReasoningText = text
                debugLog("[Codex] Reasoning: \(text.prefix(50))...")
            }

        default:
            break
        }
    }

    private func shouldApplyRateLimits(_ incoming: CodexRateLimits, to current: CodexRateLimits) -> Bool {
        if !current.hasData {
            return true
        }

        if incoming.limitId == "codex" {
            return true
        }

        return current.limitId != "codex"
    }

    private func parseRateLimitWindow(_ value: Any?) -> CodexRateLimitWindow? {
        guard let window = value as? [String: Any],
              let usedPercent = doubleValue(window["used_percent"]) else {
            return nil
        }

        var windowMinutes = intValue(window["window_minutes"])
        if windowMinutes == nil,
           let limitWindowSeconds = intValue(window["limit_window_seconds"]) {
            windowMinutes = limitWindowSeconds / 60
        }

        let resetTimestamp = doubleValue(window["resets_at"]) ?? doubleValue(window["reset_at"])
        let resetsAt = resetTimestamp.map { Date(timeIntervalSince1970: $0) }

        return CodexRateLimitWindow(
            usedPercent: usedPercent,
            windowMinutes: windowMinutes,
            resetsAt: resetsAt
        )
    }

    private func doubleValue(_ value: Any?) -> Double? {
        switch value {
        case let value as Double:
            return value
        case let value as Int:
            return Double(value)
        case let value as NSNumber:
            return value.doubleValue
        case let value as String:
            return Double(value)
        default:
            return nil
        }
    }

    private func intValue(_ value: Any?) -> Int? {
        switch value {
        case let value as Int:
            return value
        case let value as Double:
            return Int(value)
        case let value as NSNumber:
            return value.intValue
        case let value as String:
            return Int(value)
        default:
            return nil
        }
    }

    private func publishTaskCompletionIfLive(payload: [String: Any], sessionId: String) {
        guard isLoadingHistoryBySession[sessionId] != true else { return }

        let turnId = payload["turn_id"] as? String ?? UUID().uuidString
        let completedAtSeconds = payload["completed_at"] as? TimeInterval
        let completedAt = completedAtSeconds.map { Date(timeIntervalSince1970: $0) } ?? Date()
        let durationMs = payload["duration_ms"] as? Int
        let lastAgentMessage = payload["last_agent_message"] as? String

        lastTaskCompletion = CodexTaskCompletion(
            id: turnId,
            sessionId: sessionId,
            completedAt: completedAt,
            durationMs: durationMs,
            lastAgentMessage: lastAgentMessage
        )
    }

    private func parseResponseItem(
        _ payload: [String: Any],
        sessionState: inout CodexState,
        sessionId: String,
        eventDate: Date
    ) {
        guard let itemType = payload["type"] as? String else { return }

        switch itemType {
        case "reasoning":
            markTurnActive(sessionId, sessionState: &sessionState, at: eventDate)

        case "function_call":
            touchActiveTurnIfNeeded(sessionId, at: eventDate)
            sessionState.isThinking = false

            guard let callId = payload["call_id"] as? String,
                  let name = payload["name"] as? String else { return }

            let argumentsJson = payload["arguments"] as? String ?? ""
            var argument: String?
            var workdir: String?

            // Parse arguments JSON to extract useful info
            if let argsData = argumentsJson.data(using: .utf8),
               let args = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any] {
                if let command = args["command"] as? String {
                    argument = String(command.prefix(80))
                } else if let content = args["content"] as? String {
                    argument = String(content.prefix(80))
                } else if let path = args["path"] as? String {
                    argument = URL(fileURLWithPath: path).lastPathComponent
                }
                workdir = args["workdir"] as? String
            }

            var tool = CodexToolExecution(
                id: callId,
                toolName: name,
                argument: argument,
                startTime: Date()
            )
            tool.workdir = workdir

            if !sessionState.activeTools.contains(where: { $0.id == callId }) {
                debugLog("[Codex] Tool started: \(name) (id: \(callId.prefix(8))...) arg: \(argument ?? "-")")
                sessionState.activeTools.append(tool)
                pendingFunctionCalls[sessionId, default: [:]][callId] = Date()
            }

        case "function_call_output":
            touchActiveTurnIfNeeded(sessionId, at: eventDate)
            guard let callId = payload["call_id"] as? String else { return }

            pendingFunctionCalls[sessionId]?.removeValue(forKey: callId)

            if let index = sessionState.activeTools.firstIndex(where: { $0.id == callId }) {
                var tool = sessionState.activeTools.remove(at: index)
                tool.endTime = Date()

                // Parse output for exit code
                if let output = payload["output"] as? String {
                    tool.output = String(output.prefix(200))
                    if output.hasPrefix("Exit code: ") {
                        let codeStr = output.dropFirst("Exit code: ".count).prefix(while: { $0.isNumber })
                        tool.exitCode = Int(codeStr)
                    }
                }

                debugLog("[Codex] Tool completed: \(tool.toolName) (id: \(callId.prefix(8))...) duration: \(tool.formattedDuration)")

                sessionState.recentTools.insert(tool, at: 0)
                if sessionState.recentTools.count > 10 {
                    sessionState.recentTools.removeLast()
                }
            }

            // After tool completes, model is likely thinking again
            sessionState.isThinking = isActiveTurnFresh(sessionId)

        case "message":
            if let role = payload["role"] as? String {
                if role == "user" {
                    // User message = start of turn
                    markTurnActive(sessionId, sessionState: &sessionState, at: eventDate)
                } else if role == "assistant" {
                    if payload["phase"] as? String == "final_answer" {
                        markTurnFinished(sessionId, sessionState: &sessionState)
                        return
                    }

                    // Assistant message with content
                    if let content = payload["content"] as? [[String: Any]] {
                        for item in content {
                            if let type = item["type"] as? String {
                                if type == "output_text" || type == "text" {
                                    // Keep long-running Codex Desktop turns active until task_complete arrives.
                                    sessionState.isThinking = isActiveTurnFresh(sessionId)
                                }
                            }
                        }
                    }
                }
            }

        default:
            break
        }
    }

    // MARK: - Cleanup

    func stopWatching() {
        sessionScanTimer?.invalidate()
        sessionScanTimer = nil
        idleCheckTimer?.invalidate()
        idleCheckTimer = nil

        for sessionId in sessionWatchers.keys {
            stopWatchingSession(id: sessionId)
        }
    }
}
