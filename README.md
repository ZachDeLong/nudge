# Nudge

Claude Code permission prompts, in your menu bar.

When Claude stops to ask before running something (a `git push --force`, an edit to a config file), Nudge pops a panel out of the menu bar so you can click Allow from whatever app you're in. You don't have to go find the terminal.

It's a quality-of-life tool, not a security tool. Nudge only steps in for tool calls that match patterns you've listed, and everything else goes through Claude Code's normal flow.

![Permission popover](./docs/img/permission.png)

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

Nudge only steps in for tool calls that match `~/.config/nudge/patterns.txt`. There's one rule per line, and edits apply immediately.

```
Bash(git push:*)        # prefix
Bash(*--force*)         # infix
Edit(/etc/**)           # path glob
Mcp(playwright__*)      # every tool on an MCP server
```

"Always allow" from the popover writes a matching rule into Claude Code's allow list, after backing up `settings.json`. The full syntax, chained-command handling, and importing from `permissions.ask` are in [docs/patterns.md](docs/patterns.md).

## Settings

Click the menu bar icon when there's no prompt up, or right-click it to get the same toggles as a menu.

![Settings popover](./docs/img/settings.png)

A few things the panel doesn't tell you:

- **⏎ / esc from any app** needs Accessibility access. The build is unsigned, so macOS forgets that grant after every update. Remove Nudge from the list and add it back. Keys are ignored for the first 0.6s a prompt is up, so you won't approve something by accident while typing.
- **Quit means quit.** The hooks won't relaunch Nudge until you open it yourself. If it crashes, it comes back on the next hook call.

## nudge-ask

![Ask popover](./docs/img/ask.png)

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

![Agent sessions popover](./docs/img/agent-sessions.png)

Nudge only mirrors sessions it started. It can't attach to a terminal tab that's already open. Set `NUDGE_TMUX_PATH` if tmux isn't somewhere Homebrew would put it.

## Updating

```sh
nudge-update           # current vs latest
nudge-update --check   # exit 1 if an update is available
nudge-update --apply   # download, verify sha256, swap, relaunch
```

`--apply` won't install a download that doesn't match the release's published checksum.

## How it works

A `PreToolUse` hook checks each tool call against your patterns. On a match, it hands the prompt to the menu bar app and waits for your answer. If Nudge isn't running, the hook starts it, and if anything fails, Claude asks in the terminal as usual.

## Known limits

- **Unsigned.** No notarization, so the pre-built zip needs the `xattr` step, and Accessibility access has to be re-granted after each update.
- **Opt-in patterns only.** `PreToolUse` fires before Claude decides whether a call needs permission, and the hook that fires at the right moment (`PermissionRequest`) can only observe. So Nudge can't just mirror whatever Claude would have asked about.
- **FIFO queue, 5-minute timeout.** Stack up enough prompts and the oldest ones expire.
- **One Mac.** Patterns don't sync.

## Uninstall

```sh
make uninstall
```

This removes the app and its hooks (backing up `settings.json` first). Your patterns and prefs stay in `~/.config/nudge/`.

## License

MIT
