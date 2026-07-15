# QuotaPanel

QuotaPanel keeps an eye on your AI coding-tool usage quotas — Claude Code, Codex, Gemini, Copilot, and 20+ other providers — from the macOS menu bar, the GNOME top bar on Linux, or the Windows system tray. It shows the rate-limit windows each provider's own service reports in a single panel, together with open-session context usage, cost estimates, and usage history. No API keys required.

<p align="center">
  <img src="docs/panel-live.png" width="340" alt="QuotaPanel">
</p>

## Requirements

- **macOS** — macOS 14 or newer (Apple Silicon) and the Xcode Command Line Tools (`xcode-select --install`). The full Xcode app is **not** required — the Command Line Tools provide both `git` and the Swift compiler `build.sh` uses.
- **Linux** — GNOME Shell 45–49. The installer takes care of everything else.
- **Windows** — Windows 10/11 with:
  - Visual Studio 2022 or the [Build Tools](https://visualstudio.microsoft.com/downloads/#build-tools-for-visual-studio-2022) with the MSVC C++ compiler (the **Desktop development with C++** workload). The Swift compiler links against MSVC, so this is required; the Swift toolchain alone is not enough. If the matching **Windows SDK** component is missing, the installer adds it for you (via a UAC prompt).
  - The [Swift toolchain](https://www.swift.org/install/windows/) (the installer can fetch it via winget).

  The tray app itself compiles with the C# compiler Windows ships in-box — no .NET SDK needed.

## Installation

### macOS

First install the Xcode Command Line Tools — they provide `git` and the Swift compiler, so the steps below can't run without them. Skip this if `xcode-select -p` already prints a path:

```sh
xcode-select --install   # click Install in the dialog, then wait for it to finish
```

Then build and install QuotaPanel:

```sh
git clone https://github.com/aokirii/quotaPanel.git
cd quotaPanel
./build.sh
cp -R build/QuotaPanel.app /Applications/
```

Launch QuotaPanel from Applications; its icon appears in the menu bar.

### Linux (GNOME)

```sh
git clone https://github.com/aokirii/quotaPanel.git
cd quotaPanel
linux/install.sh
```

When the script finishes, reload GNOME Shell once — Xorg: press `Alt`+`F2`, type `r`, press Enter; Wayland: log out and back in. The QuotaPanel icon then appears in the top bar.

### Windows

```powershell
git clone https://github.com/aokirii/quotaPanel.git
cd quotaPanel
powershell -ExecutionPolicy Bypass -File windows\install.ps1
```

The script imports the Visual Studio build environment (installing the Windows SDK component first if it's missing), builds the same portable Swift daemon the Linux port uses, compiles the tray app with the in-box C# compiler, installs both (plus the provider icons) under `%LOCALAPPDATA%\QuotaPanel`, creates Desktop and Start Menu shortcuts, and starts it.

QuotaPanel is a **system-tray app**, not a windowed one: it has no window of its own — after install its icon appears in the system tray (bottom-right, next to the clock; click the `^` arrow if Windows hides it). Click that icon to open the panel. To launch it again after quitting, **double-click the QuotaPanel shortcut on your Desktop** or find it in the Start menu. Right-click the tray icon to enable *Start with Windows* (auto-launch at login). In-app sign-in (Settings → Accounts) works with no extra setup for Gemini, Codex, and Copilot — `install.ps1` writes their public client ids to `%APPDATA%\quotapanel\oauth-clients.json`. Claude is the exception (add it yourself) and Antigravity reads its own credentials; see [OAuth client configuration](#oauth-client-configuration) below. And if you already use these tools' own CLIs, QuotaPanel reads their credentials automatically — no sign-in needed at all.

> **Status:** builds and runs on Windows 11. The Windows tray is newer than the macOS and Linux front-ends, so if you hit a rough edge please open an issue.

To update on any platform, pull the latest changes and run the same build or install command again.

## Uninstall

Each platform has an uninstall script that removes everything QuotaPanel left behind — the app/daemon/extension, its config and status files, the autostart entry, and the `~/.quotapanel` data directory (in-app sign-in credentials and `oauth-clients.json`). Every script lists what it found and asks once before deleting; pass `-y` (`-Yes` on Windows) to skip the prompt, or `--keep-credentials` (`-KeepCredentials`) to preserve `~/.quotapanel` for a later reinstall.

```sh
./uninstall.sh          # macOS
linux/uninstall.sh      # Linux (GNOME)
```

```powershell
powershell -ExecutionPolicy Bypass -File windows\uninstall.ps1   # Windows
```

The CLIs' own credentials (`~/.claude`, `~/.codex`, `~/.gemini`, …) are never touched — QuotaPanel only ever read those.

## Usage

Click the QuotaPanel icon to open the panel.

- The strip at the top lists your providers; click a chip to inspect that provider. The small bar under each chip reflects its current session usage, and the same percentage is shown next to the icon in the bar.
- **Live** shows the selected provider's rate-limit windows with reset times; for Claude Code and Codex it also shows how full each open session's context window is and a 14-day cost/token chart. **Summary** and **Heatmap** show usage history at a glance.

  <p>
    <img src="docs/panel-summary.png" width="300" alt="Summary view">
    <img src="docs/panel-heatmap.png" width="300" alt="Heatmap view">
  </p>

- **Settings** (the gear at the bottom) lets you choose which providers to show, how often to refresh, and usage thresholds that raise desktop notifications.

  <p>
    <img src="docs/settings-providers.png" width="300" alt="Settings">
  </p>

Providers are picked up automatically: sign in to a tool with its own CLI or app (for example `claude` or `codex`) and it shows data on the next refresh; anything else is listed as not signed in until you do. QuotaPanel only ever reads those credentials — it never modifies them, and nothing leaves your machine.

## OAuth client configuration

QuotaPanel reads your usage two ways:

1. **Automatically, from a CLI/editor you already use** — sign in to a tool with its own app (`claude`, `codex`, `gemini`, GitHub Copilot in your editor, …) and QuotaPanel reads those credentials on the next refresh. No configuration at all.
2. **In-app sign-in** (Settings → Accounts) — sign in through QuotaPanel itself, without the CLI.

### What needs configuring

The in-app sign-in needs an OAuth **client id** — the app-level credential that identifies "QuotaPanel acting as that CLI" to the provider (separate from *your* tokens, which land in `credentials.json` automatically when you sign in). **The app embeds none of these**; they come from `oauth-clients.json` in the per-platform config directory:

| Platform | Config directory | How the file gets there |
| --- | --- | --- |
| Windows | `%APPDATA%\quotapanel\` | `install.ps1` writes it (Gemini/Codex/Copilot) automatically |
| macOS | `~/.quotapanel/` | copy [`oauth-clients.sample.json`](oauth-clients.sample.json) and fill it in |
| Linux | `~/.config/quotapanel/` | copy [`oauth-clients.sample.json`](oauth-clients.sample.json) and fill it in |

So on Windows, Gemini/Codex/Copilot sign-in works right after `install.ps1`. On macOS/Linux you supply the file yourself (or just use path (1) — if you already sign into these tools' CLIs, QuotaPanel reads those credentials with no file at all).

Per provider:

| Provider | Fields | Value comes from |
| --- | --- | --- |
| `gemini` | `clientId` + `clientSecret` | gemini-cli's public Google OAuth client |
| `codex` | `clientId` | codex CLI's OAuth client |
| `copilot` | `clientId` | the GitHub OAuth app the Copilot plugins use |
| `claude` | `clientId` | Claude Code's OAuth client — **you must supply this** (not written by any installer) |
| `antigravity` | — | read from Antigravity's own credential file; no entry needed |

**Claude is deliberately never written for you:** Anthropic restricts Claude Code's OAuth to Claude Code / Claude.ai. To use in-app Claude sign-in, add a `claude` entry yourself — or just rely on path (1), which reads Claude Code's own credentials when it's installed.

Precedence is **environment variable → `oauth-clients.json`**, so `QUOTAPANEL_<PROVIDER>_CLIENT_ID` / `_CLIENT_SECRET` overrides the file. Changes take effect on the next *Sign in* — no restart.

> **Terms of service:** these client credentials belong to the upstream vendors, and using them in a third-party tool can be against a provider's terms (Anthropic, OpenAI and others restrict them to their own official clients) — which may put your account at risk. The safest path is (1), reusing a CLI you already sign into. Nothing is embedded in the app or shipped enabled by default.

## License

Released under the [MIT License](LICENSE). Provider icons originate from [CodexBar](https://github.com/steipete/CodexBar), also MIT licensed.

## Credits

QuotaPanel is the successor to [ai-token-tracker](https://github.com/aokirii/ai-token-tracker) and was inspired by [CodexBar](https://github.com/steipete/CodexBar).
