# Corral

<img src="assets/header.png" alt="Corral, a session manager that stays out of your way" width="100%">

A macOS app for running Claude Code, OpenCode and PI sessions. Every session is a real Ghostty
terminal in one window, and the sidebar shows which agent is working, done or waiting for input.

## Features

- **Live status** for every session: working, waiting for input, done, error. Exact with the agent
  hooks (one click in Settings › Agents), read from the terminal otherwise.
- **⌘I** jumps to the next agent waiting for input. Notifications for permission prompts and
  questions, with Allow and Deny for Claude Code.
- **Search** (⌘K) across every Claude Code, OpenCode and PI conversation, and reopen any of them.
- **Folders**, drag and drop, split panes and sessions side by side.
- **Restores your sessions** after a relaunch and resumes the agents that were running.
- Uses your Ghostty config (theme, font, keybinds) and your shell setup. Every shortcut can be changed.

## Install

Download `Corral-<version>.dmg` from [Releases](https://github.com/MartinWie/Corral/releases/latest),
open it and drag Corral onto Applications.

Needs an Apple Silicon Mac with macOS 15 or later, and Claude Code, OpenCode or PI on your shell's
PATH. Ghostty itself doesn't need to be installed.

## Updates

Corral checks for a new version once a day and asks before installing it. **Corral › Check for
Updates…** checks right away; **Settings › General** turns the daily check off. Updates come from
this repository's releases and install only when their signature matches the key built into the app.

## Privacy

No account and no analytics. The only network request Corral makes is the update check. The agent
hooks report status over a local socket and do nothing outside Corral.

## Shortcuts

| Keys | Action |
|---|---|
| ⌃⌘C / ⌃⌘O / ⌃⌘P | New Claude Code / OpenCode / PI session |
| ⌘T | New shell |
| ⌘I | Next session waiting for input |
| ⌘K | Search all sessions |
| ⌘1 … ⌘9 | Go to a session |
| ⌘D / ⇧⌘D | Split right / down |
| ⌘W / ⇧⌘T | Close / reopen session |
| ⌘/ | All shortcuts |

## Build from source

Command Line Tools are enough, no Xcode needed.

```sh
scripts/build-ghostty.sh      # once: builds libghostty (Ghostty v1.4.0) into vendor/
scripts/test.sh               # tests
scripts/bundle.sh --install   # builds dist/Corral.app and copies it to /Applications
```

Notes for working on the code are in [CLAUDE.md](CLAUDE.md).

## Credits

Terminals by [Ghostty](https://ghostty.org)'s libghostty, updates by
[Sparkle](https://sparkle-project.org). Licenses of everything Corral ships:
[THIRD_PARTY_NOTICES.txt](Resources/app/THIRD_PARTY_NOTICES.txt).
