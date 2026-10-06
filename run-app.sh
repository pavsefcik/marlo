#!/usr/bin/env bash
#
# run-app.sh — build Marlo and launch it as a proper menu-bar .app bundle.
#
# Why this exists: `swift run MarloApp` launches the bare SwiftPM executable.
# Without an .app bundle / Info.plist, macOS refuses to hand the MenuBarExtra
# status item to MenuBarAgent, so the sparkles icon never appears. This script
# builds, wraps the binary in a minimal bundle, ad-hoc signs it, and opens it.
#
# Usage:
#   ./run-app.sh              build, bundle, launch
#   ./run-app.sh --release    build in release configuration
#   ./run-app.sh --rebuild    force a clean build first
#   ./run-app.sh --no-launch  build and bundle only
#   ./run-app.sh --install    copy the bundle to ~/Applications and launch that
#   ./run-app.sh --stop       quit any running instance
#
set -euo pipefail

cd "$(dirname "$0")"

CONFIG="debug"
BUNDLE="$PWD/.build/Marlo.app"
BINARY="$PWD/.build/$CONFIG/MarloApp"
LAUNCH=1
INSTALL=0
CLEAN=0
APP_NAME="Marlo"
BUNDLE_ID="dev.local.marlo"

# The version lives in Sources/MarloKit/Version.swift, so the CLI's --version,
# the app bundle, and the release tag all read one number.
VERSION="$(sed -n 's/.*public static let current = "\([^"]*\)".*/\1/p' \
    "$PWD/Sources/MarloKit/Version.swift")"
if [[ -z "$VERSION" ]]; then
    echo "error: could not read the version from Sources/MarloKit/Version.swift" >&2
    exit 1
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        --release)   CONFIG="release"; BINARY="$PWD/.build/$CONFIG/MarloApp"; shift ;;
        --rebuild)   CLEAN=1; shift ;;
        --no-launch) LAUNCH=0; shift ;;
        --install)   INSTALL=1; shift ;;
        --stop)      pkill -f "$APP_NAME.app/Contents/MacOS/MarloApp" 2>/dev/null || true
                     pkill -f ".build/.*/MarloApp" 2>/dev/null || true
                     echo "Stopped any running $APP_NAME instances."
                     exit 0 ;;
        -h|--help)   sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)           echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done

# --- build -------------------------------------------------------------------
[[ $CLEAN -eq 1 ]] && { echo "==> Cleaning"; swift package clean; }
echo "==> Building ($CONFIG)"
swift build -c "$CONFIG"

if [[ ! -x "$BINARY" ]]; then
    echo "error: expected binary not found at $BINARY" >&2
    exit 1
fi

# --- bundle ------------------------------------------------------------------
DEST="$BUNDLE"
if [[ $INSTALL -eq 1 ]]; then
    DEST="$HOME/Applications/$APP_NAME.app"
fi

echo "==> Bundling into $DEST"
rm -rf "$DEST"
mkdir -p "$DEST/Contents/MacOS" "$DEST/Contents/Resources"
cp "$BINARY" "$DEST/Contents/MacOS/MarloApp"

cat > "$DEST/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>MarloApp</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>27.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# --- sign (ad-hoc is enough for local development) ---------------------------
echo "==> Ad-hoc signing"
codesign --force --deep --sign - "$DEST" 2>/dev/null || \
    echo "warning: codesign failed; the app may still launch"

# --- launch ------------------------------------------------------------------
if [[ $LAUNCH -eq 1 ]]; then
    echo "==> Stopping any previous instance"
    pkill -f "$APP_NAME.app/Contents/MacOS/MarloApp" 2>/dev/null || true
    sleep 1
    echo "==> Launching $DEST"
    open "$DEST"
    sleep 2
    if pgrep -f "$APP_NAME.app/Contents/MacOS/MarloApp" >/dev/null; then
        echo "Done. Look for the sparkles (✦) icon in the right side of the menu bar."
    else
        echo "warning: app does not appear to be running. Check Console.app for MarloApp."
        exit 1
    fi
else
    echo "Done. Bundle at: $DEST"
fi
