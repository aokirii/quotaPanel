#!/bin/bash
# QuotaPanel for Linux — full uninstall (mirror of install.sh).
#
#   linux/uninstall.sh [-y] [--keep-credentials]
#
# Removes everything install.sh set up: the daemon binary, the GNOME Shell
# extension (disabled and dropped from gsettings), the daemon's config/status
# directory, and the ~/.quotapanel data directory (sign-in credentials and
# oauth-clients.json). Lists what it found and asks once before deleting;
# -y skips the prompt, --keep-credentials preserves ~/.quotapanel so a later
# reinstall picks the sign-ins back up.
#
# The CLIs' own credentials (~/.claude, ~/.codex, ~/.gemini, …) are never
# touched — QuotaPanel only ever read those. The Swift toolchain (if
# install.sh fetched one via swiftly) is left alone too: it is a general
# developer tool, not a QuotaPanel remnant. Remove it with `swiftly uninstall`
# if you no longer want it.
set -euo pipefail
cd "$(dirname "$0")"

ASSUME_YES=false
KEEP_CREDS=false
for arg in "$@"; do
    case "$arg" in
        -y|--yes) ASSUME_YES=true ;;
        --keep-credentials) KEEP_CREDS=true ;;
        -h|--help)
            sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "Unknown option: $arg (try --help)"; exit 1 ;;
    esac
done

say()  { printf '\033[1m==> %s\033[0m\n' "$*"; }
note() { printf '    %s\n' "$*"; }

UUID="quotapanel@quotapanel.app"
CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"

candidates=(
    "$HOME/.local/bin/quotapanel-daemon"
    "$DATA_HOME/gnome-shell/extensions/$UUID"
    "$CONFIG_HOME/quotapanel"
    "QuotaPanelCore/.build"
)
$KEEP_CREDS || candidates+=("$HOME/.quotapanel")

# NB: the loop variable must not be named `path` — if this ever runs under
# zsh, that is the special array tied to $PATH and assigning it clobbers
# command lookup.
found=()
for target in "${candidates[@]}"; do
    [[ -e "$target" ]] && found+=("$target")
done

if ((${#found[@]} == 0)); then
    say "Nothing to remove — no QuotaPanel remnants found."
    exit 0
fi

say "The following will be removed:"
for target in "${found[@]}"; do
    note "$target"
done
$KEEP_CREDS && note "(keeping ~/.quotapanel — credentials and oauth-clients.json)"

if ! $ASSUME_YES; then
    if [[ -t 0 ]]; then
        read -r -p "    Continue? [y/N] " answer
        [[ "${answer:-N}" =~ ^[Yy]$ ]] || { echo "Aborted — nothing deleted."; exit 1; }
    else
        # Non-interactive without -y: refuse rather than delete silently.
        echo "No terminal to confirm on — re-run with -y to delete. Nothing deleted."
        exit 1
    fi
fi

# Disable the extension and drop it from gsettings' enabled list (the reverse
# of what install.sh did), so GNOME doesn't look for the deleted directory.
say "Disabling the GNOME Shell extension"
gnome-extensions disable "$UUID" 2>/dev/null || true
if command -v gsettings >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
    python3 - <<'PY' || true
import ast, subprocess
out = subprocess.run(['gsettings', 'get', 'org.gnome.shell', 'enabled-extensions'],
                     capture_output=True, text=True).stdout.strip()
try:
    current = ast.literal_eval(out) if out and out != '@as []' else []
except (ValueError, SyntaxError):
    current = []
uuid = 'quotapanel@quotapanel.app'
if uuid in current:
    current.remove(uuid)
    subprocess.run(['gsettings', 'set', 'org.gnome.shell', 'enabled-extensions',
                    str(current)], check=True)
PY
fi

say "Stopping the daemon"
pkill -x quotapanel-daemon 2>/dev/null || true

say "Removing files"
for target in "${found[@]}"; do
    rm -rf "$target" 2>/dev/null || true
    if [[ -e "$target" ]]; then
        note "could not fully remove $target — check permissions and re-run"
    else
        note "removed $target"
    fi
done

say "Done — QuotaPanel is fully removed."
if [[ "${XDG_SESSION_TYPE:-}" == "wayland" ]]; then
    note "Log out and back in to unload the extension from the running shell."
else
    note "Press Alt+F2, type r, press Enter to unload the extension now."
fi
