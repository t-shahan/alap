#!/usr/bin/env bash
#
# Boots the full local-sidecar stack in dependency order.
#
# In the local-sidecar topology every tier runs on this machine, which is what
# makes Zero's "no offline writes" restriction a non-issue: the client's
# WebSocket to zero-cache never leaves the loopback interface, so the client is
# effectively never in the `disconnected` state.
#
# Startup order matters:
#   1. Postgres      — everything else connects to it
#   2. sidecar       — must be up BEFORE zero-cache, because zero-cache calls
#                      out to /api/query and /api/mutate
#   3. zero-cache    — opens the logical replication slot and builds its
#                      SQLite replica
#
set -euo pipefail
cd "$(dirname "$0")/.."

# Homebrew's postgresql@18 is keg-only, so its binaries are not on the default
# PATH. LC_ALL is mandatory: Postgres 18 on macOS aborts at startup with
# "postmaster became multithreaded during startup" if the locale is unset.
export PATH="/opt/homebrew/opt/postgresql@18/bin:$PATH"
export LC_ALL="en_US.UTF-8"
export LANG="en_US.UTF-8"

PGDATA="/opt/homebrew/var/postgresql@18"

# ── Refuse to start a second copy of the stack ──────────────────────────────
#
# The login agent runs this same script, so with it installed the ports are
# already taken and starting again produces two failures that read as bugs: the
# sidecar throws EADDRINUSE on :3000, and zero-cache gets far enough to check
# schemas and open a replication slot before dying on :4849 — a port neither
# this script nor the README ever mentions, because zero-cache picks it itself.
#
# Bail before any of that, and say which thing is already holding them.
BUSY=()
for port in 3000 4848; do
  lsof -ti:"$port" >/dev/null 2>&1 && BUSY+=("$port")
done

if (( ${#BUSY[@]} > 0 )); then
  # The login agent holding them is not a failure: the stack this target exists
  # to start is already up, so what was asked for is already true. Exit 0 and
  # point at the thing actually worth running, rather than making a no-op look
  # like a broken build.
  if launchctl print "gui/$UID/app.alap.services" >/dev/null 2>&1; then
    echo "✓ the stack is already running — the login agent started it at login"
    echo
    echo "  Nothing to start. To launch the app:"
    echo
    echo "      make app"
    echo
    echo "  make agent-status      what is currently up"
    echo "  make stop              shut all of it down"
    echo "  make agent-uninstall   stop the agent and run in a terminal instead"
    exit 0
  fi

  # Anything else on those ports IS a conflict, and guessing would be worse than
  # saying so.
  echo "error: ports already in use: ${BUSY[*]}" >&2
  echo "  the login agent is not running, so something else is holding them:" >&2
  echo "    lsof -ti:${BUSY[0]} | xargs ps -o pid=,command= -p" >&2
  exit 69
fi

set -a
# shellcheck disable=SC1091
source .env
set +a

mkdir -p .data

# `npm run --workspace` executes with the cwd set to packages/sidecar, so the
# relative ZERO_REPLICA_FILE in .env would resolve there instead of here — and
# zero-cache exits with "Cannot open ZERO_REPLICA_FILE" rather than silently
# building a second replica. Resolve it to an absolute path while we still know
# where "here" is.
case "$ZERO_REPLICA_FILE" in
  /*) ;;
  *) ZERO_REPLICA_FILE="$PWD/${ZERO_REPLICA_FILE#./}" ;;
esac
export ZERO_REPLICA_FILE

if ! pg_isready -q; then
  echo "▸ starting postgres"
  pg_ctl -D "$PGDATA" -l .data/postgres.log start
  until pg_isready -q; do sleep 0.3; done
fi
echo "✓ postgres        $(psql -tAd mailapp -c 'SHOW wal_level;')"

cleanup() { echo; echo "▸ stopping services"; kill 0 2>/dev/null || true; }
trap cleanup EXIT INT TERM

echo "▸ starting sidecar (:3000)"
npm run dev --workspace=@mailapp/sidecar &

# zero-cache probes the query/mutate endpoints on connect; give the sidecar a
# moment so the first sync doesn't fail and back off.
sleep 2

echo "▸ starting zero-cache (:4848)"
npm run zero:cache --workspace=@mailapp/sidecar &

# Printed after the services rather than before, so it survives their startup
# chatter and is the last thing on screen while this sits in `wait`.
echo
echo "  Ctrl-C stops these. To shut down everything, including the app and the"
echo "  sync engine:  make stop"
echo

wait
