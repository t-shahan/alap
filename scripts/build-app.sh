#!/usr/bin/env bash
#
# Builds Mail.app.
#
# SwiftPM produces a bare executable, but a SwiftUI app needs a real bundle to
# get a Dock icon, a menu bar, and normal window activation. This assembles one
# by hand rather than requiring an Xcode project, so the whole build stays
# scriptable from the terminal.
#
#   ./scripts/build-app.sh [--release]
#
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="debug"
[[ "${1:-}" == "--release" ]] && CONFIG="release"

APP="build/Mail.app"
CONTENTS="$APP/Contents"

echo "▸ bundling Zero client"
npm run build --workspace=@mailapp/client --silent

# The web assets are a SwiftPM resource, so they must be in place BEFORE the
# Swift build copies them into Mail_Mail.bundle.
mkdir -p app/Sources/Mail/Web
cp packages/client/dist/index.html packages/client/dist/bridge.js app/Sources/Mail/Web/

echo "▸ compiling swift ($CONFIG)"
swift build --package-path app -c "$CONFIG"

BIN="$(swift build --package-path app -c "$CONFIG" --show-bin-path)"

echo "▸ assembling $APP"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$BIN/Mail" "$CONTENTS/MacOS/Mail"

# SwiftPM emits resources as a separate .bundle next to the binary; Bundle.module
# resolves it relative to the executable, so it has to sit alongside.
if [[ -d "$BIN/Mail_Mail.bundle" ]]; then
  cp -R "$BIN/Mail_Mail.bundle" "$CONTENTS/MacOS/"
fi

cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Mail</string>
  <key>CFBundleDisplayName</key><string>Mail</string>
  <key>CFBundleExecutable</key><string>Mail</string>
  <key>CFBundleIdentifier</key><string>dev.local.mailapp</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <!-- Regular app: Dock icon and menu bar, not a background agent. -->
  <key>LSUIElement</key><false/>
  <!--
    zero-cache is plain HTTP on loopback. ATS blocks that by default;
    NSAllowsLocalNetworking permits localhost without weakening ATS for any
    real network destination.
  -->
  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSAllowsLocalNetworking</key><true/>
  </dict>
</dict>
</plist>
PLIST

# Ad-hoc signature. Enough for local runs; Developer ID signing and
# notarisation are Phase 7.
echo "▸ signing (ad-hoc)"
codesign --force --sign - --timestamp=none "$APP" 2>/dev/null

echo "✓ $APP"
