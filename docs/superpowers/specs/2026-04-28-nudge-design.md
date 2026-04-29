# Nudge — Design Spec

**Date:** 2026-04-28
**Status:** Approved (brainstorm) · Pivoted after Phase 1 hook-ordering investigation (see Risk 1 below) · Pending updated implementation plan

## Phase 1 verification result (2026-04-28)

Two probes were run before any code was written:

1. **PreToolUse + `Bash(*)` filter, observation only.** Result: hook fired for every Bash call including auto-mode-allowed commands (`ls`, `git status`, `git show`). PreToolUse runs **before** auto mode classifies, so the original "intercept only what auto mode would prompt about" design isn't viable through this event.
2. **PermissionRequest event, observation + attempted `permissionDecision: "allow"` override.** Result: hook fires only when a real permission prompt would appear (good — silent on auto-allow, silent on auto-deny, fires when the terminal would prompt). However, the `permissionDecision` field is ignored on this event — the terminal prompt still showed. PermissionRequest is observe-only for hooks today.

**Pivot:** Move from "broad `PreToolUse + Bash(*)`" to "narrow `PreToolUse` with a configurable list of opt-in patterns" (e.g., `Bash(git push:*)`, `Bash(rm:*)`, `Bash(*deploy*)`). Auto mode continues handling everything else exactly as it does today. Nudge owns the decision UX only for the patterns the user explicitly opts in to.

Trade-off accepted: any prompt-worthy command **not** on Nudge's opt-in list still hits the regular terminal prompt. v1 ships with a sensible default list; users can edit it in `~/.config/nudge/patterns.txt`.

## Summary

Nudge is a macOS menu bar app that surfaces Claude Code permission prompts as a clickable popover, so the user can approve from anywhere on the desktop without alt-tabbing back to the terminal.

The app complements Claude Code's auto mode (which silently approves safe commands). When auto mode would otherwise stop and ask the user, Nudge intercepts the prompt via a `PreToolUse` hook, displays it in a native macOS popover anchored to a menu bar icon, and returns the user's decision back to Claude Code.

## Goals

- Eliminate the alt-tab-to-terminal step for the ~10% of Claude Code tool calls that auto mode flags as "ask."
- Native macOS aesthetic — vibrancy, SF Pro, system colors, fits in like a built-in.
- Fail safely — every error path falls back to Claude Code's normal terminal prompt. Nudge being broken never blocks the user.

## Non-goals (v1)

- Replacing auto mode (Nudge handles only the residual prompts auto mode would otherwise show).
- Preferences UI, prompt history, custom hotkeys, sound customization, theme selector — all deferred.
- Code signing / notarization for distribution. v1 assumes personal use; the user runs `xattr -d com.apple.quarantine` once.
- Cross-platform support. Mac only.

## Architecture

Two pieces:

1. **Nudge.app** — SwiftUI menu bar app (`NSApplicationActivationPolicy.accessory`, no Dock icon). Owns the menu bar icon, runs an HTTP server on localhost, displays the popover, manages the prompt queue.
2. **`nudge-hook`** — small Swift CLI binary, shipped inside `Nudge.app/Contents/MacOS/`. Wired into Claude Code's `PreToolUse` hook. Reads JSON from stdin, POSTs to Nudge, blocks until the user clicks, prints the decision JSON to stdout.

Splitting them lets the app stay running across many Claude Code sessions while keeping the hook tiny and crash-safe.

## Components

### Nudge.app

