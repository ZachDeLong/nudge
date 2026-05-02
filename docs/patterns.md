# Patterns

`~/.config/nudge/patterns.txt` controls which Claude Code tool calls Nudge prompts on. One rule per line; `#` lines are comments. The hook re-reads the file on every call, so edits take effect immediately — no restart needed.

## Syntax

### Bash

```
Bash(git push:*)        # prefix — command starts with `git push`
Bash(*--force*)         # infix — command contains `--force` anywhere
Bash(git rebase)        # exact match
```

- **Prefix** (`Bash(<prefix>:*)`) matches at token boundaries. `Bash(rm:*)` catches `rm` and `rm -rf foo`, but not `rmdir`.
- **Infix** (`Bash(*<needle>*)`) ignores case, quote characters, and backslash escapes, and inlines the bodies of `$(...)` and backticks. `Bash(*--force*)` catches `--FORCE`, `--for""ce`, `git push --for\ce`, and `git push $(echo --force)`.
- **Exact** matches the literal command.

Chained calls match too. The hook tokenizes commands on `&&`, `||`, `;`, `|`, and `&` (respecting quotes, `$(...)` substitutions, and `$((...))` arithmetic), then checks each segment. Subshell `(...)` and brace `{...;}` wrappers are peeled and re-checked. `Bash(git push:*)` fires on `cd ~/repo && git push`; `Bash(rm:*)` fires on `(rm -rf foo); ls`.

### File-based tools (Edit, Write, Read, MultiEdit, NotebookEdit)

Match against `tool_input.file_path` with shell-style globs:

```
Edit(/etc/**)               # any file under /etc
Write(**/.env*)             # any .env-prefixed file, anywhere
Edit(/Users/**/.claude/**)  # any user's Claude config tree
```

`*` matches any chars except `/`. `**` matches any chars including `/` (recursive).

### MCP tools

`Mcp(...)` matches by tool name. The `mcp__` prefix is implied — `mcp__playwright__browser_evaluate` is matched as `playwright__browser_evaluate`.

```
Mcp(*)                              # every MCP tool
Mcp(playwright__*)                  # every tool from the playwright server
Mcp(computer-use__request_access)   # one specific tool
```

The PreToolUse hook matcher includes `mcp__.*` so all MCP calls reach Nudge; the binary then filters against `patterns.txt`.

## "Always allow"

Each popover has a `⋯` button next to Allow with two options:

- **Allow for this session** — adds the exact command to an in-memory list, won't ask again until Nudge restarts.
- **Always allow this command** — promotes the matched pattern into `~/.claude/settings.json`'s `permissions.allow`. Claude auto-allows the whole class going forward; Nudge stops prompting.

### What promotes to what

| matched pattern | written to `permissions.allow` |
|---|---|
| `Bash(git push:*)` | `Bash(git push:*)` (verbatim) |
| `Edit(/etc/**)` | `Edit(/etc/**)` (verbatim) |
| `Mcp(playwright__browser_evaluate)` | `mcp__playwright__browser_evaluate` |

Patterns hidden from "Always allow":

- **Bash infix** (`Bash(*--force*)`) — deny-leaning by design. You wrote it because you want to be asked when `--force` appears; promoting it would mean "auto-allow anything with `--force`," the opposite of the intent.
- **Mcp globs** (`Mcp(*)`, `Mcp(server__*)`) — Claude Code's permissions format can't express MCP wildcards beyond whole-server allow.

When a command matches both an infix and a prefix pattern, the infix wins. So if you promote `Bash(git push:*)`, a regular `git push origin main` is then auto-allowed, but `git push --force` still triggers a prompt because the infix match takes priority.

## Importing existing rules

On install, Nudge reads your `permissions.ask` array from `~/.claude/settings.json` and imports rules for tool families it understands: Bash, Edit, Write, Read, MultiEdit, NotebookEdit, plus bare `mcp__server__tool` entries (wrapped as `Mcp(server__tool)`).

Run `make import-permissions` later to merge in new ones without overwriting your existing `patterns.txt`.

## What the matcher won't catch

Normalization handles incidental shape variation: case differences, quote characters, backslash escapes, command substitution bodies. It doesn't try to interpret bash, so things like env-var split-and-reassemble (`F=--force git push $F`), `printf '\xNN'` hex escapes, `eval`, and `base64 -d` slip through. Nudge isn't a sandbox; it's a popover. The matcher just needs to recognize the command shapes Claude Code actually emits.
