#!/usr/bin/env bash
#
# Builds the latest Mail.app and launches it.
#
#   ./scripts/run-app.sh            # debug build
#   ./scripts/run-app.sh --release  # optimised build
#
# This is `build-app.sh` plus the two things that bite in practice:
#
#   1. It kills any running instance FIRST. `build-app.sh` does `rm -rf` on the
#      bundle, and deleting a binary that is currently mapped into a live
#      process can fault it on a lazy page-in. It also stops `open` from simply
#      re-activating a stale copy instead of launching the new one.
#
#   2. It checks the backing services before launching. The app is a Zero
#      client; with zero-cache down it opens to an empty mailbox, which looks
#      like a data-loss bug rather than a service that is not running.
#
# The process is matched by its full executable PATH, never by the name "Mail".
# Matching by path rather than name is a habit worth keeping even now that
# the app is no longer called "Mail": a name match would still catch an editor
# with the binary open, or a second checkout.
#
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Alap.app"
EXEC_PATH="$APP/Contents/MacOS/Alap"

# ── 1. Stop the old instance ────────────────────────────────────────────────
if pkill -f "$EXEC_PATH" 2>/dev/null; then
  echo "▸ quitting running instance"
  # Give it a moment to release the bundle before build-app.sh removes it.
  for _ in $(seq 20); do
    pgrep -f "$EXEC_PATH" >/dev/null 2>&1 || break
    sleep 0.1
  done
fi

# ── 2. Build ────────────────────────────────────────────────────────────────
./scripts/build-app.sh "$@"

# ── 3. Warn about anything the app depends on that is not up ────────────────
#
# These are warnings, not failures: the app still launches, and being told why
# it is empty beats staring at an empty window.
warn() { printf '\033[33m!\033[0m %s\n' "$1"; }

export PATH="/opt/homebrew/opt/postgresql@18/bin:$PATH"

pg_isready -q 2>/dev/null || warn "postgres is down          → make dev"
lsof -ti:3000 >/dev/null 2>&1 || warn "sidecar (:3000) is down    → make dev"
lsof -ti:4848 >/dev/null 2>&1 || warn "zero-cache (:4848) is down → make dev"

# There is deliberately no warning about the sync engine here. The app starts it
# itself when the window appears (AlapApp.swift), so a check that runs BEFORE
# `open` is false on every cold start — and the hint it printed told you to run
# `make daemon`, which would then leave a second daemon running alongside the
# app's own.

# ── 4. Launch ───────────────────────────────────────────────────────────────
echo "▸ launching"
open "$APP"

echo
echo "  To shut down the app and every background service:  make stop"
