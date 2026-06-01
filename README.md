# CodexNotch

A tiny native macOS notch companion for Codex and Claude Code sessions.

CodexNotch sits at the top of your display and gives you a compact, glanceable
view of what your coding agent is doing: thinking, running tools, waiting for
permission, using quota, or finishing a task.

![CodexNotch screenshot](docs/screenshot.png)

## Highlights

- Tracks OpenAI Codex sessions by reading local `~/.codex/sessions` JSONL files.
- Tracks Claude Code sessions by reading local `~/.claude/projects` JSONL files.
- Shows active tools, recent tools, thinking state, duration, token totals, and cache usage.
- Displays Codex remaining usage for the 5 hour and 1 week windows.
- Sends a one-time completion notification with optional sound when a task finishes.
- Suppresses stale completion replays when reopening old sessions.
- Clears stuck "thinking" state when a final answer arrives or activity goes stale.
- Supports permission indicators for Claude Code approval prompts.
- Lets you pick a preferred display by name, with built-in display fallback.
- Runs locally on your Mac. No cloud service, no hosted backend.

## Screenshot

The compact state stays small for day-to-day use while still showing active
tool state and Codex remaining usage. Hover or click to open the detail view
with recent tools, context, and session footer.

![CodexNotch compact usage](docs/usage.png)

## Codex Usage

CodexNotch shows the remaining Codex quota instead of the amount already used.
For example, if Codex reports that 3% has been used, CodexNotch displays `97%`
remaining. The compact chips cover both the rolling 5 hour window and the 1 week
window.

![Codex remaining usage chips](docs/usage.png)

## Requirements

- macOS 14 or newer
- Xcode 16 or newer for building from source
- A MacBook notch display, or `Force notch mode` enabled for external displays
- Optional: Codex Desktop or Codex CLI for Codex JSONL tracking
- Optional: Claude Code for Claude JSONL tracking

## Build From Source

```bash
git clone https://github.com/kuwe77/CodexNotch.git
cd CodexNotch
xcodebuild \
  -project CodexNotch.xcodeproj \
  -scheme CodexNotch \
  -configuration Release \
  CODE_SIGNING_ALLOWED=NO \
  build
```

The built app will be under Xcode's build products directory. You can also open
`CodexNotch.xcodeproj` in Xcode and run the `CodexNotch` scheme.

## Codex Setup

CodexNotch can read Codex session JSONL files directly. For OTLP log ingestion,
configure Codex with:

```toml
[analytics]
enabled = true

[otel]
trace_exporter = "none"

[otel.exporter.otlp-http]
endpoint = "http://localhost:4318/v1/logs"
protocol = "binary"
```

The app listens on port `4318` by default.

## Settings

Open the settings window from the notch controls or the menu bar item.

Useful options:

- Enable or disable Codex JSONL tracking.
- Enable or disable Claude Code JSONL tracking.
- Show or hide Codex 5 hour and 1 week remaining usage.
- Enable completion sounds.
- Choose list mode or single detailed event mode.
- Set a preferred display name, such as the exact monitor name shown by macOS.
- Tune the context token limit.

## Privacy

CodexNotch is local-first. It reads local agent session logs and listens for
local OTLP telemetry on your machine. It does not send telemetry, prompts, tool
calls, usage data, or file paths to a hosted service.

Before publishing this repository, local build outputs, Xcode user state,
environment files, provisioning profiles, token files, and common secret file
patterns are ignored by `.gitignore`.

## Attribution

This project is based on the open-source notch telemetry app by AppGram and has been
adapted for a Codex-focused desktop workflow with additional JSONL tracking,
usage display, completion handling, display selection, and compact UI changes.

## License

MIT. See [LICENSE](LICENSE).
