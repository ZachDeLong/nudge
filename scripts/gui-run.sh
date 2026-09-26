#!/usr/bin/env bash
# Runs a command inside the logged-in GUI (Aqua) session and streams its
# output back. Needed over SSH: an SSH login gets its own security session in
# which the login keychain is locked, so `claude` reports "Not logged in".
# Apps started through LaunchServices (`open`) run in the GUI session instead,
# so this wraps the command in a throwaway background .app under /tmp.
#
# Usage: scripts/gui-run.sh <command> [args...]
#   e.g. scripts/gui-run.sh make e2e-claude ONLY=deny
# Runs in the current directory; exits with the command's exit status.
set -euo pipefail

if [[ $# -eq 0 ]]; then
    echo "usage: $0 <command> [args...]" >&2
    exit 2
fi

work=$(mktemp -d /tmp/nudge-gui-run.XXXXXX)
app="$work/NudgeGUIRun.app"
log="$work/output.log"
status_file="$work/status"
mkdir -p "$app/Contents/MacOS"
touch "$log"

cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>run</string>
  <key>CFBundleIdentifier</key><string>local.nudge.e2e.gui-run</string>
  <key>CFBundleName</key><string>NudgeGUIRun</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST

# A login shell, so Homebrew and ~/.local/bin are on PATH like in Terminal.
cat > "$app/Contents/MacOS/run" <<'RUN'
#!/bin/zsh -l
status_file="$1"; dir="$2"; shift 2
cd "$dir" || { echo 127 > "$status_file"; exit 127; }
"$@"
echo $? > "$status_file"
RUN
chmod +x "$app/Contents/MacOS/run"

open -W -g -n "$app" --stdout "$log" --stderr "$log" --args "$status_file" "$PWD" "$@" &
open_pid=$!
tail -n +1 -f "$log" &
tail_pid=$!
# Ctrl-C here can't reach the wrapped command (it isn't our child), so say so.
trap 'kill $tail_pid 2>/dev/null; echo "gui-run: interrupted; the command may still be running in the GUI session" >&2; exit 130' INT TERM
wait $open_pid || true
sleep 0.5
kill $tail_pid 2>/dev/null || true
wait $tail_pid 2>/dev/null || true

status=$(cat "$status_file" 2>/dev/null || echo 1)
rm -rf "$work"
exit "$status"
