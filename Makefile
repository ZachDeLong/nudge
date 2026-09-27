.PHONY: build clean run app install uninstall sync-patterns import-permissions test e2e e2e-claude e2e-codex test-popup previews icon

CONFIG ?= release
BUILD_DIR := .build/$(CONFIG)
APP_DEST := /Applications/Nudge.app
# Quit Nudge by path, never by name: another app can be called Nudge.
KILL_APP = pkill -f '^$(APP_DEST)/Contents/MacOS/Nudge' 2>/dev/null || true
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
	-$(KILL_APP)
	rm -rf $(APP_DEST)
	cp -R $(BUILD_DIR)/Nudge.app $(APP_DEST)
	xattr -dr com.apple.quarantine $(APP_DEST) 2>/dev/null || true
	@echo "→ Seeding patterns (if missing) + importing from settings.json…"
	./scripts/seed-patterns.sh
	@echo "→ Wiring hooks into Claude Code…"
	./scripts/install-hook.sh
	@echo "→ Wiring hooks into Codex (if you use it)…"
	./scripts/install-codex-hook.sh
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
	./Tests/install/claude-hook-test.sh
	./Tests/install/codex-hook-test.sh

# End-to-end: recorded Claude Code hook payloads through the real nudge-hook
# into a real Nudge, answered over its test API. Runs its own isolated Nudge
# (temp config dir, port, token), so the installed app and ~/.config/nudge
# are never touched. A second menu bar icon may flash while it runs.
# Usage: make e2e                  (all fixtures in Tests/e2e/fixtures)
#        make e2e ONLY=withdrawal  (fixtures whose name contains ONLY)
e2e:
	swift build -c $(CONFIG)
	$(BUILD_DIR)/nudge-test-e2e --bin-dir $(BUILD_DIR) --fixtures Tests/e2e/fixtures $(ONLY)

# End-to-end, layer 2: real `claude -p` sessions (MODEL, default haiku) in
# throwaway git sandboxes under /tmp, hooked to the same kind of isolated
# Nudge. Asserts on real effects (did the local bare remote get the push).
# Costs a few cents per scenario. ~/.claude/settings.json is never loaded
# (--setting-sources project), and each run checks that no real hook fired.
# One scenario clicks the popover with Peekaboo, so it needs Screen Recording
# and Accessibility for Peekaboo. Transcripts and screenshots land in
# .build/e2e-claude/<timestamp>/.
# Over SSH the keychain is locked and claude isn't logged in; wrap it:
#   scripts/gui-run.sh make e2e-claude
# Usage: make e2e-claude              (all scenarios in Tests/e2e/claude)
#        make e2e-claude ONLY=deny    (scenarios whose name contains ONLY)
MODEL ?= haiku
e2e-claude:
	swift build -c $(CONFIG)
	$(BUILD_DIR)/nudge-test-e2e --claude --model $(MODEL) --bin-dir $(BUILD_DIR) --fixtures Tests/e2e/claude $(ONLY)

# End-to-end, layer 2 for Codex: real Codex, driven over `codex app-server`
# the way the ChatGPT app drives it, in throwaway CODEX_HOMEs and git repos
# under /tmp, with the hooks install-codex-hook.sh writes pointed at this
# build and an isolated Nudge. Asserts on real effects (did the command run,
# did Codex fall back to its own prompt). Each temp home gets a copy of
# ~/.codex/auth.json, deleted with it; ~/.codex's hooks.json and config.toml
# are never loaded, and the run checks they didn't change. Uses a little of
# your Codex usage per scenario (CODEX_MODEL, default gpt-6-luna).
# Usage: make e2e-codex               (all scenarios in Tests/e2e/codex)
#        make e2e-codex ONLY=deny     (scenarios whose name contains ONLY)
CODEX_MODEL ?= gpt-6-luna
e2e-codex:
	swift build -c $(CONFIG)
	$(BUILD_DIR)/nudge-test-e2e --codex --model $(CODEX_MODEL) --bin-dir $(BUILD_DIR) --fixtures Tests/e2e/codex $(ONLY)

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
	-$(KILL_APP)
	rm -rf $(APP_DEST)
	rm -f $(HOME)/.config/nudge/port $(HOME)/.config/nudge/token $(HOME)/.config/nudge/no-autolaunch
	@./scripts/link-cli.sh --uninstall
	./scripts/uninstall-hook.sh
	./scripts/install-codex-hook.sh --uninstall
	@echo "✓ Nudge uninstalled."
