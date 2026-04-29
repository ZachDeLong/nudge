.PHONY: build clean run install uninstall sync-patterns import-permissions test-popup

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

# Builds an .app bundle in $(BUILD_DIR)/Nudge.app and installs it to /Applications.
install: build
	@echo "→ Building app bundle…"
	rm -rf $(BUILD_DIR)/Nudge.app
	mkdir -p $(BUILD_DIR)/Nudge.app/Contents/MacOS
	cp $(BUILD_DIR)/Nudge $(BUILD_DIR)/Nudge.app/Contents/MacOS/Nudge
	cp $(BUILD_DIR)/nudge-hook $(BUILD_DIR)/Nudge.app/Contents/MacOS/nudge-hook
	cp $(BUILD_DIR)/nudge-ask $(BUILD_DIR)/Nudge.app/Contents/MacOS/nudge-ask
	cp Resources-Info.plist $(BUILD_DIR)/Nudge.app/Contents/Info.plist
	@echo "→ Copying to /Applications…"
	-pkill -x Nudge 2>/dev/null || true
	rm -rf $(APP_DEST)
	cp -R $(BUILD_DIR)/Nudge.app $(APP_DEST)
	xattr -dr com.apple.quarantine $(APP_DEST) 2>/dev/null || true
	@echo "→ Seeding patterns (if missing) + importing from settings.json…"
	./scripts/seed-patterns.sh
	@echo "→ Wiring hooks into Claude Code…"
	./scripts/install-hook.sh
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

# Fires a test prompt directly at Nudge's HTTP server (bypasses Claude Code).
# Usage: make test-popup            (default: git push --force, default mode)
#        make test-popup CMD="rm -rf /tmp/foo"
#        make test-popup CMD="" TOOL=Edit
#        make test-popup MODE=auto       (auto mode → no Always button)
test-popup:
	./scripts/test-popup.sh "$(CMD)" "$(TOOL)" "$(MODE)"

uninstall:
	-pkill -x Nudge 2>/dev/null || true
	rm -rf $(APP_DEST)
	rm -f $(HOME)/.config/nudge/port
	./scripts/uninstall-hook.sh
	@echo "✓ Nudge uninstalled."
