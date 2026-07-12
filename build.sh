#!/bin/zsh
# Builds QuotaPanel directly with swiftc into a .app bundle.
#
# Why not SwiftPM: on some machines a damaged CommandLineTools install breaks
# `swift build` at the manifest stage (mismatched ManifestAPI / duplicate
# SwiftBridging modulemaps). swiftc itself is fine, so this script bypasses
# SwiftPM entirely. On a healthy toolchain plain `swift build` works too.
set -euo pipefail
cd "$(dirname "$0")"

APP=build/QuotaPanel.app
BIN="$APP/Contents/MacOS/QuotaPanel"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# CLT repair leftover: if usr/include/swift contains two modulemaps defining
# the same SwiftBridging module, map the old one to an empty file via a VFS
# overlay (no system files touched). Skips itself on a healthy install.
EXTRA_FLAGS=()
CLT_INC=/Library/Developer/CommandLineTools/usr/include/swift
if [[ -f "$CLT_INC/module.modulemap" && -f "$CLT_INC/bridging.modulemap" ]]; then
    mkdir -p build
    : > build/empty.modulemap
    cat > build/overlay.yaml <<EOF
{
  "version": 0,
  "roots": [
    {
      "name": "$CLT_INC/module.modulemap",
      "type": "file",
      "external-contents": "$PWD/build/empty.modulemap"
    }
  ]
}
EOF
    EXTRA_FLAGS=(-vfsoverlay "$PWD/build/overlay.yaml")
fi

echo "Compiling..."
swiftc -O \
    -swift-version 6 \
    -target arm64-apple-macos14.0 \
    -parse-as-library \
    "${EXTRA_FLAGS[@]}" \
    $(find Sources -name '*.swift') \
    -framework SwiftUI -framework Charts -framework ServiceManagement \
    -framework UserNotifications -framework Security -framework Network \
    -o "$BIN"

# Provider icons and other bundled assets
cp -R Resources/. "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>tr.gupi.quotapanel</string>
    <key>CFBundleName</key><string>QuotaPanel</string>
    <key>CFBundleDisplayName</key><string>QuotaPanel</string>
    <key>CFBundleExecutable</key><string>QuotaPanel</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Ad-hoc signature: required for notifications and SMAppService
xattr -cr "$APP"
codesign --force --sign - "$APP"

echo "Done: $APP"
echo "Run:  open $APP"
echo "Install:  cp -R $APP /Applications/"
