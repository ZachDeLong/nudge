---
name: nudge-ask
description: Use whenever you need a free-form text answer from the user. Pops up a Nudge popover with a text field instead of asking inline. Triggers on any moment you'd otherwise stop and wait for the user to type a reply (clarifying questions, decision points, naming things, choosing options).
---

# nudge-ask

When you need a typed answer from the user, run:

```
/Applications/Nudge.app/Contents/MacOS/nudge-ask "<your question>"
```

The user's typed response is on stdout. Use it as their reply and continue from there.

## Rules

- Use this **instead of** asking the user inline in the terminal. Don't both ask in chat AND run nudge-ask — pick one.
- Pass the question as a single quoted argv. No newlines.
- Exit code 0 with stdout = the answer.
- Exit code 130 = the user cancelled. Treat that as "they don't want to answer right now" and proceed without the input (or stop and explain what's blocked).
- Any other non-zero exit = Nudge isn't running or another error. Fall back to asking inline.

## When NOT to use it

- For permission-style yes/no questions Claude already handles via the permission system. Nudge's hook does that separately.
- For tool calls or search queries — use the appropriate tool, not nudge-ask.
- For requests Claude can answer itself without user input.

## Installation note

The first call also needs `Bash(/Applications/Nudge.app/Contents/MacOS/nudge-ask:*)` in `~/.claude/settings.json` permissions.allow, or Claude Code will prompt before each call. Add it once and forget about it.
