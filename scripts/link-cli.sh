#!/usr/bin/env bash
# Symlinks Nudge's user-facing CLIs (nudge-claude, nudge-update) into a
# writable PATH directory. Tries the standard Homebrew/XDG locations in
# order; falls back to a hint if none are writable.
#
# Usage: link-cli.sh             (install)
#        link-cli.sh --uninstall (remove the symlinks)

set -euo pipefail

APP_DIR="/Applications/Nudge.app/Contents/MacOS"
NAMES=("nudge-claude" "nudge-update")

# Order matters: pick the most-likely-on-PATH option that the user can write to
# without sudo. Homebrew prefixes vary by architecture, so check both.
CANDIDATES=(
    "/opt/homebrew/bin"
    "/usr/local/bin"
    "$HOME/.local/bin"
    "$HOME/bin"
)

if [[ "${1:-}" == "--uninstall" ]]; then
    for name in "${NAMES[@]}"; do
        target="$APP_DIR/$name"
        for dir in "${CANDIDATES[@]}"; do
            link="$dir/$name"
            if [[ -L "$link" ]] && [[ "$(readlink "$link")" == "$target" ]]; then
                rm -f "$link"
                echo "  Removed $link"
            fi
        done
    done
    exit 0
fi

# Pick the first writable directory and put all symlinks there together.
DEST=""
for dir in "${CANDIDATES[@]}"; do
    if [[ -d "$dir" ]] && [[ -w "$dir" ]]; then
        DEST="$dir"
        break
    fi
done

if [[ -z "$DEST" ]]; then
    echo "  ⚠ No writable directory found in PATH. Run the binaries directly:"
    for name in "${NAMES[@]}"; do
        echo "      $APP_DIR/$name"
    done
    exit 0
fi

for name in "${NAMES[@]}"; do
    target="$APP_DIR/$name"
    if [[ ! -x "$target" ]]; then
        echo "  ✗ $target not found — install Nudge.app first." >&2
        continue
    fi
    ln -sf "$target" "$DEST/$name"
    echo "  ✓ Linked $DEST/$name → $target"
done

if ! echo ":$PATH:" | grep -q ":$DEST:"; then
    echo "  ⚠ $DEST is not in your PATH. Add it to your shell rc:"
    echo "      export PATH=\"$DEST:\$PATH\""
fi
