#!/bin/zsh
# QuotaPanel for macOS — full uninstall.
#
#   ./uninstall.sh [-y] [--keep-credentials]
#
# Removes everything QuotaPanel leaves on this Mac: the app bundle, its
# UserDefaults, the ~/.quotapanel data directory (sign-in credentials and
# oauth-clients.json), the pre-rename ~/.kotabar leftovers, and the repo's
# build artifacts. Lists what it found and asks once before deleting;
# -y skips the prompt, --keep-credentials preserves ~/.quotapanel so a
# later reinstall picks the sign-ins back up.
#
# The CLIs' own credentials (~/.claude, ~/.codex, ~/.gemini, …) are never
# touched — QuotaPanel only ever read those.
set -euo pipefail
cd "$(dirname "$0")"

ASSUME_YES=false
KEEP_CREDS=false
for arg in "$@"; do
    case "$arg" in
        -y|--yes) ASSUME_YES=true ;;
        --keep-credentials) KEEP_CREDS=true ;;
        -h|--help)
            sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "Unknown option: $arg (try --help)"; exit 1 ;;
    esac
done

say()  { printf '\033[1m==> %s\033[0m\n' "$*"; }
note() { printf '    %s\n' "$*"; }

BUNDLE_ID="tr.gupi.quotapanel"

# Everything QuotaPanel may have left behind, in delete order.
typeset -a candidates
candidates=(
    "/Applications/QuotaPanel.app"
    "$HOME/Library/Preferences/$BUNDLE_ID.plist"
    "$HOME/.kotabar"
    "build"
    ".build"
    "linux/QuotaPanelCore/.build"
)
$KEEP_CREDS || candidates+=("$HOME/.quotapanel")

typeset -a found
found=()
# NB: the loop variable must not be named `path` — in zsh that is the
# special array tied to $PATH, and assigning it clobbers command lookup.
for target in "${candidates[@]}"; do
    [[ -e "$target" ]] && found+=("$target")
done

if (( ${#found[@]} == 0 )); then
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
        read -r "answer?    Continue? [y/N] "
        [[ "$answer" =~ ^[Yy]$ ]] || { echo "Aborted — nothing deleted."; exit 1; }
    else
        # Non-interactive without -y: refuse rather than delete silently.
        echo "No terminal to confirm on — re-run with -y to delete. Nothing deleted."
        exit 1
    fi
fi

# Quit the running app first (graceful quit, then a hard kill as fallback)
# so the bundle isn't held open while we delete it.
say "Stopping QuotaPanel"
osascript -e 'quit app "QuotaPanel"' >/dev/null 2>&1 || true
/bin/sleep 1 2>/dev/null || true
pkill -x QuotaPanel 2>/dev/null || true

say "Removing files"
for target in "${found[@]}"; do
    rm -rf "$target" 2>/dev/null || true
    if [[ -e "$target" ]]; then
        note "could not fully remove $target — check permissions and re-run"
    else
        note "removed $target"
    fi
done

# Flush the cfprefsd cache so the deleted plist doesn't linger in memory.
defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true

say "Done — QuotaPanel is fully removed."
note "If a stale 'QuotaPanel' entry remains under System Settings → General →"
note "Login Items, remove it there (macOS keeps the list, not the app)."
