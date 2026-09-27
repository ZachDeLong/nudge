#!/usr/bin/env bash
# Connects Nudge to Claude Code (and Codex, if it's installed): seeds
# ~/.config/nudge/patterns.txt, wires the hooks, and starts Nudge. Shipped
# inside Nudge.app so installs that didn't come from a clone (Homebrew, the
# release zip) can set up with one command. Safe to run again.
#
# Usage: nudge-setup           connect
#        nudge-setup --remove  disconnect (your patterns and prefs stay)

set -euo pipefail

# Homebrew links this script into its bin dir, so follow the link to find the
# helper scripts next to the real file.
self="$0"
while [[ -L "$self" ]]; do
    link="$(readlink "$self")"
    [[ "$link" == /* ]] && self="$link" || self="$(dirname "$self")/$link"
done
here="$(cd "$(dirname "$self")" && pwd)"

case "${1:-}" in
    "")
        "$here/seed-patterns.sh"
        "$here/install-hook.sh"
        "$here/install-codex-hook.sh"
        # Open this bundle (or failing that the bundle ID), never the name:
        # other apps are called Nudge too.
        app="$(cd "$here/../../.." && pwd)"
        if [[ "$app" == *.app ]]; then
            open -g "$app" 2>/dev/null || true
        else
            open -gb com.zachdelong.Nudge 2>/dev/null || true
        fi
        echo "✓ Nudge is connected. Its icon is in the menu bar."
        ;;
    --remove)
        "$here/uninstall-hook.sh"
        "$here/install-codex-hook.sh" --uninstall
        echo "✓ Nudge's hooks are removed. Your patterns and prefs stay in ~/.config/nudge."
        ;;
    *)
        echo "usage: nudge-setup [--remove]" >&2
        exit 2
        ;;
esac
