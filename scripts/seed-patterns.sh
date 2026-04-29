#!/usr/bin/env bash
# Seeds ~/.config/nudge/patterns.txt — by default, only when it doesn't
# exist (so user edits are never clobbered). Pulls in:
#   1. Curated defaults from scripts/default-patterns.txt
#   2. Any Bash(...) rules from ~/.claude/settings.json's permissions.ask
#      array — those are commands the user already told Claude to prompt on.
#
# Modes:
#   (no args)   — seed only if patterns.txt is missing. Used by `make install`.
#   --merge     — append new imports to an existing patterns.txt without
#                 touching what's already there. Used by `make import-permissions`.

set -euo pipefail

PATTERNS_FILE="$HOME/.config/nudge/patterns.txt"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEFAULTS="$SCRIPT_DIR/default-patterns.txt"
SETTINGS="$HOME/.claude/settings.json"

MODE="${1:-seed}"

mkdir -p "$(dirname "$PATTERNS_FILE")"

case "$MODE" in
    seed)
        if [[ -f "$PATTERNS_FILE" ]]; then
            exit 0
        fi
        cp "$DEFAULTS" "$PATTERNS_FILE"
        echo "→ Seeded $PATTERNS_FILE from defaults"
        ;;
    --merge)
        if [[ ! -f "$PATTERNS_FILE" ]]; then
            cp "$DEFAULTS" "$PATTERNS_FILE"
            echo "→ Created $PATTERNS_FILE from defaults"
        fi
        ;;
    *)
        echo "usage: $0 [--merge]" >&2
        exit 2
        ;;
esac

# Import permission rules from permissions.ask for tool families the hook
# binary knows how to match: Bash, Edit, Write, Read, MultiEdit, NotebookEdit.
# Other rules (e.g. mcp__... or unknown tools) are skipped — they wouldn't
# do anything in patterns.txt today.
if [[ ! -f "$SETTINGS" ]] || ! command -v jq >/dev/null 2>&1; then
    exit 0
fi

ASK_BASH=$(jq -r '
    (.permissions.ask // [])
    | map(select(type == "string"
        and (startswith("Bash(")
          or startswith("Edit(")
          or startswith("Write(")
          or startswith("Read(")
          or startswith("MultiEdit(")
          or startswith("NotebookEdit("))))
    | unique
    | .[]
' "$SETTINGS" 2>/dev/null || true)

if [[ -z "$ASK_BASH" ]]; then
    exit 0
fi

# Existing non-comment, non-blank lines for dedup.
EXISTING=$(grep -v '^[[:space:]]*#' "$PATTERNS_FILE" 2>/dev/null | grep -v '^[[:space:]]*$' || true)

NEW_LINES=""
while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    if ! grep -Fxq "$line" <<<"$EXISTING"; then
        NEW_LINES+="$line"$'\n'
    fi
done <<<"$ASK_BASH"

if [[ -z "$NEW_LINES" ]]; then
    exit 0
fi

{
    echo ""
    echo "# Imported from ~/.claude/settings.json (permissions.ask) on $(date +%Y-%m-%d)"
    printf "%s" "$NEW_LINES"
} >> "$PATTERNS_FILE"

COUNT=$(printf "%s" "$NEW_LINES" | grep -cE '^(Bash|Edit|Write|Read|MultiEdit|NotebookEdit)\(' || true)
echo "→ Imported $COUNT pattern(s) from $SETTINGS (permissions.ask)"
