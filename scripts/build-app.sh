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

APP="build/Alap.app"
CONTENTS="$APP/Contents"

echo "▸ bundling Zero client"
npm run build --workspace=@mailapp/client --silent

# The web assets are a SwiftPM resource, so they must be in place BEFORE the
# Swift build copies them into Alap_Alap.bundle.
mkdir -p app/Sources/Mail/Web
cp packages/client/dist/index.html packages/client/dist/bridge.js app/Sources/Mail/Web/

echo "▸ compiling swift ($CONFIG)"
swift build --package-path app -c "$CONFIG"

BIN="$(swift build --package-path app -c "$CONFIG" --show-bin-path)"

echo "▸ assembling $APP"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$BIN/Alap" "$CONTENTS/MacOS/Alap"

# SwiftPM emits resources as a separate .bundle next to the binary; Bundle.module
# resolves it relative to the executable, so it has to sit alongside.
#
# SwiftPM's version is a FLAT directory that merely ends in `.bundle` — no
# Info.plist, no Contents/. codesign keys off the extension, tries to seal it as
# a real bundle, and fails with "bundle format unrecognized, invalid, or
# unsuitable", which takes the whole build down with it. So reshape it into a
# genuine bundle on the way in. `Bundle.module.resourceURL` then resolves to
# Contents/Resources, which is where the payload now lives, so the lookup in
# ZeroBridge.swift keeps working unchanged.
RESOURCE_BUNDLE="$CONTENTS/MacOS/Alap_Alap.bundle"
if [[ -d "$BIN/Alap_Alap.bundle" ]]; then
  mkdir -p "$RESOURCE_BUNDLE/Contents/Resources"
  cp -R "$BIN/Alap_Alap.bundle/." "$RESOURCE_BUNDLE/Contents/Resources/"
  # Guard against copying a previously-reshaped bundle into itself.
  rm -rf "$RESOURCE_BUNDLE/Contents/Resources/Contents"

  cat > "$RESOURCE_BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Alap_Alap</string>
  <key>CFBundleIdentifier</key><string>app.alap.mail.resources</string>
  <key>CFBundlePackageType</key><string>BNDL</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
</dict>
</plist>
PLIST
fi

# The app icon. Regenerate with scripts/make-icon.sh if the source art changes.
if [[ -f app/Resources/AppIcon.icns ]]; then
  cp app/Resources/AppIcon.icns "$CONTENTS/Resources/AppIcon.icns"
fi

# The engine ships INSIDE the bundle. The app spawns `mailengined connect` to
# add a mailbox, because OAuth, the Keychain and every network call belong to
# the engine — duplicating them in the app would also mean putting Google
# credentials somewhere anyone can crack open with unzip.
if [[ -x engine/build/mailengined ]]; then
  echo "▸ embedding engine"
  mkdir -p "$CONTENTS/Helpers"
  cp engine/build/mailengined "$CONTENTS/Helpers/mailengined"
else
  echo "  (engine not built; the app will fall back to a development path)"
fi

cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Alap</string>
  <key>CFBundleDisplayName</key><string>Alap</string>
  <key>CFBundleExecutable</key><string>Alap</string>
  <key>CFBundleIdentifier</key><string>app.alap.mail</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <!-- Named without the extension; Launch Services appends .icns itself. -->
  <key>CFBundleIconFile</key><string>AppIcon</string>
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

# Signed with the local development identity when one exists, ad-hoc otherwise.
# Developer ID signing and notarisation remain Phase 7; this only stops macOS
# treating every rebuild as a different application.
#
# Nested bundles are signed first: codesign seals the outer bundle over the
# hashes of what it contains, so signing outside-in would immediately invalidate
# the result.
#
# stderr is deliberately NOT silenced. It used to be, and a failure here left a
# STALE signature on the bundle from an earlier build — so `codesign -dv`
# happily reported a valid ad-hoc signature while this script was exiting 1 and
# taking `&& open` down with it.
echo "▸ signing"
# The embedded engine is nested CODE, not a resource, so it must carry its own
# signature before the outer seal is computed over it.
./scripts/sign.sh "$CONTENTS/Helpers/mailengined" "$RESOURCE_BUNDLE" "$APP"
codesign --verify --deep --strict "$APP"

echo "✓ $APP"
