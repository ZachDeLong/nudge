#!/usr/bin/env bash
# Installs/syncs Nudge's Claude Code hooks into ~/.claude/settings.json.
# Permission prompts are driven by nudge-hook + patterns.txt; lifecycle/tool
# observability is driven by nudge-agent-hook.
#
# Idempotent: removes any existing Nudge entries first, then re-adds.

set -euo pipefail

SETTINGS="$HOME/.claude/settings.json"
PATTERNS="$HOME/.config/nudge/patterns.txt"
HOOK_CMD="/Applications/Nudge.app/Contents/MacOS/nudge-hook"
AGENT_HOOK_CMD="/Applications/Nudge.app/Contents/MacOS/nudge-agent-hook"

if ! command -v jq >/dev/null 2>&1; then
    echo "✗ jq is required but not installed." >&2
    echo "  Install with: brew install jq" >&2
    exit 1
fi

if [[ ! -f "$PATTERNS" ]]; then
    echo "✗ Patterns file not found: $PATTERNS" >&2
    exit 1
fi

mkdir -p "$(dirname "$SETTINGS")"
if [[ ! -f "$SETTINGS" ]]; then
    echo "{}" > "$SETTINGS"
fi

# Validate current JSON.
jq -e . "$SETTINGS" > /dev/null

BACKUP="$SETTINGS.bak.$(date +%s)"
cp "$SETTINGS" "$BACKUP"

# Count active patterns for the success message (skip comments and blanks).
PATTERN_COUNT=$(grep -v '^[[:space:]]*#' "$PATTERNS" | grep -v '^[[:space:]]*$' | wc -l | tr -d ' ')

# Install one PreToolUse entry with a tool-name regex matcher for permission
# prompts. Claude Code's `matcher` field filters by tool name only, so we
# narrow to the families we know how to handle and let the hook binary do the
# value-level filtering.
#
# Also install a non-blocking lifecycle hook side-channel. It observes the
# same PreToolUse stream plus PostToolUse/failure/UserPromptSubmit/
# Notification/Stop events so the menu bar can show what the agent is doing
# without screen scraping timing guesses.
MATCHER='Bash|Edit|Write|Read|MultiEdit|NotebookEdit|mcp__.*'

jq \
  --arg cmd "$HOOK_CMD" \
  --arg agentCmd "$AGENT_HOOK_CMD" \
  --arg matcher "$MATCHER" \
  '
    def strip_nudge:
      map(select((.hooks // []) | all(.command != $cmd and .command != $agentCmd)));

    .hooks //= {} |
    .hooks.PreToolUse //= [] |
    .hooks.PreToolUse |= strip_nudge |
    .hooks.PreToolUse += [
      {
        "matcher": $matcher,
        "hooks": [{ "type": "command", "command": $cmd }]
      },
      {
        "matcher": "*",
        "hooks": [{ "type": "command", "command": $agentCmd }]
      }
    ] |
    .hooks.PostToolUse //= [] |
    .hooks.PostToolUse |= strip_nudge |
    .hooks.PostToolUse += [{
      "matcher": "*",
      "hooks": [{ "type": "command", "command": $agentCmd }]
    }] |
    .hooks.PostToolUseFailure //= [] |
    .hooks.PostToolUseFailure |= strip_nudge |
    .hooks.PostToolUseFailure += [{
      "matcher": "*",
      "hooks": [{ "type": "command", "command": $agentCmd }]
    }] |
    reduce ["UserPromptSubmit", "Notification", "Stop", "StopFailure", "SessionEnd"][] as $event (.;
      .hooks[$event] //= [] |
      .hooks[$event] |= strip_nudge |
      .hooks[$event] += [{
        "hooks": [{ "type": "command", "command": $agentCmd }]
      }]
    )
  ' "$SETTINGS" > "$SETTINGS.tmp"

# Validate before replacing.
jq -e . "$SETTINGS.tmp" > /dev/null
mv "$SETTINGS.tmp" "$SETTINGS"

echo "✓ Installed Nudge hooks (permission matcher: $MATCHER) into $SETTINGS"
echo "  Active patterns: $PATTERN_COUNT (read from $PATTERNS at hook time)"
echo "  Backup: $BACKUP"
