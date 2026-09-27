#!/usr/bin/env bash
# Tests scripts/install-hook.sh and uninstall-hook.sh against throwaway homes.
# Never touches ~/.claude: every case sets HOME to a temp dir.
# Usage: Tests/install/claude-hook-test.sh   (from the repo root)

set -uo pipefail

SCRIPTS="$(cd "$(dirname "$0")/../.." && pwd)/scripts"
BIN="/Applications/Nudge.app/Contents/MacOS"
HOOK="$BIN/nudge-hook"
AGENT_HOOK="$BIN/nudge-agent-hook"
ROOT=$(mktemp -d /tmp/nudge-claude-install-test.XXXXXX)
trap 'rm -rf "$ROOT"' EXIT

passed=0
failed=0
check() { # name, command...
    local name=$1; shift
    if "$@"; then
        passed=$((passed + 1))
    else
        failed=$((failed + 1))
        echo "✗ $name"
    fi
}
home() { # a fresh home with a patterns file, optionally with settings.json
    local dir="$ROOT/$1"
    mkdir -p "$dir/.claude" "$dir/.config/nudge"
    echo 'Bash(git push:*)' > "$dir/.config/nudge/patterns.txt"
    [[ -n "${2:-}" ]] && printf '%s\n' "$2" > "$dir/.claude/settings.json"
    echo "$dir"
}
install() { HOME="$1" "$SCRIPTS/install-hook.sh" >"$1.out" 2>&1; }
uninstall() { HOME="$1" "$SCRIPTS/uninstall-hook.sh" >"$1.out" 2>&1; }
q() { jq -c "$2" "$1/.claude/settings.json"; }
count() { q "$1" "[.. | objects | select(.command? == \"$2\")] | length"; }

GUARD='{"type":"command","command":"/usr/local/bin/my-guardrail"}'

# Fresh settings get every Nudge hook, once.
d=$(home fresh '{}')
install "$d"
check "fresh: exits 0" test $? -eq 0
check "fresh: one PermissionRequest hook" test "$(q "$d" '[.hooks.PermissionRequest[].hooks[] | select(.command == "'"$HOOK"'")] | length')" = 1
check "fresh: agent hook on Stop" test "$(q "$d" '.hooks.Stop[0].hooks[0].command')" = "\"$AGENT_HOOK\""
install "$d"
check "reinstall: still one nudge-hook per event" test "$(count "$d" "$HOOK")" = 2

# A user's own hook sharing a group with Nudge's survives install and uninstall.
d=$(home shared "{\"hooks\":{\"PreToolUse\":[{\"matcher\":\"*\",\"hooks\":[{\"type\":\"command\",\"command\":\"$AGENT_HOOK\"},$GUARD]}]}}")
install "$d"
check "shared group: guardrail kept on install" test "$(count "$d" /usr/local/bin/my-guardrail)" = 1
check "shared group: Nudge's agent hook not duplicated" test "$(q "$d" "[.hooks.PreToolUse[].hooks[] | select(.command == \"$AGENT_HOOK\")] | length")" = 1
uninstall "$d"
check "shared group: guardrail kept on uninstall" test "$(q "$d" '.hooks.PreToolUse')" = "[{\"matcher\":\"*\",\"hooks\":[$GUARD]}]"
check "uninstall: no Nudge hooks left" test "$(count "$d" "$HOOK")$(count "$d" "$AGENT_HOOK")" = 00

# Other settings are untouched; uninstall drops the hooks key it emptied.
d=$(home other '{"model":"opus","permissions":{"allow":["Bash(ls:*)"]}}')
install "$d"
uninstall "$d"
check "other settings: back to the original" test "$(jq -cS . "$d/.claude/settings.json")" = '{"model":"opus","permissions":{"allow":["Bash(ls:*)"]}}'

# A symlinked settings.json (dotfile repos) stays a link, and its target keeps
# its permissions.
d=$(home linked)
mkdir -p "$d/dotfiles"
echo '{}' > "$d/dotfiles/settings.json"
chmod 600 "$d/dotfiles/settings.json"
ln -s "$d/dotfiles/settings.json" "$d/.claude/settings.json"
install "$d"
check "symlink: still a link after install" test -L "$d/.claude/settings.json"
check "symlink: target got the hooks" test "$(jq '.hooks | length' "$d/dotfiles/settings.json")" -gt 0
check "symlink: target mode kept" test "$(stat -f %Lp "$d/dotfiles/settings.json")" = 600
uninstall "$d"
check "symlink: still a link after uninstall" test -L "$d/.claude/settings.json"
check "symlink: hooks removed from target" test "$(jq -c . "$d/dotfiles/settings.json")" = '{}'

# Malformed JSON is left alone.
d=$(home broken '{"hooks": {')
cp "$d/.claude/settings.json" "$ROOT/broken-before"
install "$d"
check "malformed: fails" test $? -ne 0
check "malformed: file untouched" cmp -s "$d/.claude/settings.json" "$ROOT/broken-before"

echo "install-hook: $passed passed, $failed failed"
[[ $failed -eq 0 ]]
