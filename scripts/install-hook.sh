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

# Read patterns into a JSON array (skip comments and blanks).
PATTERNS_JSON=$(grep -v '^[[:space:]]*#' "$PATTERNS" | grep -v '^[[:space:]]*$' | jq -R . | jq -s .)

# 1) Remove any prior Nudge entries (those whose hooks reference HOOK_CMD).
# 2) Append one entry per current pattern.
jq \
  --arg cmd "$HOOK_CMD" \
  --argjson patterns "$PATTERNS_JSON" \
  '
    .hooks //= {} |
    .hooks.PreToolUse //= [] |
    .hooks.PreToolUse |= map(select((.hooks // []) | all(.command != $cmd))) |
    .hooks.PreToolUse += ($patterns | map({
      "if": .,
      "hooks": [{ "type": "command", "command": $cmd }]
    })) |
    if (.hooks.PreToolUse | length) == 0 then del(.hooks.PreToolUse) else . end
  ' "$SETTINGS" > "$SETTINGS.tmp"

# Validate before replacing.
jq -e . "$SETTINGS.tmp" > /dev/null
mv "$SETTINGS.tmp" "$SETTINGS"

PATTERN_COUNT=$(echo "$PATTERNS_JSON" | jq 'length')
echo "✓ Installed $PATTERN_COUNT Nudge hook(s) into $SETTINGS"
echo "  Backup: $BACKUP"
