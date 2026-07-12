# QuotaPanel

A macOS menu bar app that tracks your **Claude Code** and **Codex** quota and usage at a glance — official rate-limit percentages, per-session context windows, cost/token charts, offline summaries, and heatmaps. No API keys required.

<p align="center">
  <img src="docs/panel-live.png" width="340" alt="QuotaPanel — live panel">
</p>

## Features

- **One panel, provider strip on top** — switch between Claude and Codex with a click; each provider chip shows its logo, name, and a mini bar that fills to the current 5-hour session usage (0% → empty, 15% → filled to 15%). The strip scrolls horizontally as more providers are added.
- **Menu bar icon follows your selection** — the menu bar shows the logo of the provider currently open in the panel, with its usage percent and a color-coded mini bar underneath.
- **Official rate limits** — Claude's session / weekly / per-model windows come straight from Anthropic's usage endpoint, so they match what Claude Code itself reports. Codex limits come from the ChatGPT backend the codex CLI uses.
- **Context windows** — one bar per open session showing how full its context window is (tokens used / window size) with the session's project and model. Claude sessions are detected from Claude Code's live session registry; Codex from its running process.
- **Token-type breakdown** — session and context bars split into **input / cache / output** segments, so you can see what your usage is made of (cache *reads* are excluded — they re-count the same history every turn).
- **Summary view** — token totals over the last 24 h / 7 days / 30 days, with the same input/cache/output split.

  <img src="docs/panel-summary.png" width="340" alt="Summary view">

- **Heatmap view** — a GitHub-style daily grid of the last 12 weeks plus an hour-of-day punch card of the last 7 days.

  <img src="docs/panel-heatmap.png" width="340" alt="Heatmap view">

- **Cost & token charts** — estimated Claude cost (USD) and Codex token usage over the last 14 days, with today / this-month totals.
- **Configurable alerts** — add up to 6 usage thresholds (e.g. 50 / 70 / 80 / 90 / 95%); one notification per threshold per window cycle, plus a "limit reset" notification. Fractional percentages (3.1%, 5.4%) are shown wherever the data has them.
- **Sign in from the app** — optional OAuth sign-in for both providers (see below), so you never need to run `claude` or `codex` in a terminal.

  <img src="docs/settings.png" width="340" alt="Settings">

## Download & build

Requirements: **macOS 14+ (Apple Silicon)**, Xcode Command Line Tools (`xcode-select --install`).

```sh
git clone https://github.com/aokirii/quotaPanel.git
cd quotaPanel
./build.sh              # → build/QuotaPanel.app
open build/QuotaPanel.app
```

To keep it around, copy it to Applications:

```sh
cp -R build/QuotaPanel.app /Applications/
```

> `./build.sh` compiles with `swiftc` directly and also works on machines where a damaged Command Line Tools install breaks SwiftPM. On a healthy toolchain, plain `swift build` works too.

## Getting started

1. **Launch the app** — a provider icon appears in the menu bar. Click it to open the panel.
2. **First-launch permissions** (both optional but recommended):
   - **Keychain** — asked when reading the Claude Code CLI's token. Click **Always Allow** and it won't ask again.
   - **Notifications** — needed for threshold alerts.
3. **Get data flowing** — either sign in from the app (Settings → Accounts, see below), or just be logged in to the `claude` / `codex` CLIs; QuotaPanel reads their local credentials automatically.

## Options

Everything is a click away in **⚙ Settings** — no config files:

| Option | What it does |
|---|---|
| **Claude / Codex toggles** | Show or hide a provider everywhere (strip, panel, alerts). |
| **Show percent in menu bar** | Show the usage percent next to the menu bar icon, or icon + bar only. |
| **Refresh interval** | 30 s – 30 min, in 30-second steps. |
| **Alert thresholds** | Add (＋) or remove (－) up to 6 thresholds; each adjustable in 5% steps. Remove all to silence notifications. |
| **Launch at login** | One toggle — registers with macOS login items (works from the .app bundle). |
| **Accounts** | Sign in / sign out per provider (below). |

## Signing in from the app (optional)

Settings → **Accounts** lets you authenticate without ever touching a terminal:

- **Claude** — *Sign in* opens claude.ai in your browser (the official OAuth + PKCE flow used by Claude Code). Approve, copy the code the page shows, paste it into the panel, and hit *Verify*.
- **Codex** — *Sign in* opens auth.openai.com; after you approve, the app catches the `localhost:1455` callback itself (the same flow the codex CLI uses) — nothing to paste.

Tokens refresh themselves automatically when they expire, so usage keeps flowing without ever running `claude` or `codex` again. *Sign out* removes only QuotaPanel's own credentials.

## Privacy

QuotaPanel is designed to keep everything on your machine:

- **No telemetry, no analytics, no third-party servers.** The app talks only to the providers' own endpoints — `api.anthropic.com` (Claude usage), `chatgpt.com` / `auth.openai.com` (Codex usage and sign-in) — over HTTPS.
- **Credentials never leave your Mac.** In-app sign-ins are stored in `~/.quotapanel/credentials.json`, readable only by your user (`0600`), outside any repository. The OAuth sign-in callback server binds to `127.0.0.1` only.
- **CLI credentials are read-only.** The Claude Code Keychain item and `~/.codex/auth.json` are never written to — signing out of QuotaPanel never touches your CLI logins.
- **Local logs stay local.** Cost, context, summary, and heatmap data are computed by scanning `~/.claude/projects` and `~/.codex/sessions` on-device; nothing is uploaded anywhere.
- **Nothing sensitive can land in the repo.** Credentials live outside the project; `.gitignore` additionally excludes credential-shaped files as a safety net.

## Troubleshooting

- **"Token expired and refresh failed"** — the refresh token was invalidated server-side (e.g. you signed in on another machine). Sign in again from Settings → Accounts, or run the CLI once.
- **"No credentials"** — sign in from Settings, or log in to the `claude` / `codex` CLI.
- **Cost numbers differ slightly from your invoice** — they're estimates from local logs priced by `Pricing.swift`; update that one file when prices change.
- **`swift build` fails at the manifest stage** — your Command Line Tools install is damaged; use `./build.sh` (it works around it), or reinstall CLT.

## Project structure

```
Sources/QuotaPanel/
├── QuotaPanelApp.swift   # MenuBarExtra entry point
├── AppState.swift        # observable state + poll loop
├── Models/               # usage snapshots, settings, token breakdown
├── Providers/            # Claude & Codex API clients (fetch + parse + refresh)
├── Services/             # keychain reader, log scanners, OAuth, notifier, credential store
└── UI/                   # panel, provider strip, meters, charts, heatmap, settings
Resources/                # provider icons
```

## Credits

- Inspired by [CodexBar](https://github.com/steipete/CodexBar) by Peter Steinberger; provider icons are from CodexBar (MIT licensed).
- Context/summary/heatmap feature set inspired by [ai-token-tracker](https://github.com/aokirii/ai-token-tracker).
