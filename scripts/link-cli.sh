#!/usr/bin/env bash
# Symlinks /Applications/Nudge.app/Contents/MacOS/nudge-claude into a writable
# PATH directory so the user can just run `nudge-claude`. Tries the standard
# Homebrew/XDG locations in order; falls back to a hint if none are writable.
#
# Usage: link-cli.sh             (install)
#        link-cli.sh --uninstall (remove the symlink)

set -euo pipefail

TARGET="/Applications/Nudge.app/Contents/MacOS/nudge-claude"
NAME="nudge-claude"

# Order matters: pick the most-likely-on-PATH option that the user can write to
# without sudo. Homebrew prefixes vary by architecture, so check both.
CANDIDATES=(
    "/opt/homebrew/bin"
    "/usr/local/bin"
    "$HOME/.local/bin"
    "$HOME/bin"
)

if [[ "${1:-}" == "--uninstall" ]]; then
    for dir in "${CANDIDATES[@]}"; do
        link="$dir/$NAME"
        if [[ -L "$link" ]] && [[ "$(readlink "$link")" == "$TARGET" ]]; then
            rm -f "$link"
            echo "  Removed $link"
        fi
    done
    exit 0
fi

if [[ ! -x "$TARGET" ]]; then
    echo "  ✗ $TARGET not found — install Nudge.app first." >&2
    exit 1
fi

for dir in "${CANDIDATES[@]}"; do
    if [[ -d "$dir" ]] && [[ -w "$dir" ]]; then
        ln -sf "$TARGET" "$dir/$NAME"
        echo "  ✓ Linked $dir/$NAME → $TARGET"
        if ! command -v "$NAME" >/dev/null 2>&1; then
            echo "  ⚠ $dir is not in your PATH. Add it to your shell rc:"
            echo "      export PATH=\"$dir:\$PATH\""
        fi
        exit 0
    fi
done

echo "  ⚠ No writable directory found in PATH. Run nudge-claude via:"
echo "      $TARGET"
echo "  Or symlink it manually:"
echo "      ln -sf '$TARGET' /usr/local/bin/$NAME"