- **`NudgeApp.swift`** — `@main` entry point. Sets accessory activation policy, instantiates the controller, starts the server.
- **`MenuBarController.swift`** — owns the `NSStatusItem`. Swaps icon between idle (`circle.fill`, default tint) and pending (`circle.fill`, red, soft pulse). Anchors the popover.
- **`PopoverView.swift`** — SwiftUI view shown in the popover. Renders the prompt (tool name, command, cwd) and Allow/Deny buttons. Listens for Enter/Escape via NSEvent monitor while visible.
- **`PromptServer.swift`** — HTTP/1.1 listener on `127.0.0.1`, built on `Network.framework` (`NWListener` for the TCP socket) with a minimal in-house HTTP/1.1 parser. We deliberately avoid pulling in `swift-nio` for v1 — the protocol surface is tiny (one `POST /prompt` endpoint, JSON body, JSON response) and a self-contained parser keeps the dependency graph clean. Accepts `POST /prompt`, hands the request to `PromptQueue`, suspends the response via Swift `async/await`, returns the decision JSON when the queue resolves.
- **`PromptQueue.swift`** — Swift actor. FIFO queue of pending prompts; the popover renders the head of the queue. When 2+ prompts are pending, the popover header shows an "X more queued" pill.
- **`Settings.swift`** — minimal. Holds the current port and the discovery-file path. Persists port to `UserDefaults`. No UI in v1.
- **`Patterns.swift`** — reads `~/.config/nudge/patterns.txt` and rewrites the corresponding `PreToolUse` entries in `~/.claude/settings.json`. Invoked from the installer and exposed via `nudge-hook --sync`. Default patterns shipped: `Bash(git push:*)`, `Bash(rm:*)`, `Bash(*--force*)`, `Bash(*deploy*)`.

### `nudge-hook`

A small Swift CLI binary built alongside the app target.

- Reads JSON from stdin (Claude Code hook input format: `{tool_name, tool_input, cwd, session_id, ...}`).
- Reads the port from `~/.config/nudge/port`.
- If the port file is missing or the server doesn't respond within 200ms: runs `open -ga /Applications/Nudge.app`, polls the port for up to 2 seconds.
- POSTs the prompt JSON to `http://127.0.0.1:<port>/prompt`. Waits for the response (no client-side timeout — server enforces 5-minute timeout).
- Writes Claude Code's hook output JSON to stdout: `{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "allow"|"deny"}}`.
- On any error (no Nudge installed, server unreachable after retries, malformed response): exits 0 with no output, letting Claude Code fall back to its normal prompt.

### Claude Code hook entry

Added to `~/.claude/settings.json` by the installer. One `PreToolUse` block per opt-in pattern, each scoped to a specific risky command via the `if` field:

```json
{
  "hooks": {
    "PreToolUse": [
      { "if": "Bash(git push:*)",   "hooks": [{ "type": "command", "command": "/Applications/Nudge.app/Contents/MacOS/nudge-hook" }] },
      { "if": "Bash(rm:*)",         "hooks": [{ "type": "command", "command": "/Applications/Nudge.app/Contents/MacOS/nudge-hook" }] },
      { "if": "Bash(*--force*)",    "hooks": [{ "type": "command", "command": "/Applications/Nudge.app/Contents/MacOS/nudge-hook" }] },
      { "if": "Bash(*deploy*)",     "hooks": [{ "type": "command", "command": "/Applications/Nudge.app/Contents/MacOS/nudge-hook" }] }
    ]
  }
}
```

The full pattern list is read from `~/.config/nudge/patterns.txt` (one pattern per line, `#` for comments). The installer rewrites the hook entries from this file. v1 ships with the four patterns above; users can edit the file and re-run `make sync-patterns` (or `nudge-hook --sync`) to regenerate the settings.json entries.

This means Nudge handles a **specific opt-in set** of risky commands rather than every prompt auto mode would have shown. Anything not on the list still hits the regular terminal prompt — graceful degradation. Adding a new pattern is one line in `patterns.txt` plus a `make sync-patterns`.

## Data flow

Happy path (user is in their browser; Claude wants to `git push origin main`):

