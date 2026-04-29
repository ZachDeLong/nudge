#!/usr/bin/env bash
# Fires a test prompt directly at Nudge's HTTP server, bypassing the
# Claude Code hook + patterns. Use during UI iteration to see the popover
# without rigging up a real Bash command.
#
# Usage:
#   scripts/test-popup.sh                              # default git push --force prompt
#   scripts/test-popup.sh "rm -rf /tmp/foo"            # custom command
#   scripts/test-popup.sh "rm -rf /tmp/foo" Bash       # custom command + tool
#   scripts/test-popup.sh "" Edit                      # empty-command (Edit/Write style)
#   scripts/test-popup.sh "git push" Bash auto         # mimic auto-mode prompt (no Always button)

set -euo pipefail

PORT_FILE="$HOME/.config/nudge/port"
COMMAND="${1:-git push --force origin main}"
TOOL="${2:-Bash}"
MODE="${3:-default}"

# Auto-launch Nudge if it's not running, then wait for the port file.
if ! pgrep -x Nudge > /dev/null; then
    echo "→ Nudge not running, launching…"
    open -ga Nudge
    for _ in $(seq 1 20); do
        [[ -f "$PORT_FILE" ]] && break
        sleep 0.1
    done
fi

if [[ ! -f "$PORT_FILE" ]]; then
    echo "✗ Nudge port file not found at $PORT_FILE — is Nudge installed?" >&2
    exit 1
fi

PORT=$(cat "$PORT_FILE")
ID="test-$(date +%s)-$$"
CWD="${PWD}"
SESSION="test-session"

BODY=$(jq -n \
    --arg id "$ID" \
    --arg tool "$TOOL" \
    --arg command "$COMMAND" \
    --arg cwd "$CWD" \
    --arg sessionId "$SESSION" \
    --arg permissionMode "$MODE" \
    '{id: $id, tool: $tool, command: $command, cwd: $cwd, sessionId: $sessionId, permissionMode: $permissionMode}')

echo "→ POST 127.0.0.1:$PORT/prompt"
echo "  tool=$TOOL  mode=$MODE  command=$(jq -r .command <<<"$BODY")"
echo "  (waiting for click — Nudge popover should be open)"

RESPONSE=$(curl -sS -X POST -H "Content-Type: application/json" \
    --data "$BODY" \
    "http://127.0.0.1:$PORT/prompt")

echo "← $RESPONSE"
