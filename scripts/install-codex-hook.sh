#!/usr/bin/env bash
# Wires Nudge into Codex (CLI or the ChatGPT app) through ~/.codex/hooks.json:
#
# - PermissionRequest runs nudge-hook. It fires only when Codex is about to
#   ask for approval, and Nudge answers in its place.
# - Interrupt runs nudge-agent-hook. Codex leaves the PermissionRequest hook
#   running when you stop a turn; this tells Nudge to drop that prompt.
#
# Codex trusts each hook entry by its position and content, so this edits in
# place: an entry that's already right is left alone, an older Nudge entry is
# replaced where it is, and everything else in the file (other events, other
# handlers, even ones sharing a group with Nudge's) is kept as it was. The
# file is only rewritten, after a backup, when something changes.
#
# Usage: install-codex-hook.sh             (install)
#        install-codex-hook.sh --uninstall (remove Nudge's entries)
# CODEX_HOME picks another Codex home, as it does for Codex.

set -euo pipefail

CODEX_DIR="${CODEX_HOME:-$HOME/.codex}"
HOOKS="$CODEX_DIR/hooks.json"
BIN_DIR="/Applications/Nudge.app/Contents/MacOS"
# The CLI the ChatGPT app ships (it moved into codex-cli/bin in 26.9).
CODEX_CLI="/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex"
[[ -x "$CODEX_CLI" ]] || CODEX_CLI="/Applications/ChatGPT.app/Contents/Resources/codex"

UNINSTALL=0
[[ "${1:-}" == "--uninstall" ]] && UNINSTALL=1

if [[ ! -d "$CODEX_DIR" ]]; then
    [[ $UNINSTALL -eq 0 ]] && echo "  (no Codex at $CODEX_DIR, skipping)"
    exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "✗ jq is required but not installed." >&2
    echo "  Install with: brew install jq" >&2
    exit 1
fi

if [[ ! -f "$HOOKS" ]]; then
    [[ $UNINSTALL -eq 1 ]] && exit 0
    CURRENT='{}'
else
    if ! CURRENT=$(jq -e . "$HOOKS"); then
        echo "✗ $HOOKS isn't valid JSON; leaving it alone." >&2
        exit 1
    fi
fi

UPDATED=$(jq --arg bin "$BIN_DIR" --argjson uninstall "$UNINSTALL" '
    def nudge_handler($name): (.command // "") | startswith($bin + "/" + $name);

    # Puts `$want` where the first Nudge `$name` handler of `$event` is, drops
    # any other Nudge handler there (and groups that leaves empty), or appends
    # a new group if there was none. With $want null, only removes. Groups
    # without a Nudge handler are passed through untouched.
    def place($event; $name; $want):
      (.hooks[$event] // []) as $groups
      | ([$groups | to_entries[] | .key as $g | (.value.hooks // []) | to_entries[]
          | select(.value | nudge_handler($name)) | [$g, .key]] | first) as $first
      | [$groups | to_entries[] | .key as $g | .value as $group
          | if any(($group.hooks // [])[]; nudge_handler($name)) then
              $group
              | .hooks = [.hooks | to_entries[]
                  | if [$g, .key] == $first and $want != null then $want
                    elif (.value | nudge_handler($name)) then empty
                    else .value end]
              | select((.hooks | length) > 0)
            else $group end] as $kept
      | (if $first == null and $want != null then $kept + [{"hooks": [$want]}] else $kept end) as $new
      | if ($new | length) > 0 then .hooks[$event] = $new
        elif .hooks[$event] != null then del(.hooks[$event])
        else . end;

    def handler($name): {"type": "command", "command": ($bin + "/" + $name + " --agent codex")};

    .hooks //= {}
    | if $uninstall == 1 then
        reduce (.hooks | keys[]) as $event (.;
          place($event; "nudge-hook"; null) | place($event; "nudge-agent-hook"; null))
      else
        place("PermissionRequest"; "nudge-hook"; handler("nudge-hook"))
        | place("Interrupt"; "nudge-agent-hook"; handler("nudge-agent-hook"))
      end
    | if (.hooks | length) == 0 then del(.hooks) else . end
' <<<"$CURRENT")

if [[ "$(jq -S . <<<"$CURRENT")" == "$(jq -S . <<<"$UPDATED")" ]]; then
    if [[ $UNINSTALL -eq 1 ]]; then
        echo "  (no Nudge hooks in $HOOKS)"
    else
        echo "✓ Nudge's Codex hooks are already in $HOOKS"
    fi
    exit 0
fi

if [[ -f "$HOOKS" ]]; then
    BACKUP="$HOOKS.bak.$(date +%s)"
    cp -p "$HOOKS" "$BACKUP"
    # Keep the five newest backups.
    ls -1t "$HOOKS".bak.* 2>/dev/null | tail -n +6 | while IFS= read -r OLD; do
        rm -f "$OLD"
    done
fi
# Write through a symlinked hooks.json and keep the file's permissions.
TARGET="$HOOKS"
[[ -e "$HOOKS" ]] && TARGET="$(realpath "$HOOKS")"
printf '%s\n' "$UPDATED" > "$TARGET.tmp"
[[ -f "$TARGET" ]] && chmod "$(stat -f %Lp "$TARGET")" "$TARGET.tmp"
mv "$TARGET.tmp" "$TARGET"

if [[ $UNINSTALL -eq 1 ]]; then
    echo "✓ Removed Nudge's hooks from $HOOKS"
    [[ -n "${BACKUP:-}" ]] && echo "  Backup: $BACKUP"
    exit 0
fi

echo "✓ Installed Nudge's Codex hooks into $HOOKS"
[[ -n "${BACKUP:-}" ]] && echo "  Backup: $BACKUP"
echo "  Codex skips new or changed hooks until you trust them. Once, in a terminal:"
if [[ -x "$CODEX_CLI" ]]; then
    echo "    $CODEX_CLI"
else
    echo "    codex"
fi
echo "  then type /hooks and trust Nudge's two entries. (That screen can trust"
echo "  every pending hook at once, so check the list first.)"
