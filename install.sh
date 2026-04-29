#!/usr/bin/env bash
# One-line installer for Nudge.
#
#   curl -fsSL https://raw.githubusercontent.com/ZachDeLong/nudge/main/install.sh | bash
#
# Clones the repo to a temporary directory, builds the .app, copies it to
# /Applications, and wires the Claude Code hook into ~/.claude/settings.json.
# Idempotent: safe to re-run when there's a new version.

set -euo pipefail

REPO="https://github.com/ZachDeLong/nudge.git"
TMP_DIR="$(mktemp -d -t nudge-install)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "→ Cloning $REPO into $TMP_DIR"
git clone --depth 1 "$REPO" "$TMP_DIR/nudge"

cd "$TMP_DIR/nudge"
echo "→ Building (release config)…"
make install

echo
echo "✓ Nudge is installed at /Applications/Nudge.app"
echo
echo "Next steps:"
echo "  1. Edit ~/.config/nudge/patterns.txt to control what triggers a popover."
echo "  2. (Optional) Drop the skill at skills/nudge-ask/ into ~/.claude/skills/"
echo "     so Claude knows to call nudge-ask for free-form questions."
echo "  3. To uninstall: cd into a clone of the repo and run \`make uninstall\`."
