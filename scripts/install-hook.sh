#!/usr/bin/env bash
# Installs/syncs Nudge's PreToolUse entries into ~/.claude/settings.json
# based on the patterns in ~/.config/nudge/patterns.txt.
#
# Idempotent: removes any existing Nudge entries first, then re-adds.

set -euo pipefail

SETTINGS="$HOME/.claude/settings.json"
PATTERNS="$HOME/.config/nudge/patterns.txt"
HOOK_CMD="/Applications/Nudge.app/Contents/MacOS/nudge-hook"

if [[ ! -f "$PATTERNS" ]]; then
    echo "✗ Patterns file not found: $PATTERNS" >&2
    exit 1
fi

if [[ ! -f "$SETTINGS" ]]; then
    echo "{}" > "$SETTINGS"
fi

# Validate current JSON.
jq -e . "$SETTINGS" > /dev/null

BACKUP="$SETTINGS.bak.$(date +%s)"
cp "$SETTINGS" "$BACKUP"

# Count active patterns for the success message (skip comments and blanks).
PATTERN_COUNT=$(grep -v '^[[:space:]]*#' "$PATTERNS" | grep -v '^[[:space:]]*$' | wc -l | tr -d ' ')

# Install one PreToolUse entry with matcher "Bash" — Claude Code's `matcher`
# field filters by tool name only, so we narrow to Bash here and let the hook
# binary do the per-command pattern matching against patterns.txt.
#
# 1) Remove any prior Nudge entries (those whose hooks reference HOOK_CMD).
# 2) Append a single entry that fires on Bash calls.
jq \
  --arg cmd "$HOOK_CMD" \
  '
    .hooks //= {} |
    .hooks.PreToolUse //= [] |
    .hooks.PreToolUse |= map(select((.hooks // []) | all(.command != $cmd))) |
    .hooks.PreToolUse += [{
      "matcher": "Bash",
      "hooks": [{ "type": "command", "command": $cmd }]
    }] |
    if (.hooks.PreToolUse | length) == 0 then del(.hooks.PreToolUse) else . end
  ' "$SETTINGS" > "$SETTINGS.tmp"

# Validate before replacing.
jq -e . "$SETTINGS.tmp" > /dev/null
mv "$SETTINGS.tmp" "$SETTINGS"

echo "✓ Installed Nudge hook (matcher: Bash) into $SETTINGS"
echo "  Active patterns: $PATTERN_COUNT (read from $PATTERNS at hook time)"
echo "  Backup: $BACKUP"
