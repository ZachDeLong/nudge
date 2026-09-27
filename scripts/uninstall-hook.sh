#!/usr/bin/env bash
# Removes all Nudge hook entries from ~/.claude/settings.json.
set -euo pipefail

SETTINGS="$HOME/.claude/settings.json"
HOOK_CMD="/Applications/Nudge.app/Contents/MacOS/nudge-hook"
AGENT_HOOK_CMD="/Applications/Nudge.app/Contents/MacOS/nudge-agent-hook"

if ! command -v jq >/dev/null 2>&1; then
    echo "✗ jq is required but not installed." >&2
    echo "  Install with: brew install jq" >&2
    exit 1
fi

if [[ ! -f "$SETTINGS" ]]; then
    echo "no settings file, nothing to remove"
    exit 0
fi

# Write through a symlinked settings.json and keep the file's permissions.
TARGET="$(realpath "$SETTINGS")"

BACKUP="$SETTINGS.bak.$(date +%s)"
cp -p "$TARGET" "$BACKUP"

jq --arg cmd "$HOOK_CMD" --arg agentCmd "$AGENT_HOOK_CMD" '
  # Only the Nudge handlers go. Anything else sharing a group with them
  # stays; a group left empty goes too.
  def strip_nudge:
    map(.hooks = ((.hooks // []) | map(select(.command != $cmd and .command != $agentCmd))))
    | map(select(.hooks | length > 0));

  if .hooks then
    reduce ["PreToolUse", "PermissionRequest", "PostToolUse", "PostToolUseFailure", "UserPromptSubmit", "Notification", "Stop", "StopFailure", "SessionEnd"][] as $event (.;
      if .hooks[$event] then
        .hooks[$event] |= strip_nudge |
        if (.hooks[$event] | length) == 0 then del(.hooks[$event]) else . end
      else . end
    ) |
    if (.hooks | length) == 0 then del(.hooks) else . end
  else . end
' "$TARGET" > "$TARGET.tmp"

jq -e . "$TARGET.tmp" > /dev/null
chmod "$(stat -f %Lp "$TARGET")" "$TARGET.tmp"
mv "$TARGET.tmp" "$TARGET"
echo "✓ Removed Nudge hooks from $SETTINGS"
echo "  Backup: $BACKUP"
