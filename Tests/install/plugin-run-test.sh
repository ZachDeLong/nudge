#!/usr/bin/env bash
# Tests plugin/bin/nudge-run, the wrapper the Claude Code plugin's hooks go
# through, against a fake app and throwaway homes.
# Usage: Tests/install/plugin-run-test.sh   (from the repo root)

set -uo pipefail

RUN="$(cd "$(dirname "$0")/../.." && pwd)/plugin/bin/nudge-run"
ROOT=$(mktemp -d /tmp/nudge-plugin-run-test.XXXXXX)
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

# A fake Nudge.app/Contents/MacOS whose nudge-hook records how it was run.
APP="$ROOT/app"
mkdir -p "$APP"
cat > "$APP/nudge-hook" <<'HOOK'
#!/bin/sh
{ echo "args:$*"; echo "stdin:$(cat)"; } > "$NUDGE_TEST_LOG"
exit 3
HOOK
chmod +x "$APP/nudge-hook"

home() { # a fresh home, optionally with ~/.claude/settings.json
    local dir="$ROOT/$1"
    mkdir -p "$dir/.claude"
    [[ -n "${2:-}" ]] && printf '%s\n' "$2" > "$dir/.claude/settings.json"
    echo "$dir"
}
# run <home> [env...]: runs `nudge-run nudge-hook --agent claude` with a
# payload on stdin; leaves the exit status in $status and output in $out.
run() {
    local h=$1; shift
    export NUDGE_TEST_LOG="$h.log"
    rm -f "$NUDGE_TEST_LOG"
    out=$(echo '{"tool_name":"Bash"}' | env -u CLAUDE_CONFIG_DIR -u NUDGE_PLUGIN_FORCE \
        HOME="$h" NUDGE_APP_BIN_DIR="$APP" "$@" "$RUN" nudge-hook --agent claude 2>&1)
    status=$?
}
ran() { [[ -f "$NUDGE_TEST_LOG" ]]; }
not_ran() { [[ ! -f "$NUDGE_TEST_LOG" ]]; }
quiet_ok() { [[ $status -eq 0 && -z "$out" ]]; }

WIRED="{\"hooks\":{\"PreToolUse\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"$APP/nudge-hook\"}]}]}}"

# No settings: runs the helper with its arguments and stdin, and passes its
# exit status through.
h=$(home plain)
run "$h"
check "plain: helper ran" ran
check "plain: arguments passed" grep -qx 'args:--agent claude' "$h.log"
check "plain: stdin passed" grep -qx 'stdin:{"tool_name":"Bash"}' "$h.log"
check "plain: exit status passed through" test "$status" -eq 3

# Settings without Nudge's hooks: still runs.
h=$(home other '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/usr/local/bin/my-hook"}]}]}}')
run "$h"
check "other hooks: helper ran" ran

# nudge-setup already wired Nudge into settings.json: stays out of the way.
h=$(home wired "$WIRED")
run "$h"
check "wired: helper not run" not_ran
check "wired: quiet exit 0" quiet_ok

# ...also when that settings.json is in CLAUDE_CONFIG_DIR.
h=$(home configdir)
mkdir -p "$h/cfg" && printf '%s\n' "$WIRED" > "$h/cfg/settings.json"
run "$h" CLAUDE_CONFIG_DIR="$h/cfg"
check "CLAUDE_CONFIG_DIR wired: helper not run" not_ran

# NUDGE_PLUGIN_FORCE skips that check.
h=$(home forced "$WIRED")
run "$h" NUDGE_PLUGIN_FORCE=1
check "forced: helper ran" ran

# No app: quiet no-op, so Claude Code shows its own prompt.
h=$(home noapp)
run "$h" NUDGE_APP_BIN_DIR="$ROOT/missing"
check "no app: helper not run" not_ran
check "no app: quiet exit 0" quiet_ok

echo "plugin-run: $passed passed, $failed failed"
[[ $failed -eq 0 ]]
