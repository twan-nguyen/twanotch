<h1 align="center">
  <br>
  <img src="Configuration/branding/twanotch-icon.svg" alt="Twanotch" width="150">
  <br>
  Twanotch
  <br>
</h1>

<p align="center">A personal build of <a href="https://github.com/TheBoredTeam/boring.notch">boring.notch</a> that turns the MacBook notch, or the top of any display, into a hub for music, calendar, files, system HUDs and Claude usage.</p>

## Features

- Now Playing with controls and a visualizer, for any app that shows in Control Center.
- Calendar and Reminders.
- File shelf with AirDrop and quick share.
- Volume, brightness and keyboard backlight HUDs.
- Claude plan usage: what is left of your 5-hour and weekly limits, and when they reset.
- Answer Claude Code's permission requests and questions right from the notch.
- English and Vietnamese.

## Install

Requires macOS 14 Sonoma or later and [Homebrew](https://brew.sh).

```bash
brew install --cask twan-nguyen/tap/twanotch
```

If Homebrew says the tap is untrusted, run `brew trust --tap twan-nguyen/tap` and install again.

On first launch, allow Twanotch in System Settings > Privacy & Security > Accessibility so the HUDs work.

- **Update:** Check for Updates… in the menu bar icon.
- **Uninstall:** `brew uninstall --cask twanotch` (add `--zap` to also remove its settings).

## Claude usage

Needs [Claude Code](https://code.claude.com) installed and signed in. Twanotch asks Claude Code on this Mac for the same figures `/usage` shows, so it never reads your sign-in or connects to Anthropic itself. Turn it on or off in Settings > Claude.

To answer Claude Code from the notch, turn on **Answer Claude Code in the notch** in Settings > Claude. Twanotch adds its hooks to `~/.claude/settings.json` (the original file is kept as `settings.json.twanotch-backup`); restart running Claude Code sessions afterwards. Claude Code still asks as usual, and the first answer wins. With the Claude desktop app installed, Clawd in the notch also shows whether Claude is idle, working or waiting for you.

Before uninstalling Twanotch, turn this off so the hooks are removed, or delete the hooks whose URL contains `/twanotch/` from `~/.claude/settings.json`.

## Credits

Based on [boring.notch](https://github.com/TheBoredTeam/boring.notch) and released under the same [GPL-3.0 license](LICENSE). Also uses [MediaRemoteAdapter](https://github.com/ungive/mediaremote-adapter) and [NotchDrop](https://github.com/Lakr233/NotchDrop), and reads Claude usage the way [CodexBar](https://github.com/steipete/CodexBar)'s CLI source does. See [THIRD_PARTY_LICENSES](THIRD_PARTY_LICENSES).
