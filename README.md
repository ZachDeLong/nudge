# Nudge

A macOS menu bar app for Claude Code permission prompts. When Claude wants to run something risky like `git push --force`, Nudge pops a small panel out of the menu bar instead of asking back in the terminal. Click Allow from wherever you are.

It also ships with `nudge-ask`, a small CLI Claude can call when it needs a free-form text answer from you. Same popover style, with a text field instead of Allow/Deny.

## Why I built it

I run Claude Code in auto mode and keep it on a side monitor. When something risky comes up, auto mode is supposed to stop and ask. But the prompt shows up in whichever terminal Claude is running in, and if I'm testing the app it just built, I don't see it for thirty seconds. Nudge surfaces those moments in the menu bar so I can answer without hunting.

It's opt-in, not a security blanket. You list patterns in `~/.config/nudge/patterns.txt`. Anything matching pops up; anything else goes through the normal Claude Code flow.

## Install

One line:

```sh
curl -fsSL https://raw.githubusercontent.com/ZachDeLong/nudge/main/install.sh | bash
```

Or manually:

```sh
git clone https://github.com/ZachDeLong/nudge.git
cd nudge
make install
```

Either way builds the app, copies it to `/Applications/Nudge.app`, seeds default patterns, wires a `PreToolUse` hook into `~/.claude/settings.json`, and launches Nudge in the background.

Requirements: macOS 14+ and Xcode Command Line Tools. No full Xcode needed.

## How it works

Two halves:

- **The app** runs as a menu bar icon. It owns an `NSStatusItem`, a popover, and a tiny localhost HTTP server. The server is how the hook talks to it.
- **The hook** is a small Swift CLI at `Nudge.app/Contents/MacOS/nudge-hook`. Claude Code runs it via the `PreToolUse` hook. It reads the tool call from stdin, checks `patterns.txt`, and POSTs to the app if there's a match. Then it blocks until you click Allow or Deny.

If the app isn't running when the hook fires, the hook auto-launches it via `open -ga Nudge`. If anything fails, the hook exits silently and Claude falls back to its normal terminal prompt.

## Patterns

`~/.config/nudge/patterns.txt` controls everything. One Claude Code permission rule per line. The hook re-reads it on every call, so edits take effect immediately.

```
# Bash
Bash(git push:*)        # command starts with `git push`
Bash(rm:*)              # command starts with `rm`
Bash(*--force*)         # command contains --force anywhere
Bash(git rebase)        # exact match

# File-based tools (Edit, Write, Read, MultiEdit, NotebookEdit)
Edit(/etc/**)               # any file under /etc
Write(**/.env*)             # any .env-something file, anywhere
Edit(/Users/**/.claude/**)  # any user's claude config
```

`*` matches a single path segment; `**` matches across slashes. Bash supports prefix (`x:*`), infix (`*x*`), and exact match.

When you install, Nudge also imports `Bash()`-style rules from your existing `permissions.ask` array in `~/.claude/settings.json`. So if you've already told Claude Code to ask about `git push:*`, Nudge picks that up automatically. Run `make import-permissions` later to merge in new ones.

## "Always allow"

Each popover has a `⋯` button next to Allow with two options:

- **Allow for this session.** Adds the exact command to an in-memory list, won't ask again until you restart Nudge.
- **Always allow this command.** Promotes the matched pattern (e.g. `Bash(git push:*)`) into your `permissions.allow`. Claude auto-allows the whole class going forward; Nudge stops prompting.

The menu only shows up when the matched pattern can be promoted to a valid Claude rule. Infix patterns like `Bash(*--force*)` aren't promotable, so on those you only see Allow / Deny. If a command matches both an infix and a prefix pattern, the infix wins on safety: promoting `git push:*` would also auto-allow `git push --force` next time, which is the bad path.

## nudge-ask

A CLI Claude can call when it needs a free-form text answer.

```sh
/Applications/Nudge.app/Contents/MacOS/nudge-ask "Which deployment target?"
# popover with a text field appears
# user types "staging", clicks Send
# "staging" lands on stdout
```

Exit code 0 with the answer on stdout. Exit code 130 if the user cancels. Anything else if Nudge is unreachable.

To opt Claude into using it, drop the skill into your skills directory:

```sh
cp -R skills/nudge-ask ~/.claude/skills/
```

Or paste this into your Claude Code session and Claude will wire it up itself:

> Add `Bash(/Applications/Nudge.app/Contents/MacOS/nudge-ask:*)` to my `~/.claude/settings.json` permissions.allow array. Then append this to `~/.claude/CLAUDE.md`: "When you need a free-form text answer from me, run `/Applications/Nudge.app/Contents/MacOS/nudge-ask "<question>"` via Bash and use stdout as my reply."

Either way, pre-allowing the `Bash(...:*)` rule keeps Claude from prompting before each call.

## Known limits

- **Personal use only for now.** The build is unsigned. The Makefile runs `xattr -d com.apple.quarantine` so it launches without Gatekeeper drama, but it isn't notarized.
- **One Mac at a time.** Patterns aren't synced across machines.
- **Hooks fire before Claude classifies.** That's why patterns are explicit opt-in rather than "everything auto mode would prompt about." `PreToolUse` runs before Claude decides whether a call would trigger a prompt, and the `PermissionRequest` event (which fires at the right time) is observe-only.
- **Queue is FIFO with a 5-minute timeout.** Pile up enough prompts and the older ones expire.

## Uninstall

```sh
cd /path/to/nudge && make uninstall
```

Removes `/Applications/Nudge.app`, kills the running app, and cleans the hook out of `settings.json` (with a backup).

## License

MIT. See [LICENSE](./LICENSE).
