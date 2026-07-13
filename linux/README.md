# QuotaPanel for Linux (GNOME)

A Linux port of [QuotaPanel](../README.md) — the macOS menu-bar app that tracks
AI coding-tool usage quotas. On Linux the same idea is split in two:

- **`quotapanel-daemon`** — a portable Swift program that fetches your quotas
  from each provider and writes them to `~/.config/quotapanel/status.json`.
- **A GNOME Shell extension** — a top-bar button that reads that JSON and shows a
  per-provider usage panel. Click the button to open it, click again to close
  (native GNOME behavior).

The daemon does all the network and credential work; the extension only renders.
They talk through one small, versioned file (`status.json`), so you can run the
daemon on its own (cron, systemd, a terminal) even without the extension.

```
┌────────────────────┐        writes         ┌──────────────────────┐
│  quotapanel-daemon │ ───────────────────▶  │ ~/.config/quotapanel │
│  (Swift, fetches)  │     status.json       │      /status.json    │
└────────────────────┘                       └──────────┬───────────┘
                                                         │ reads
                                              ┌──────────▼───────────┐
                                              │  GNOME Shell ext.    │
                                              │  (top-bar panel)     │
                                              └──────────────────────┘
```

> The macOS app under the repo root is untouched by anything in this `linux/`
> folder. This is a parallel port that shares the provider logic, not the UI.

## Supported providers

19 providers work on Linux today:

Claude Code, Codex, Gemini, Copilot, Droid, Warp, Amp, Augment, Kilo, Kiro,
OpenCode, OpenCode Go, Antigravity, Devin, Qoder, Command Code, CrossModel,
Manus, Codebuff.

Four macOS-only providers (Cursor, Windsurf, JetBrains AI, Zed) are not ported
yet — they rely on `~/Library` paths / Keychain and are skipped by the daemon.

## Requirements

