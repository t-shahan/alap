#!/usr/bin/env bash
#
# What the login agent executes. Not meant to be run by hand — use `make dev`
# for that, which is the same stack in the foreground.
#
# ## Why this wraps dev.sh instead of replacing it
#
# dev.sh is the single description of the local stack. Duplicating its startup
# order here would mean two files to keep in step, and the one launchd runs is
# the one nobody watches.
#
# The only thing it cannot do under launchd is start Postgres. Postgres has its
# own Homebrew login agent, launchd does not order jobs against each other, and
# dev.sh's `pg_ctl start` would race it and exit non-zero — so this waits for
# Postgres first, after which dev.sh sees it up and skips that branch.
#
set -euo pipefail
cd "$(dirname "$0")/.."

# PATH comes from the plist: launchd starts jobs with /usr/bin:/bin:/usr/sbin:/sbin,
# which has neither npm nor pg_isready.
DEADLINE=$((SECONDS + 60))
until pg_isready -q 2>/dev/null; do
  if (( SECONDS >= DEADLINE )); then
    echo "postgres did not accept connections within 60s — giving up" >&2
    exit 69
  fi
  sleep 1
done

exec ./scripts/dev.sh
