# Nudge

Claude Code permission prompts, in your menu bar.

When Claude stops to ask before running something (a `git push --force`, an edit to a config file), Nudge pops a panel out of the menu bar so you can click Allow from whatever app you're in. You don't have to go find the terminal.

Nudge asks exactly when Claude Code would ask. If an allow rule or auto mode already covers a call, you don't see it. Plan approvals and Claude's multiple-choice questions stay in the terminal.

It's a quality-of-life tool, not a security tool. The terminal still works: answer there and Nudge's copy goes away.

![Nudge asking to allow a git push, under its menu bar icon](./docs/img/hero.png)

## What's in the box

- **Permission popover.** Allow, Deny, allow for this session, or always allow. Enter and Esc work from any app once you grant Accessibility access.
- **`nudge-ask`.** A CLI Claude can call when it needs a typed answer from you. Same popover, with a text field.
- **Agent sessions** (experimental). `nudge-claude` runs Claude Code in tmux, and the menu bar shows the live transcript with a reply box.
- **`nudge-update`.** Checks GitHub for a new release and installs it after verifying the checksum.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/ZachDeLong/nudge/main/install.sh | bash
```

Or clone and `make install`. Either way it builds the app into `/Applications/Nudge.app`, seeds default patterns, adds the hooks to `~/.claude/settings.json`, links `nudge-claude` and `nudge-update` onto your PATH, and launches Nudge.

You'll need macOS 14+, Xcode Command Line Tools, and `jq` (`brew install jq`). Agent sessions also need `tmux`.

<details>
<summary>Pre-built bundle instead of building from source</summary>

Grab `Nudge.app.zip` from the [latest release](https://github.com/ZachDeLong/nudge/releases/latest), unzip it into `/Applications`, and clear the quarantine flag (the build is unsigned):

```sh
xattr -dr com.apple.quarantine /Applications/Nudge.app
```

Then wire up the hooks from a clone of the repo:

```sh
git clone https://github.com/ZachDeLong/nudge.git && cd nudge
./scripts/seed-patterns.sh
./scripts/install-hook.sh
open -ga Nudge
```

</details>

## Patterns

Patterns are for things you want to be asked about even when Claude wouldn't ask, like a command you've allow-listed or anything in auto mode. They live in `~/.config/nudge/patterns.txt`, one rule per line, and edits apply immediately. An empty file is fine: Nudge still shows Claude's own prompts.

```
Bash(git push:*)        # prefix
Bash(*--force*)         # infix
Edit(/etc/**)           # path glob
Mcp(playwright__*)      # every tool on an MCP server
```

"Always allow" from the popover writes a matching rule into Claude Code's allow list, after backing up `settings.json`. The full syntax, chained-command handling, and importing from `permissions.ask` are in [docs/patterns.md](docs/patterns.md).

## Settings

Click the menu bar icon when there's no prompt up, or right-click it to get the same toggles as a menu.

![Nudge's settings panel](./docs/img/settings.png)

A few things the panel doesn't tell you:

- **⏎ / esc from any app** needs Accessibility access: System Settings → Privacy & Security → Accessibility, which macOS 27 renamed Device Control and Data Access. The Enable… button in the panel opens it. The build is unsigned, so macOS forgets that grant after every update. Remove Nudge from the list and add it back. Keys are ignored for the first 0.6s a prompt is up, so you won't approve something by accident while typing.
- **Quit means quit.** The hooks won't relaunch Nudge until you open it yourself. If it crashes, it comes back on the next hook call.

## nudge-ask

![A question from Claude in Nudge's ask popover](./docs/img/ask.png)

```sh
/Applications/Nudge.app/Contents/MacOS/nudge-ask "Which deployment target?"
# → prints what you typed; exit 130 if you cancel
```

To let Claude use it, copy the skill over and pre-allow the command so Claude doesn't ask permission to ask you a question:

```sh
cp -R skills/nudge-ask ~/.claude/skills/
```

and add `Bash(/Applications/Nudge.app/Contents/MacOS/nudge-ask:*)` to `permissions.allow` in `~/.claude/settings.json`.

## Agent sessions (experimental)

```sh
nudge-claude              # start Claude Code in a tmux session here
nudge-claude attach [id]  # re-attach (latest, or a specific one)
nudge-claude list         # list sessions
nudge-claude prune [days] # clean up ended sessions (default 7 days)
```

Detach with `Ctrl-b d`. Claude keeps working, and the menu bar panel lets you pick a session, see what it's doing (thinking, using a tool, waiting, idle), read the transcript, and send replies. Replies are pasted into the tmux pane, so Claude keeps its cwd, skills, MCPs, and hooks.

![A mirrored Claude session in the menu bar panel](./docs/img/agent-sessions.png)

Nudge only mirrors sessions it started. It can't attach to a terminal tab that's already open. Set `NUDGE_TMUX_PATH` if tmux isn't somewhere Homebrew would put it. If your Claude setup reads files from `~/Documents` (a `CLAUDE.md` import, say), macOS asks once whether `nudge-claude` may access that folder; allow it, or sessions start without those files.

## Updating

```sh
nudge-update           # current vs latest
nudge-update --check   # exit 1 if an update is available
nudge-update --apply   # download, verify sha256, swap, relaunch
```

`--apply` won't install a download that doesn't match the release's published checksum.

Updating from 1.3.x or earlier: the first time the new Nudge starts, it adds its `PermissionRequest` hook to `~/.claude/settings.json`, after backing the file up. It only does this once, and only if Nudge's other hooks are already there. If you take the entry out, it stays out.

## How it works

Two hooks hand prompts to the menu bar app and wait for your answer:

- `PermissionRequest` fires when Claude Code is about to show its own permission prompt. Nudge shows it too, and whichever you answer first wins.
- `PreToolUse` fires on every tool call. Nudge only asks there if the call matches one of your patterns.

A third hook, `nudge-agent-hook`, tells Nudge when a tool call finished or Claude's turn ended, so a prompt you answered in the terminal leaves the menu bar.

If Nudge isn't running, the hooks start it. If anything fails, Claude asks in the terminal as usual.

Which modes Nudge asks in:

- Claude's own prompts come through in every mode they happen in. In auto mode that's rare: ask rules, and calls the classifier won't decide. In `dontAsk` mode Claude never asks, so Nudge doesn't either.
- Patterns ask in every mode except `bypassPermissions`.

If you allow a pattern prompt and an ask rule covers the same command, Claude asks again right after. Nudge answers that second one for you instead of showing it twice.

## Known limits

- **Unsigned.** No notarization, so the pre-built zip needs the `xattr` step, and Accessibility access has to be re-granted after each update.
- **Answering in the terminal.** Esc or No there clears Nudge's copy right away. Yes clears it when the command finishes, because Claude doesn't tell hooks it was answered. For a slow command the prompt sits in the menu bar until then, and clicking it does nothing.
- **Plan approvals and questions stay in the terminal.** Accepting a plan means choosing how Claude carries on, and a plain Allow can't say which.
- **"Always allow" is for patterns.** Claude's own prompts get Allow, Deny, and allow for this session.
- **FIFO queue, 5-minute timeout.** Stack up enough prompts and the oldest ones expire.
- **One Mac.** Patterns don't sync.

## Uninstall

```sh
make uninstall
```

This removes the app and its hooks (backing up `settings.json` first). Your patterns and prefs stay in `~/.config/nudge/`.

## License

MIT
