#!/usr/bin/env bash
#
# Regenerates app/Resources/AppIcon.icns from an .appiconset.
#
#   ./scripts/make-icon.sh [path-to-AppIcon.appiconset]
#
# `iconutil` will not read an .appiconset directly — it needs an .iconset with
# its own fixed naming, where each @2x file is simply the next size up. This
# does that mapping so the source art can stay in whatever form the icon tool
# exported it.
#
set -euo pipefail
cd "$(dirname "$0")/.."

SRC="${1:-$HOME/Downloads/AppIcons/Assets.xcassets/AppIcon.appiconset}"
[[ -d "$SRC" ]] || { echo "no appiconset at $SRC" >&2; exit 1; }

ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"

# point size → source pixel size
copy() { cp "$SRC/$2.png" "$ICONSET/icon_$1.png"; }
copy 16x16       16
copy 16x16@2x    32
copy 32x32       32
copy 32x32@2x    64
copy 128x128    128
copy 128x128@2x 256
copy 256x256    256
copy 256x256@2x 512
copy 512x512    512
copy 512x512@2x 1024

mkdir -p app/Resources
iconutil -c icns "$ICONSET" -o app/Resources/AppIcon.icns
echo "✓ app/Resources/AppIcon.icns"
