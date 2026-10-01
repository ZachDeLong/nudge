# Privacy

Nudge runs entirely on your Mac. It has no servers, no accounts and no analytics, and it never sends your prompts, commands or messages anywhere.

## What it handles

- **Hook payloads from Claude Code and Codex**: the command, file path or question an agent wants you to see, and an agent's last message when it finishes. The hooks pass these to the Nudge app over a local port that only accepts connections from your Mac itself, guarded by a random token in `~/.config/nudge/token`. The app shows them in its panel and keeps them in memory only until you answer, they're withdrawn, or the app quits.
- **Session transcripts**: when Claude finishes, Nudge's hook reads the end of that session's transcript on your disk to count the files and lines the turn changed. Nothing from it is stored or sent.

## What it stores

Only in `~/.config/nudge` on your Mac: your settings (`prefs.json`), your patterns (`patterns.txt`), the localhost port and token, and small records of agent sessions you start through Nudge (id, title, folder, tmux session name). "Always allow" writes the rule you chose into Claude Code's own `settings.json`. Removing Nudge with `brew uninstall --zap` deletes `~/.config/nudge`.

## Network

The only time Nudge goes online is when you check for or install an update (`nudge-update`, or Homebrew), which downloads release information and the app from GitHub. The Claude Code plugin makes no network calls.

## Questions

Open an issue at https://github.com/ZachDeLong/nudge/issues.
