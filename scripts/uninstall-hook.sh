#!/usr/bin/env bash
# Removes all Nudge PreToolUse entries from ~/.claude/settings.json.
set -euo pipefail

SETTINGS="$HOME/.claude/settings.json"
HOOK_CMD="/Applications/Nudge.app/Contents/MacOS/nudge-hook"

if [[ ! -f "$SETTINGS" ]]; then
    echo "no settings file, nothing to remove"
    exit 0
fi

BACKUP="$SETTINGS.bak.$(date +%s)"
cp "$SETTINGS" "$BACKUP"

jq --arg cmd "$HOOK_CMD" '
  if .hooks?.PreToolUse then
    .hooks.PreToolUse |= map(select((.hooks // []) | all(.command != $cmd)))
    | (if (.hooks.PreToolUse | length) == 0 then del(.hooks.PreToolUse) else . end)
  else . end
' "$SETTINGS" > "$SETTINGS.tmp"

jq -e . "$SETTINGS.tmp" > /dev/null
mv "$SETTINGS.tmp" "$SETTINGS"
echo "✓ Removed Nudge hooks from $SETTINGS"
echo "  Backup: $BACKUP"
