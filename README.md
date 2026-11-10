# Corral

<img src="assets/header.png" alt="Corral, a session manager that stays out of your way" width="100%">

A macOS app for your Claude Code, OpenCode and PI sessions. Every session is a real Ghostty terminal,
and the sidebar shows which agent is working, done or waiting for input.

## Install

1. Download `Corral-<version>.dmg` from [Releases](https://github.com/MartinWie/Corral/releases/latest).
2. Open it and drag Corral onto Applications.

Needs an Apple Silicon Mac with macOS 15 or later, and Claude Code, OpenCode or PI. Corral checks for
updates once a day and asks before installing one. No account, no analytics: the update check is the
only network request it makes.

## Getting started

1. Start an agent with **⌃⌘C** (Claude Code), **⌃⌘O** (OpenCode) or **⌃⌘P** (PI), or a plain shell with **⌘T**.
2. Install the status hooks when Corral offers them (in the sidebar, or Settings › Agents). With them
   the sidebar knows exactly when an agent works or waits for you.
3. Keep several sessions going. **⌘I** takes you to the one waiting for input, and every session comes
   back after a restart.

| Keys | Action |
|---|---|
| ⌃⌘C | New Claude Code session |
| ⌘T | New shell |
| ⌘I | Next session waiting for input |
| ⌘K | Search all sessions and conversations |
| ⌘1 … ⌘9 | Go to a session |
| ⌘D | Split the terminal |
| ⌘W | Close the session |
| ⌘/ | All shortcuts (change them in Settings › Shortcuts) |

Corral uses your Ghostty config (theme, font, keybinds) and your shell setup.

## Build from source

```sh
scripts/build-ghostty.sh      # once: builds libghostty into vendor/
scripts/bundle.sh --install   # builds Corral.app and copies it to /Applications
```

Command Line Tools are enough, no Xcode needed. Notes for working on the code:
[CLAUDE.md](CLAUDE.md) and [docs/internals.md](docs/internals.md).

## Credits

Terminals by [Ghostty](https://ghostty.org)'s libghostty, updates by [Sparkle](https://sparkle-project.org).
Licenses of everything Corral ships: [THIRD_PARTY_NOTICES.txt](Resources/app/THIRD_PARTY_NOTICES.txt).
