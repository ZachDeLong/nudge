.PHONY: build clean run app install uninstall sync-patterns import-permissions test test-popup previews icon

CONFIG ?= release
BUILD_DIR := .build/$(CONFIG)
APP_DEST := /Applications/Nudge.app
PATTERNS_FILE := $(HOME)/.config/nudge/patterns.txt

build:
	swift build -c $(CONFIG)

clean:
	swift package clean
	rm -rf .build

run: build
	$(BUILD_DIR)/Nudge

# Builds an .app bundle in $(BUILD_DIR)/Nudge.app without installing it.
app: build
	./scripts/build-app.sh $(BUILD_DIR)

# Builds an .app bundle in $(BUILD_DIR)/Nudge.app and installs it to /Applications.
install: build
	@echo "→ Building app bundle…"
	./scripts/build-app.sh $(BUILD_DIR)
	@echo "→ Copying to /Applications…"
	-pkill -x Nudge 2>/dev/null || true
	rm -rf $(APP_DEST)
	cp -R $(BUILD_DIR)/Nudge.app $(APP_DEST)
	xattr -dr com.apple.quarantine $(APP_DEST) 2>/dev/null || true
	@echo "→ Seeding patterns (if missing) + importing from settings.json…"
	./scripts/seed-patterns.sh
	@echo "→ Wiring hooks into Claude Code…"
	./scripts/install-hook.sh
	@echo "→ Symlinking nudge-claude into PATH…"
	@./scripts/link-cli.sh
	@echo "→ Launching Nudge…"
	open -ga Nudge
	@echo ""
	@echo "✓ Nudge installed and running."
	@echo "  Patterns: $(PATTERNS_FILE)"
	@echo "  Re-sync after editing: make sync-patterns"

# Re-reads patterns.txt and rewrites the hook entries in settings.json.
sync-patterns:
	./scripts/install-hook.sh
	@echo "✓ Hook entries synced from $(PATTERNS_FILE)"

# Merges any new Bash() rules from settings.json's permissions.ask into patterns.txt.
# Existing patterns are preserved.
import-permissions:
	./scripts/seed-patterns.sh --merge
	@echo "✓ Patterns merged. Active list: $(PATTERNS_FILE)"

# XCTest needs full Xcode (not Command Line Tools), so skip it gracefully on
# CLT-only machines. The matching+token suite always runs.
test:
	@if xcrun --find xctest >/dev/null 2>&1; then \
		swift test -c $(CONFIG); \
	else \
		echo "(skipping swift test — install full Xcode to run XCTest coverage)"; \
	fi
	swift build --product nudge-test-matching -c $(CONFIG)
	$(BUILD_DIR)/nudge-test-matching

# Fires a test prompt directly at Nudge's HTTP server (bypasses Claude Code).
# Usage: make test-popup            (default: git push --force, default mode)
#        make test-popup CMD="rm -rf /tmp/foo"
#        make test-popup CMD="" TOOL=Edit
#        make test-popup MODE=auto       (auto mode → no Always button)
test-popup:
	./scripts/test-popup.sh "$(CMD)" "$(TOOL)" "$(MODE)"

# Renders every popover state to .build/previews/*.png without touching the
# running app — quick way to eyeball UI changes or refresh README screenshots.
previews: build
	$(BUILD_DIR)/Nudge --render-previews $(BUILD_DIR)/previews
	@echo "✓ Previews in $(BUILD_DIR)/previews/"

# Regenerates assets/AppIcon.icns from scripts/render-icon.swift.
icon:
	swift scripts/render-icon.swift

uninstall:
	-pkill -x Nudge 2>/dev/null || true
	rm -rf $(APP_DEST)
	rm -f $(HOME)/.config/nudge/port $(HOME)/.config/nudge/token $(HOME)/.config/nudge/no-autolaunch
	@./scripts/link-cli.sh --uninstall
	./scripts/uninstall-hook.sh
	@echo "✓ Nudge uninstalled."
