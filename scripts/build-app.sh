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

# Setup scripts ride along in the bundle so installs without a clone
# (Homebrew, the release zip) can run `nudge-setup`.
SETUP="$APP/Contents/Resources/setup"
mkdir -p "$SETUP"
for f in nudge-setup.sh seed-patterns.sh default-patterns.txt install-hook.sh uninstall-hook.sh install-codex-hook.sh; do
    cp "$ROOT/scripts/$f" "$SETUP/$f"
done
chmod +x "$SETUP"/*.sh

# Signing with a stable identity (CI sets NUDGE_SIGN_IDENTITY from a
# self-signed certificate) makes macOS identify Nudge by that certificate
# instead of by each build's hash, so the Accessibility grant survives
# updates. Without it the binaries keep the linker's ad-hoc signature.
# NUDGE_SIGN_KEYCHAIN optionally names the keychain holding the identity.
if [[ -n "${NUDGE_SIGN_IDENTITY:-}" ]]; then
    # Hardened runtime: without it the loader honours DYLD_INSERT_LIBRARIES,
    # so any process could start Nudge with its own code inside and borrow
    # the Accessibility grant. Nudge needs no entitlements to run under it.
    sign=(codesign --force --timestamp=none --options runtime --sign "$NUDGE_SIGN_IDENTITY")
    if [[ -n "${NUDGE_SIGN_KEYCHAIN:-}" ]]; then
        sign+=(--keychain "$NUDGE_SIGN_KEYCHAIN")
    fi
    # Helpers first: the bundle signature seals them as nested code.
    for bin in "${BINARIES[@]}"; do
        [[ "$bin" == Nudge ]] && continue
        "${sign[@]}" --identifier "com.zachdelong.Nudge.$bin" "$APP/Contents/MacOS/$bin"
    done
    "${sign[@]}" "$APP"
    codesign --verify --strict "$APP"
    echo "✓ Signed with \"$NUDGE_SIGN_IDENTITY\""
fi

echo "✓ Assembled $APP"
