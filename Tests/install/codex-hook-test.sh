#!/usr/bin/env bash
# Tests scripts/install-codex-hook.sh against throwaway Codex homes. Never
# touches ~/.codex: every case sets CODEX_HOME to a temp dir.
# Usage: Tests/install/codex-hook-test.sh   (from the repo root; make test runs it)

set -uo pipefail

INSTALLER="$(cd "$(dirname "$0")/../.." && pwd)/scripts/install-codex-hook.sh"
BIN="/Applications/Nudge.app/Contents/MacOS"
HOOK="$BIN/nudge-hook --agent codex"
AGENT_HOOK="$BIN/nudge-agent-hook --agent codex"
ROOT=$(mktemp -d /tmp/nudge-codex-install-test.XXXXXX)
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
home() { # a fresh Codex home, optionally with a hooks.json
    local dir="$ROOT/$1"
    mkdir -p "$dir"
    [[ -n "${2:-}" ]] && printf '%s\n' "$2" > "$dir/hooks.json"
    echo "$dir"
}
run() { CODEX_HOME="$1" "$INSTALLER" "${@:2}" >"$1.out" 2>&1; }
q() { jq -c "$2" "$1/hooks.json"; }
backups() { ls "$1"/hooks.json.bak.* 2>/dev/null | wc -l | tr -d ' '; }

# The shape of a real ~/.codex/hooks.json: the vault's session hooks and an
# earlier Nudge install.
VAULT_START='{"matcher":"startup|resume","hooks":[{"type":"command","command":"node \"/Users/me/.agent-config/vault-handoff.mjs\" start codex","timeout":30}]}'
VAULT_END='{"hooks":[{"type":"command","command":"node \"/Users/me/.agent-config/vault-handoff.mjs\" end codex","timeout":30}]}'
REAL="{\"hooks\":{\"PermissionRequest\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"$HOOK\"}]}],\"SessionStart\":[$VAULT_START],\"SessionEnd\":[$VAULT_END]}}"

# No Codex home: nothing to do, nothing created.
d="$ROOT/none"
CODEX_HOME="$d" "$INSTALLER" >/dev/null 2>&1
check "no Codex: exits 0" test $? -eq 0
check "no Codex: creates nothing" test ! -e "$d"

# A Codex home without hooks.json gets both entries.
d=$(home fresh)
run "$d"
check "fresh: PermissionRequest entry" test "$(q "$d" '.hooks.PermissionRequest')" = "[{\"hooks\":[{\"type\":\"command\",\"command\":\"$HOOK\"}]}]"
check "fresh: Interrupt entry" test "$(q "$d" '.hooks.Interrupt')" = "[{\"hooks\":[{\"type\":\"command\",\"command\":\"$AGENT_HOOK\"}]}]"
check "fresh: no backup of a file that wasn't there" test "$(backups "$d")" = 0

# An existing install: Nudge's PermissionRequest entry stays exactly where it
# is (Codex keys trust by position and content), the vault hooks are kept,
# and Interrupt is added.
d=$(home real "$REAL")
before_pr=$(q "$d" '.hooks.PermissionRequest')
run "$d"
check "real: PermissionRequest untouched" test "$(q "$d" '.hooks.PermissionRequest')" = "$before_pr"
check "real: SessionStart kept" test "$(q "$d" '.hooks.SessionStart')" = "[$VAULT_START]"
check "real: SessionEnd kept" test "$(q "$d" '.hooks.SessionEnd')" = "[$VAULT_END]"
check "real: Interrupt added" test "$(q "$d" '.hooks.Interrupt[0].hooks[0].command')" = "\"$AGENT_HOOK\""
check "real: backed up once" test "$(backups "$d")" = 1

# Running it again changes nothing, not even the mtime, and makes no backup.
cp -p "$d/hooks.json" "$ROOT/real-after-first"
sleep 1
run "$d"
check "rerun: file identical" cmp -s "$d/hooks.json" "$ROOT/real-after-first"
check "rerun: mtime unchanged" test "$(stat -f %m "$d/hooks.json")" = "$(stat -f %m "$ROOT/real-after-first")"
check "rerun: no new backup" test "$(backups "$d")" = 1
check "rerun: says so" grep -q "already" "$d.out"

