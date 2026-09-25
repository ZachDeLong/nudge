#!/usr/bin/env bash
# Wires Nudge into Codex (CLI or the ChatGPT app) through ~/.codex/hooks.json.
# One PermissionRequest entry: it fires only when Codex is about to show its
# own approval prompt, and Nudge answers in its place.
#
# Idempotent: removes any existing Nudge entry first, then re-adds it, so the
# definition (and Codex's trust hash for it) stays the same across re-runs.
#
# Usage: install-codex-hook.sh             (install)
#        install-codex-hook.sh --uninstall (remove the Nudge entry)

set -euo pipefail

CODEX_DIR="${CODEX_HOME:-$HOME/.codex}"
HOOKS="$CODEX_DIR/hooks.json"
HOOK_BIN="/Applications/Nudge.app/Contents/MacOS/nudge-hook"
HOOK_CMD="$HOOK_BIN --agent codex"
CODEX_CLI="/Applications/ChatGPT.app/Contents/Resources/codex"

if [[ ! -d "$CODEX_DIR" ]]; then
    echo "  (Codex not found at $CODEX_DIR, skipping)"
    exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "✗ jq is required but not installed." >&2
    echo "  Install with: brew install jq" >&2
    exit 1
fi

UNINSTALL=0
[[ "${1:-}" == "--uninstall" ]] && UNINSTALL=1

if [[ ! -f "$HOOKS" ]]; then
    [[ $UNINSTALL -eq 1 ]] && exit 0
    echo '{}' > "$HOOKS"
fi
jq -e . "$HOOKS" > /dev/null

BACKUP="$HOOKS.bak.$(date +%s)"
cp -p "$HOOKS" "$BACKUP"
ls -1t "$HOOKS".bak.* 2>/dev/null | tail -n +6 | while IFS= read -r OLD; do
    rm -f "$OLD"
done

# Matches any Nudge entry, with or without arguments, so older definitions
# are replaced rather than duplicated.
jq --arg bin "$HOOK_BIN" --arg cmd "$HOOK_CMD" --argjson uninstall "$UNINSTALL" '
    def strip_nudge:
      map(select((.hooks // []) | all((.command // "") | startswith($bin) | not)));

    .hooks //= {} |
    .hooks.PermissionRequest //= [] |
    .hooks.PermissionRequest |= strip_nudge |
    if $uninstall == 1 then
      (if (.hooks.PermissionRequest | length) == 0 then del(.hooks.PermissionRequest) else . end) |
      (if (.hooks | length) == 0 then del(.hooks) else . end)
    else
      .hooks.PermissionRequest += [{
        "hooks": [{ "type": "command", "command": $cmd }]
      }]
    end
' "$HOOKS" > "$HOOKS.tmp"

jq -e . "$HOOKS.tmp" > /dev/null
mv "$HOOKS.tmp" "$HOOKS"

if [[ $UNINSTALL -eq 1 ]]; then
    echo "✓ Removed Nudge from $HOOKS"
    exit 0
fi

echo "✓ Installed Nudge's Codex hook into $HOOKS"
echo "  Codex skips new hooks until you trust them, and the ChatGPT app can't"
echo "  do that yet. Once, in a terminal:"
if [[ -x "$CODEX_CLI" ]]; then
    echo "    $CODEX_CLI"
else
    echo "    codex"
fi
echo "  then type /hooks and trust the Nudge entry. (That screen trusts every"
echo "  pending hook at once, so check the list first.)"
