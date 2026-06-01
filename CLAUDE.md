# CodexNotch Project Notes

CodexNotch is a native macOS SwiftUI app that displays local coding-agent
activity in a compact notch-style panel.

## Main Areas

- `CodexNotch/Core/Codex/CodexManager.swift`
  Reads Codex JSONL sessions from `~/.codex/sessions`, tracks tools, thinking
  state, token usage, task completion, and Codex rate-limit windows.

- `CodexNotch/Core/ClaudeCode/ClaudeCodeManager.swift`
  Reads Claude Code JSONL sessions from `~/.claude/projects`, tracks tools,
  todos, thinking state, permission waits, and completion state.

- `CodexNotch/Core/Telemetry`
  Runs a local OTLP HTTP receiver on port `4318` and decodes OTLP logs/metrics.

- `CodexNotch/Core/Coordinators/UICoordinator.swift`
  Owns the notch panel, display selection, screen-change handling, and menu bar
  fallback setup.

- `CodexNotch/Views/Notch/CodexNotchContentView.swift`
  Main notch UI for compact, peeking, and expanded states.

- `CodexNotch/Core/Settings/AppSettings.swift`
  User defaults backed by `@AppStorage`.

## Display Behavior

If `preferredDisplayName` is set, the notch panel tries to appear on a matching
display name. If that display is unavailable, it falls back to the built-in
display, then `NSScreen.main`, then the first screen.

## Privacy

The app should not include default remote media URLs, credentials, tokens,
or user-specific paths beyond documented local session locations like
`~/.codex` and `~/.claude`.

## Build

```bash
xcodebuild \
  -project CodexNotch.xcodeproj \
  -scheme CodexNotch \
  -configuration Release \
  CODE_SIGNING_ALLOWED=NO \
  build
```
