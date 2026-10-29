<div align="center">

<img src="docs/icon.png" width="96" alt="">

# kawari

**替わり** — a menu bar switcher for Claude Code accounts

Light, open source, and zero heartburn.

macOS 14+　·　under 1 MB　·　native AppKit　·　no network

[![Release](https://img.shields.io/github/v/release/dogxii/kawari?style=flat-square&color=5856D6)](https://github.com/dogxii/kawari/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/dogxii/kawari/total?style=flat-square&color=5856D6)](https://github.com/dogxii/kawari/releases)
[![Stars](https://img.shields.io/github/stars/dogxii/kawari?style=flat-square&color=5856D6)](https://github.com/dogxii/kawari/stargazers)
[![License](https://img.shields.io/github/license/dogxii/kawari?style=flat-square&color=5856D6)](LICENSE)

[中文](README.md)

<img src="docs/sheet.png" alt="kawari panel: not connected, connected, hovering to switch, in light and dark">

</div>

## Usage

The ring in the menu bar is the current account's 5-hour usage; it turns orange past 80%. Open the panel, hover an account and click **Switch**. Right-click an account to sign in again or remove it.

## Install

Download from [Releases](https://github.com/dogxii/kawari/releases) and drag it into Applications. It isn't notarized yet: the first time, right-click it in Finder → Open.

Then click **Connect** at the top of the panel to start syncing quota.

## Command line

Turn on **Command Line Tool** in the right-click menu, then in a terminal:

```
kawari              List accounts and quotas
kawari use B        Switch by letter, number, or email prefix
kawari status       Current account and 5-hour usage, for your prompt or tmux
```

## How it works

Only official Claude Code mechanisms, no private APIs.

- **Accounts**: the primary account is `~/.claude`; every other account gets `~/.claude-accounts/<n>`. The official `CLAUDE_CONFIG_DIR` keeps sign-ins apart, and Keychain entries are per directory too. Sign-in runs `claude auth login`.
- **Shared data**: apart from `.claude.json` and credentials, everything in a secondary account's directory is a symlink into `~/.claude`. Sessions, `--resume`, settings, skills and plugins are one copy; MCP servers sync from the primary account.
- **Switching**: the selected directory is written to `~/.config/kawari/current`. A short snippet in `~/.zshrc` reads it before each command, so open terminals follow along; `launchctl setenv` covers apps opened afterwards, such as VS Code. Running sessions are left alone.
- **Quota**: Claude Code hands the official `rate_limits` to the status line. kawari keeps a copy in `~/.config/kawari/usage/` and passes the input on to your original status line unchanged. Idle accounts show as reset once their reset time passes.
- **Tokens**: the last 14 days of transcripts under `~/.claude/projects` are read incrementally, cache reads and writes included (same totals as ccusage).

**Connect Claude Code** only touches `statusLine` in `~/.claude/settings.json` and a marked block in `~/.zshrc`. Turning it off in the menu restores both.

## Build

```sh
./scripts/build.sh              # build/kawari.app (Apple Silicon)
./scripts/build.sh --universal  # also Intel
./scripts/build.sh --dmg        # also a DMG
swift test                      # accounts, integration, hook script, token ledger
./scripts/snapshot.sh           # render the panel sheet to build/snapshots/
./scripts/icon.sh               # regenerate the app icon
```

## Star History

<a href="https://star-history.com/#dogxii/kawari&Date">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=dogxii/kawari&type=Date&theme=dark">
    <img alt="Star History" src="https://api.star-history.com/svg?repos=dogxii/kawari&type=Date" width="600">
  </picture>
</a>

## License

[MIT](LICENSE)
