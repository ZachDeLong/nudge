#!/usr/bin/env bash
# Assembles Nudge.app from SwiftPM build products. Shared by `make install`,
# CI and the release workflow so the three can't drift on which binaries ship.
#
# Usage: build-app.sh [build-dir]   (default: .build/release; run `swift build` first)

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${1:-$ROOT/.build/release}"
APP="$BUILD_DIR/Nudge.app"
BINARIES=(Nudge nudge-hook nudge-agent-hook nudge-ask nudge-claude nudge-update)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
for bin in "${BINARIES[@]}"; do
    cp "$BUILD_DIR/$bin" "$APP/Contents/MacOS/$bin"
done
cp "$ROOT/Resources-Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

echo "✓ Assembled $APP"
