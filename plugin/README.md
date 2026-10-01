# Nudge for Claude Code

Answer Claude Code from whatever app you're in. When Claude needs your approval, asks you a question, or finishes a turn, Nudge shows it in a small panel under your Mac's menu bar. Allow or deny, pick an answer, or type a reply, without switching back to the terminal.

This plugin adds Nudge's hooks to Claude Code. It needs the free Nudge menu bar app (macOS 14+):

```sh
brew install --cask zachdelong/tap/nudge-app
```

Then, in Claude Code:

```
/plugin marketplace add ZachDeLong/nudge
/plugin install nudge@nudge
```

Without the app, the hooks do nothing and Claude Code asks in the terminal as usual. If you already connected Nudge with `nudge-setup`, the plugin stays out of the way so nothing shows twice. Codex support comes from `nudge-setup`, not this plugin.

Everything runs on your Mac: the hooks talk to the Nudge app over a local port, and nothing is sent anywhere else. See the [privacy policy](https://github.com/ZachDeLong/nudge/blob/main/PRIVACY.md).

Source, settings and docs: https://github.com/ZachDeLong/nudge
