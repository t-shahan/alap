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

set -a
# shellcheck disable=SC1091
source .env
set +a

mkdir -p .data

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

wait
