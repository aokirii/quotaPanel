#!/bin/bash
# Generates the extension's provider icons from ../../Resources/ProviderIcon-*.svg.
# The source SVGs are white monochrome glyphs (macOS renders them in template
# mode); GNOME St.Icon renders files as-is, so each copy is pre-tinted with the
# provider's brand color (Provider.brandColorHex values, except manus whose
# near-black #34322d would vanish on the dark shell theme).
set -euo pipefail
cd "$(dirname "$0")"

SRC=../../Resources
OUT=quotapanel@quotapanel.app/icons
mkdir -p "$OUT"

declare -A COLORS=(
    [claude]="#d97757"      [codex]="#10a37f"      [gemini]="#4285f4"
    [copilot]="#8250df"     [droid]="#cc5933"      [warp]="#938bb4"
    [amp]="#dc2626"         [augment]="#6366f1"    [kilo]="#f27027"
    [kiro]="#ff9900"        [opencode]="#3b82f6"   [opencodego]="#3b82f6"
    [antigravity]="#60ba7e" [devin]="#46b482"      [qoder]="#10b981"
    [commandcode]="#6b7380" [crossmodel]="#7c3aed" [manus]="#b5b2a8"
    [codebuff]="#44ff00"
)

for id in "${!COLORS[@]}"; do
    src="$SRC/ProviderIcon-$id.svg"
    [[ -f "$src" ]] || { echo "skip $id (no source svg)"; continue; }
    sed "s/fill=\"white\"/fill=\"${COLORS[$id]}\"/g" "$src" > "$OUT/ProviderIcon-$id.svg"
done
echo "Icons written to $OUT"