# An older Nudge entry (no --agent) in the middle is replaced in place, and
# the other PermissionRequest hooks keep their positions.
OTHER1='{"hooks":[{"type":"command","command":"/usr/local/bin/audit-a"}]}'
OTHER2='{"matcher":"Bash","hooks":[{"type":"command","command":"/usr/local/bin/audit-b"}]}'
d=$(home old "{\"hooks\":{\"PermissionRequest\":[$OTHER1,{\"hooks\":[{\"type\":\"command\",\"command\":\"$BIN/nudge-hook\"}]},$OTHER2]}}")
run "$d"
check "old entry: replaced in place" test "$(q "$d" '.hooks.PermissionRequest[1].hooks[0].command')" = "\"$HOOK\""
check "old entry: hook before it kept" test "$(q "$d" '.hooks.PermissionRequest[0]')" = "$OTHER1"
check "old entry: hook after it kept" test "$(q "$d" '.hooks.PermissionRequest[2]')" = "$OTHER2"
check "old entry: nothing duplicated" test "$(q "$d" '.hooks.PermissionRequest | length')" = 3

# A handler sharing a group with Nudge's survives both install and uninstall.
MINE='{"type":"command","command":"/usr/local/bin/mine"}'
d=$(home shared "{\"hooks\":{\"PermissionRequest\":[{\"hooks\":[$MINE,{\"type\":\"command\",\"command\":\"$BIN/nudge-hook\"}]}]}}")
run "$d"
check "shared group: other handler kept first" test "$(q "$d" '.hooks.PermissionRequest[0].hooks[0]')" = "$MINE"
check "shared group: Nudge's updated in place" test "$(q "$d" '.hooks.PermissionRequest[0].hooks[1].command')" = "\"$HOOK\""
run "$d" --uninstall
check "shared group: uninstall keeps the other handler" test "$(q "$d" '.hooks.PermissionRequest')" = "[{\"hooks\":[$MINE]}]"
check "shared group: uninstall removes Interrupt" test "$(q "$d" '.hooks.Interrupt')" = "null"

# Duplicate Nudge entries collapse to the first one.
NUDGE_GROUP="{\"hooks\":[{\"type\":\"command\",\"command\":\"$HOOK\"}]}"
d=$(home dup "{\"hooks\":{\"PermissionRequest\":[$NUDGE_GROUP,$OTHER1,$NUDGE_GROUP]}}")
run "$d"
check "duplicates: one Nudge entry left" test "$(q "$d" '[.hooks.PermissionRequest[].hooks[].command | select(startswith("/Applications/Nudge.app"))] | length')" = 1
check "duplicates: first position kept" test "$(q "$d" '.hooks.PermissionRequest[0]')" = "$NUDGE_GROUP"

# Uninstall on the real-shaped file leaves exactly the vault hooks.
d=$(home uninstall "$REAL")
run "$d"
run "$d" --uninstall
expected=$(jq -ncS --argjson start "$VAULT_START" --argjson end "$VAULT_END" \
    '{hooks: {SessionStart: [$start], SessionEnd: [$end]}}')
check "uninstall: only the vault hooks left" test "$(jq -cS . "$d/hooks.json")" = "$expected"
n=$(backups "$d")
run "$d" --uninstall
check "uninstall again: no change, no backup" test "$(backups "$d")" = "$n"

# Malformed JSON is left alone.
d=$(home broken '{"hooks": {')
cp "$d/hooks.json" "$ROOT/broken-before"
run "$d"
check "malformed: fails" test $? -ne 0
check "malformed: file untouched" cmp -s "$d/hooks.json" "$ROOT/broken-before"

echo "install-codex-hook: $passed passed, $failed failed"
[[ $failed -eq 0 ]]