1. Claude Code is about to run `Bash`. Auto mode classifier flags it as "ask."
2. `PreToolUse` hook fires → `nudge-hook` runs.
3. `nudge-hook` reads stdin and locates Nudge: reads `~/.config/nudge/port`. If missing or unresponsive, runs `open -ga` and polls (≤ 2s).
4. `nudge-hook` POSTs `{id, tool, command, cwd, session_id}` to `/prompt`. The HTTP request stays open.
5. `PromptServer` receives, enqueues into `PromptQueue`, suspends the response.
6. `PromptQueue` notifies `MenuBarController`. Status icon flips to "pending" (red pulse). Popover **auto-opens** under the menu bar icon (no focus steal — popovers don't deactivate the foreground app).
7. `PopoverView` renders the prompt. User clicks **Allow**.
8. `PopoverView` resolves the prompt → `PromptServer` returns `{"decision":"allow"}`.
9. `nudge-hook` writes the Claude Code hook output JSON to stdout, exits 0.
10. Claude Code proceeds. The user never touched the terminal.

### Concurrency

Multiple Claude Code sessions can POST simultaneously. The `PromptQueue` actor serializes access; prompts are shown one at a time in FIFO order. The popover header displays the queue depth.

### Timeout

If the user ignores the popover for **5 minutes**, `PromptServer` returns the request with no decision. `nudge-hook` exits with no output, and Claude Code shows its normal terminal prompt.

## Visual design

Native macOS aesthetic. Reference mockup committed alongside this spec at `2026-04-28-popover-mockup.html` (open in a browser).

- **Menu bar icon** — SF Symbol `circle.fill`, system tint by default. Pending state: tinted red with a 1.5s ease-in-out pulse animation.
- **Popover** — 380px wide, ~200px tall (grows with command length, capped at 320px with internal scroll).
- **Background** — `NSVisualEffectView` material `.popover` with `.behindWindow` blending.
- **Header** — small Claude logo/icon (32px), "Permission request" title, `tool · cwd-basename` subtitle, "just now" timestamp. Optional "X more queued" orange pill on the right when queue depth > 1.
- **Body** — command in a monospaced (SF Mono) box with subtle background, soft corners.
- **Buttons** — Allow (filled `.controlAccentColor`, default), Deny (gray secondary). Right-aligned, equal-width.
- **Keyboard** — Enter approves (default button), Escape denies. Both work whether or not the popover has keyboard focus, via a global `NSEvent` monitor active only while the popover is open.

## Error handling

Every failure mode falls back to Claude Code's normal terminal prompt:

| Failure | Behavior |
|---------|----------|
| Nudge.app not installed | `nudge-hook` exits without writing decision JSON. |
| Nudge.app not running | Hook tries `open -ga`, polls 2s. If still down, falls back. |
| Server crashes mid-prompt | Hook's HTTP request errors out. |
| User idle 5 minutes | Server returns no decision. |
| Two prompts arrive simultaneously | Queued. Popover shows "1 more queued." |
| Malformed prompt JSON | Server returns HTTP 400. Hook falls back. |
| Port file missing or stale | Hook attempts `open -ga`, falls back if unreachable. |

The principle: if Nudge is broken in any way, the user just sees Claude Code's regular prompt. Nudge improves the common case; it never makes things worse.

## Testing

### Unit tests

- `PromptQueue` — FIFO ordering, concurrent enqueue safety, 5-minute timeout fires correctly, decision propagation.
- JSON encode/decode for the request and response shapes.
- Port discovery file format and parsing.

### Integration tests

- Start `PromptServer` on a random port. Hit `POST /prompt` with `curl`. Verify the request blocks until a test fixture resolves it via the queue. Test happy path, timeout, malformed body, queue ordering.
- No real menu bar UI in the test harness — `MenuBarController` is mocked.

### Manual end-to-end

Documented in `README.md`:

1. Install Nudge to `/Applications`.
2. Run installer to add the hook to `~/.claude/settings.json`.
3. In a separate terminal, ask Claude Code to do something that auto mode would prompt for (e.g., `git push origin main`).
4. Confirm: menu bar icon flips to red, popover appears under it, clicking Allow makes Claude proceed.

UI snapshot tests are out of scope for v1 — they're flaky for menu bar apps and we'd be testing AppKit rather than our logic.

## Risks and open questions

### Risk 1: PreToolUse vs auto mode ordering (RESOLVED — design pivoted)

**Outcome:** PreToolUse fires before auto mode classifies (confirmed via probe 1, Phase 1). PermissionRequest fires only when a real prompt would otherwise appear (confirmed via probe 2), but cannot override the decision (confirmed: terminal prompt still appeared after returning `permissionDecision: "allow"`).

**Resolution:** Pivoted to "narrow PreToolUse with opt-in patterns" approach. Nudge handles a configurable list of risky patterns rather than intercepting all auto-mode prompts. See "Phase 1 verification result" section above.

### Risk 2: First-launch macOS approval

Menu bar apps may need accessibility approval for global key shortcuts (Enter/Escape while the popover is open). Document the steps in `README.md`. Consider falling back to focus-required key handling if accessibility is denied.

### Risk 3: Unsigned app + Gatekeeper

Running an unsigned `Nudge.app` from `/Applications` triggers Gatekeeper. v1 documents `xattr -d com.apple.quarantine /Applications/Nudge.app` as the workaround. Code signing is out of scope.

### Risk 4: Port collisions

If port 19283 is taken, the server picks a random free port and writes it to `~/.config/nudge/port`. The hook always reads the file rather than hardcoding the port.

## v2 ideas (out of scope for v1, captured here so we don't lose them)

### Text reply dropdown for Claude's elicitations

When Claude asks the user a question that needs a text response (not a permission prompt — an actual "what should I name this?" or "which option do you want?" question), surface it in the same popover with a text field instead of Allow/Deny buttons.

**Technical wrinkle:** text questions don't go through the permission system. They surface via the `Notification` hook with messages like "Claude is waiting for your input," but that hook is fire-and-forget — Claude isn't actually blocked waiting for a hook response, it's blocked waiting for the user to type into the terminal.

**Possible mechanisms:**

- **MCP server with an `ask_user` tool** — Claude calls the tool when it wants text input; the tool blocks until Nudge resolves. Requires Claude to actually call the tool rather than typing into the terminal, which is a behavioral change.
- **`Elicitation` hook event** — the hooks schema lists `Elicitation` and `ElicitationResult` events. If they support blocking and decision return, this is the natural fit. Needs investigation.
- **Terminal output scraping** — fragile and gross, but technically possible. Last resort.

Worth a separate brainstorm + spec once Nudge v1 is shipped and stable.

### Other v2 candidates

- **Notification history** — small list of past prompts in the popover, so the user can review what they approved/denied recently.
- **Per-pattern preferences** — "always allow for this command" learned from clicks.
- **Cross-machine sync** — approve from a different machine via Tailscale/iCloud.
- **Touch Bar / Stream Deck integration** — physical hardware to approve.

## Project layout

```
~/Desktop/nudge/
├── Package.swift              # SwiftPM manifest with two targets
├── Makefile                   # build, install, uninstall
├── README.md                  # install steps, troubleshooting
├── Sources/
│   ├── Nudge/                 # the app
│   │   ├── NudgeApp.swift
│   │   ├── MenuBarController.swift
│   │   ├── PopoverView.swift
│   │   ├── PromptServer.swift
│   │   ├── PromptQueue.swift
│   │   └── Settings.swift
│   └── NudgeHook/             # the hook binary
│       └── main.swift
├── Tests/
│   ├── NudgeTests/
│   │   ├── PromptQueueTests.swift
│   │   └── PromptServerTests.swift
└── docs/
    └── superpowers/
        └── specs/
            └── 2026-04-28-nudge-design.md   # this file
```

Same shape as the user's existing `radioform` project (SwiftPM + Makefile, no Xcode required).

## Implementation order (high level)

1. **Verify hook ordering** with a logging probe (Risk 1).
2. **`nudge-hook` binary** — barebones: reads stdin, sleeps for the user (`read -p` style), writes a hardcoded "allow" to stdout. Confirms the Claude Code wiring works end-to-end.
3. **`PromptServer` + `PromptQueue`** — pure logic, no UI. Test with `curl`.
4. **Wire hook → server** — replace the hardcoded "allow" with a real HTTP POST.
5. **Menu bar app shell** — `NSStatusItem`, idle icon, popover that opens on click with hardcoded content.
6. **`PopoverView` + queue integration** — real prompts render in the popover.
7. **Polish** — icon states (idle/pending/pulse), animations, keyboard shortcuts, queue indicator.
8. **Installer / Makefile** — `make install` copies the app to `/Applications` and **merges** the hook entry into `~/.claude/settings.json`. The installer preserves all existing settings, hooks, and permissions; it adds Nudge's `PreToolUse` entry alongside any existing hooks (or appends to the existing array if `PreToolUse` already exists). `make uninstall` reverses both. The installer must `jq -e` the file before and after to verify valid JSON, and must back up to `~/.claude/settings.json.bak.<timestamp>` on every install.

A detailed plan with checkpoints will be created via `superpowers:writing-plans`.