- A Swift toolchain (5.9+) to build the daemon. Install from
  [swift.org/download](https://www.swift.org/download/) or your distro's package
  manager. `sqlite3` is used by a couple of providers and is usually present.
- GNOME Shell **45–49** for the extension (it uses ESM / GNOME 45+ APIs).

## Build the daemon

```sh
cd linux/QuotaPanelCore
swift build -c release
```

The binary lands at `.build/release/quotapanel-daemon`. Put it on your `PATH`
(the extension looks for it on `PATH`, then in `~/.local/bin`):

```sh
install -Dm755 .build/release/quotapanel-daemon ~/.local/bin/quotapanel-daemon
```

Run it once to write the first `status.json`:

```sh
quotapanel-daemon --once --stdout
```

### Daemon usage

```
quotapanel-daemon [--once | --interval SECONDS]
                  [--providers a,b,c] [--out PATH] [--stdout]
```

- `--once` — fetch once, write `status.json`, exit (the default).
- `--interval 300` — keep running, refreshing every 300 seconds.
- `--providers claude,codex` — restrict to a subset.
- `--out PATH` — write somewhere other than `~/.config/quotapanel/status.json`.
- `--stdout` — also print the JSON (handy for debugging).

## Install the GNOME Shell extension

Copy the extension into your local extensions directory (the folder name must
match the UUID):

```sh
mkdir -p ~/.local/share/gnome-shell/extensions
cp -r linux/gnome-extension/quotapanel@quotapanel.app \
      ~/.local/share/gnome-shell/extensions/
```

Then reload GNOME Shell and enable it:

- **Xorg:** press `Alt`+`F2`, type `r`, press Enter.
- **Wayland:** log out and back in.

```sh
gnome-extensions enable quotapanel@quotapanel.app
```

A small gauge icon appears in the top bar with the fullest quota as a percentage.
Click it to open the panel; use **Refresh** to run the daemon on demand.

## Keep it up to date automatically (systemd timer)

The extension refreshes when it sees `status.json` change and polls every ~30s,
but it only *reads* the file. To refresh the data itself in the background, run
the daemon on a timer. User units (no root needed):

`~/.config/systemd/user/quotapanel.service`

```ini
[Unit]
Description=Refresh QuotaPanel status.json

[Service]
Type=oneshot
ExecStart=%h/.local/bin/quotapanel-daemon --once
# Providers that read API keys/cookies from the environment (see below):
# EnvironmentFile=%h/.config/quotapanel/env
```

`~/.config/systemd/user/quotapanel.timer`

```ini
[Unit]
Description=Refresh QuotaPanel every 5 minutes

[Timer]
OnBootSec=1min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
```

```sh
systemctl --user daemon-reload
systemctl --user enable --now quotapanel.timer
```

## Provider credentials

Most CLI-based providers are picked up automatically once you've signed in with
their own tool — the daemon reads (never writes) the credential files those
tools already create:

| Provider     | Source the daemon reads                                            |
|--------------|-------------------------------------------------------------------|
| Claude Code  | `~/.claude/.credentials.json` (sign in with the Claude CLI)       |
| Codex        | `~/.codex/auth.json`                                               |
| Gemini       | `~/.gemini/oauth_creds.json`                                       |
| Copilot      | `~/.config/github-copilot/apps.json` / `hosts.json`               |
| Droid        | `FACTORY_API_KEY`, or `~/.factory/.env`                            |
| Amp          | `AMP_API_KEY`, or the `amp` CLI                                    |
| Augment      | the `auggie` CLI                                                   |
| Kilo         | `KILO_API_KEY`, or `~/.local/share/kilo/auth.json`                 |
| Kiro         | the `kiro-cli` CLI                                                 |
| OpenCode Go  | `~/.local/share/opencode/auth.json`                               |
| Antigravity  | `ANTIGRAVITY_OAUTH_CREDENTIALS_JSON`, or its `oauth_creds.json`   |
| Codebuff     | `CODEBUFF_API_KEY`, or `~/.config/manicode/credentials.json`      |

Providers that need an API key, token, or a pasted browser cookie take it from
an environment variable (QuotaPanel never decrypts your browser's cookie store):

| Provider     | Environment variable(s)                                            |
|--------------|-------------------------------------------------------------------|
| Warp         | `WARP_API_KEY` or `WARP_TOKEN`                                     |
| Devin        | `DEVIN_BEARER_TOKEN` or `DEVIN_AUTHORIZATION`                      |
| CrossModel   | `CROSSMODEL_API_KEY`                                               |
| Manus        | `MANUS_SESSION_TOKEN` / `MANUS_SESSION_ID` / `MANUS_COOKIE`        |
| OpenCode     | `OPENCODE_COOKIE`                                                  |
| Qoder        | `QODER_COOKIE`                                                     |
| Command Code | `COMMANDCODE_COOKIE`                                               |

Put these in `~/.config/quotapanel/env` (`KEY=value` per line) and point the
systemd service's `EnvironmentFile` at it, as shown above. A provider with no
credentials simply shows as **not signed in** and is grouped in a footer line;
it never blocks the others.

> The **Refresh** button spawns the daemon as a child of GNOME Shell, so it only
> sees variables in the Shell's own environment. For env-var providers, prefer
> the systemd timer (with `EnvironmentFile`) over the Refresh button.

## Files

```
linux/
├── QuotaPanelCore/                     Swift package (library + daemon)
│   ├── Package.swift
│   └── Sources/
│       ├── QuotaPanelCore/             portable core: models, providers, engine
│       └── quotapanel-daemon/          CLI entry point
├── gnome-extension/
│   └── quotapanel@quotapanel.app/      the GNOME Shell extension
│       ├── metadata.json
│       ├── extension.js
│       └── stylesheet.css
├── status.sample.json                  example of what the daemon writes
└── README.md
```

## Troubleshooting

- **Panel says "No status yet"** — the daemon hasn't written the file. Run
  `quotapanel-daemon --once --stdout` and check for errors.
- **Extension not listed** — the folder name must be exactly
  `quotapanel@quotapanel.app` and live directly under
  `~/.local/share/gnome-shell/extensions/`. Check logs with
  `journalctl -f -o cat /usr/bin/gnome-shell`.
- **Refresh does nothing** — the daemon isn't on `PATH` or in `~/.local/bin`.
  The Refresh item is disabled when the binary can't be found.
- **A provider shows "not signed in"** — sign in with that tool's own CLI, or
  set its environment variable (see the tables above), then Refresh.

## Roadmap

This is the MVP. Planned next:

1. **Phase 2** — desktop notifications on threshold crossings; a preferences UI
   (GSettings) for refresh interval and which providers to show.
2. **Phase 3 (full parity)** — summary/history views and the four remaining
   providers (Cursor, Windsurf, JetBrains AI, Zed).
