#!/usr/bin/env bash
#
# Stops everything Alap runs in the background.
#
#   ./scripts/stop.sh          # or: make stop
#
# ## Order matters
#
# The app respawns its sync engine when it notices it has gone, and launchd
# respawns the services because the agent sets KeepAlive. So each layer is shut
# down from the top: the app first, then the engine it supervises, then the
# agent, and only then anything left holding a port.
#
# Killing processes without booting the agent out just hands them back to
# launchd ten seconds later, which looks like the stop command doing nothing.
#
# Postgres is deliberately left running. Homebrew owns its login agent, other
# things on the machine may be using it, and it is not Alap's to stop.
#
set -euo pipefail
cd "$(dirname "$0")/.."

LABEL="app.alap.services"

ok()   { printf '  ✓ %s\n' "$1"; }
skip() { printf '  \033[2m= %s\033[0m\n' "$1"; }

# Waits for a pattern to stop matching, so the next layer down is not killed
# while something above it is still able to restart it.
settle() {
  for _ in $(seq 30); do
    pgrep -f "$1" >/dev/null 2>&1 || return 0
    sleep 0.1
  done
  return 1
}

# ── 1. The app ──────────────────────────────────────────────────────────────
if pgrep -f "Alap.app/Contents/MacOS/Alap" >/dev/null 2>&1; then
  # TERM rather than KILL: the app stops its sync daemon on the way out, so a
  # graceful quit does half of step 2 by itself.
  pkill -TERM -f "Alap.app/Contents/MacOS/Alap" 2>/dev/null || true
  settle "Alap.app/Contents/MacOS/Alap" || pkill -KILL -f "Alap.app/Contents/MacOS/Alap" 2>/dev/null || true
  ok "quit Alap"
else
  skip "Alap not running"
fi

# ── 2. The sync engine ──────────────────────────────────────────────────────
if pgrep -f "mailengined daemon" >/dev/null 2>&1; then
  pkill -TERM -f "mailengined daemon" 2>/dev/null || true
  settle "mailengined daemon" || pkill -KILL -f "mailengined daemon" 2>/dev/null || true
  ok "stopped the sync engine"
else
  skip "sync engine not running"
fi

# ── 3. The login agent ──────────────────────────────────────────────────────
#
# bootout stops the job and its children now. The plist stays installed, so the
# services come back at the next login — which is the behaviour "stop" should
# have. `make agent-uninstall` is the one that makes it permanent.
if launchctl print "gui/$UID/$LABEL" >/dev/null 2>&1; then
  launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
  ok "stopped the login agent (returns at next login)"
else
  skip "login agent not loaded"
fi

# ── 4. Anything still holding a port ────────────────────────────────────────
#
# A foreground `make dev` traps its own exit and cleans up, so this only catches
# the case where that terminal was killed rather than interrupted.
for port in 3000 4848 4849; do
  pids="$(lsof -ti:"$port" 2>/dev/null || true)"
  [[ -z "$pids" ]] && continue
  # shellcheck disable=SC2086
  kill -TERM $pids 2>/dev/null || true
  sleep 0.5
  pids="$(lsof -ti:"$port" 2>/dev/null || true)"
  # shellcheck disable=SC2086
  [[ -n "$pids" ]] && kill -KILL $pids 2>/dev/null || true
  ok "freed port $port"
done

echo
echo "  Postgres is still running — it is Homebrew's, and other things may use it."
echo "  To stop it too:  brew services stop postgresql@18"
echo
echo "  To start again:  make agent    (background)   or   make dev   (terminal)"
