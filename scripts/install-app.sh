#!/usr/bin/env bash
#
# Installs Alap.app so it can be opened from Finder or Spotlight like any other
# application.
#
#   ./scripts/install-app.sh
#
# ## Why this also copies .env
#
# The app is launched by Finder, so it inherits none of the shell environment,
# and the engine reads GOOGLE_CLIENT_ID and ZERO_UPSTREAM_DB from its own
# environment. From a development checkout the app finds `<repo>/.env` two
# levels above the bundle; an installed copy has no repository above it, so it
# reads ~/Library/Application Support/Alap/env instead.
#
# Re-run this after changing .env — the copy does not track the original.
#
set -euo pipefail
cd "$(dirname "$0")/.."

[[ -f .env ]] || { echo "error: no .env — run 'make setup' first" >&2; exit 69; }

# ── 1. Build ────────────────────────────────────────────────────────────────
./scripts/build-app.sh --release

# ── 2. Choose a destination ─────────────────────────────────────────────────
#
# /Applications is normally writable by the logged-in user on macOS. When it is
# not — a managed Mac, or FileVault with a restrictive setup — fall back to the
# per-user ~/Applications rather than asking for a password.
DEST="/Applications"
if [[ ! -w "$DEST" ]]; then
  DEST="$HOME/Applications"
  mkdir -p "$DEST"
  echo "! /Applications is not writable; installing to $DEST instead"
fi

TARGET="$DEST/Alap.app"

# Quit a running copy before replacing it: deleting a bundle whose binary is
# mapped into a live process can fault it on a lazy page-in.
if pgrep -f "$TARGET/Contents/MacOS/Alap" >/dev/null 2>&1; then
  echo "▸ quitting the installed copy"
  pkill -f "$TARGET/Contents/MacOS/Alap" || true
  for _ in $(seq 20); do
    pgrep -f "$TARGET/Contents/MacOS/Alap" >/dev/null 2>&1 || break
    sleep 0.1
  done
fi

echo "▸ installing to $TARGET"
rm -rf "$TARGET"
cp -R build/Alap.app "$TARGET"

# ── 3. Configuration the installed copy can reach ───────────────────────────
SUPPORT="$HOME/Library/Application Support/Alap"
mkdir -p "$SUPPORT"
cp .env "$SUPPORT/env"
# The file holds an OAuth client secret. The refresh tokens are in the Keychain,
# but there is no reason for this to be group- or world-readable.
chmod 600 "$SUPPORT/env"
echo "▸ wrote $SUPPORT/env"

echo
echo "✓ installed — open Alap from Spotlight or $DEST"
echo
echo "  it needs the sidecar and zero-cache running:"
echo "    make agent    # start them at login, no terminal"
echo "    make dev      # or run them in a terminal"
