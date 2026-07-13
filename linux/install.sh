#!/bin/bash
# QuotaPanel for Linux — one-shot installer/updater.
#
#   linux/install.sh [-y]
#
# Does everything the README's manual steps do: checks for a Swift toolchain
# (installs one via swiftly if missing — ~1 GB download, -y skips the prompt),
# builds the daemon, installs it to ~/.local/bin, generates the provider
# icons, copies the GNOME extension into place, enables it, and writes the
# first status.json. Safe to re-run; a re-run just updates everything.
# No sudo needed — if system libraries are missing it prints the apt command.
set -euo pipefail
cd "$(dirname "$0")"

ASSUME_YES=false
[[ "${1:-}" == "-y" ]] && ASSUME_YES=true

say()  { printf '\033[1m==> %s\033[0m\n' "$*"; }
note() { printf '    %s\n' "$*"; }

have_swift() {
    command -v swift >/dev/null 2>&1 && swift --version 2>/dev/null | grep -q 'Swift version'
}

# --- 1. Swift toolchain ------------------------------------------------------

# A prior swiftly install may just not be in this shell's PATH yet.
if ! have_swift && [[ -f "$HOME/.local/share/swiftly/env.sh" ]]; then
    . "$HOME/.local/share/swiftly/env.sh"
fi

if ! have_swift; then
    if swift --version 2>/dev/null | grep -qi 'swiftclient'; then
        note "Note: /usr/bin/swift is the OpenStack client (python3-swiftclient), not the Swift language."
        note "Leaving it alone; the real toolchain will shadow it in PATH."
    fi
    say "Swift toolchain not found — installing via swiftly (~1 GB download)"
    if ! $ASSUME_YES && [[ -t 0 ]]; then
        read -r -p "    Continue? [Y/n] " answer
        [[ "${answer:-Y}" =~ ^[Yy]?$ ]] || { echo "Aborted."; exit 1; }
    fi
    tmp="$(mktemp -d)"
    curl -fL -o "$tmp/swiftly.tar.gz" \
        "https://download.swift.org/swiftly/linux/swiftly-$(uname -m).tar.gz"
    tar -zxf "$tmp/swiftly.tar.gz" -C "$tmp"
    "$tmp/swiftly" init --assume-yes --quiet-shell-followup
    rm -rf "$tmp"
    . "$HOME/.local/share/swiftly/env.sh"
fi
say "Using $(swift --version 2>/dev/null | head -1)"

# System libraries Swift wants: warn, don't sudo (the build usually works
# with the runtime libs a desktop already has).
missing=()
for p in binutils gnupg2 libc6-dev libcurl4-openssl-dev libedit2 libgcc-13-dev \
         libpython3-dev libsqlite3-0 libstdc++-13-dev libncurses-dev \
         libxml2-dev libz3-dev pkg-config tzdata unzip zlib1g-dev; do
    dpkg -s "$p" &>/dev/null || missing+=("$p")
done
if ((${#missing[@]})); then
    note "If the build fails, install the missing Swift dependencies first:"
    note "  sudo apt-get install -y ${missing[*]}"
fi

# --- 2. Daemon ---------------------------------------------------------------

say "Building quotapanel-daemon (release)"
(cd QuotaPanelCore && swift build -c release)
install -Dm755 QuotaPanelCore/.build/release/quotapanel-daemon \
    "$HOME/.local/bin/quotapanel-daemon"
note "Installed to ~/.local/bin/quotapanel-daemon"

# --- 3. Extension ------------------------------------------------------------

say "Installing the GNOME Shell extension"
./gnome-extension/make-icons.sh >/dev/null
EXT_DIR="$HOME/.local/share/gnome-shell/extensions"
mkdir -p "$EXT_DIR"
rm -rf "$EXT_DIR/quotapanel@quotapanel.app"
cp -r gnome-extension/quotapanel@quotapanel.app "$EXT_DIR/"
note "Copied to $EXT_DIR/quotapanel@quotapanel.app"

# Enable now if GNOME already knows the extension; otherwise pre-enable it in
# gsettings so it comes up enabled right after the shell reload.
if ! gnome-extensions enable quotapanel@quotapanel.app 2>/dev/null; then
    python3 - <<'PY'
import ast, subprocess
out = subprocess.run(['gsettings', 'get', 'org.gnome.shell', 'enabled-extensions'],
                     capture_output=True, text=True).stdout.strip()
try:
    current = ast.literal_eval(out) if out and out != '@as []' else []
except (ValueError, SyntaxError):
    current = []
uuid = 'quotapanel@quotapanel.app'
if uuid not in current:
    current.append(uuid)
    subprocess.run(['gsettings', 'set', 'org.gnome.shell', 'enabled-extensions',
                    str(current)], check=True)
PY
fi

# --- 4. First data + next step -----------------------------------------------

say "Writing the first status.json"
"$HOME/.local/bin/quotapanel-daemon" --once || true

say "Done — one manual step left to load the extension:"
if [[ "${XDG_SESSION_TYPE:-}" == "wayland" ]]; then
    note "Log out and back in (Wayland reload)."
else
    note "Press Alt+F2, type r, press Enter (Xorg reload)."
fi
note "The gauge icon then appears in the top bar."
