.PHONY: build clean run install uninstall sync-patterns

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
	cp Resources-Info.plist $(BUILD_DIR)/Nudge.app/Contents/Info.plist
	@echo "→ Copying to /Applications…"
	-pkill -x Nudge 2>/dev/null || true
	rm -rf $(APP_DEST)
	cp -R $(BUILD_DIR)/Nudge.app $(APP_DEST)
	xattr -dr com.apple.quarantine $(APP_DEST) 2>/dev/null || true
	@echo "→ Seeding default patterns (if missing)…"
	mkdir -p $(HOME)/.config/nudge
	[ -f $(PATTERNS_FILE) ] || cp scripts/default-patterns.txt $(PATTERNS_FILE)
	@echo "→ Wiring hooks into Claude Code…"
	./scripts/install-hook.sh
	@echo ""
	@echo "✓ Nudge installed."
	@echo "  Launch: open -ga Nudge"
	@echo "  Patterns: $(PATTERNS_FILE)"
	@echo "  Re-sync after editing: make sync-patterns"

# Re-reads patterns.txt and rewrites the hook entries in settings.json.
sync-patterns:
	./scripts/install-hook.sh
	@echo "✓ Hook entries synced from $(PATTERNS_FILE)"

uninstall:
	-pkill -x Nudge 2>/dev/null || true
	rm -rf $(APP_DEST)
	rm -f $(HOME)/.config/nudge/port
	./scripts/uninstall-hook.sh
	@echo "✓ Nudge uninstalled."
