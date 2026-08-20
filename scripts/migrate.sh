#!/usr/bin/env bash
#
# Applies pending SQL migrations to the mail database.
#
#   ./scripts/migrate.sh
#
# ## Why this exists
#
# The migrations in packages/sidecar/migrations were applied by hand, and the
# README never mentioned them at all — so a fresh checkout produced an empty
# database, zero-cache replicated nothing, and the app opened to a mailbox that
# looked broken rather than unconfigured.
#
# ## Why it tracks state instead of re-running everything
#
# 0001 and 0003 are NOT idempotent: 0001 has no IF NOT EXISTS, and 0003 rewrites
# attachment primary keys. Replaying either against a populated database is
# destructive, so applied files are recorded in `schema_migration` and never run
# twice.
#
# ## Baselining
#
# A database that predates this script has the schema but no ledger table.
# Replaying 0001 there would fail on existing objects, so the first run against
# an ALREADY-POPULATED database records every migration as applied without
# executing any of it. The tell is the `message` table: present means some human
# already ran these by hand.
#
# ## Why the ledger is not in `public`
#
# Zero's publication is FOR TABLES IN SCHEMA public, so ANY table created there
# is replicated automatically and cannot be dropped from the publication
# individually. A ledger in `public` would land in zero-cache's SQLite replica
# and bump the replicated schema for a table no client ever queries. Its own
# schema keeps it invisible to replication.
#
set -euo pipefail
cd "$(dirname "$0")/.."

# Homebrew's postgresql@18 is keg-only, so psql is not on the default PATH.
# `brew --prefix` rather than a hardcoded /opt/homebrew: Intel Macs use
# /usr/local, and this script has to run on a machine that is not the author's.
if command -v brew >/dev/null 2>&1; then
  export PATH="$(brew --prefix)/opt/postgresql@18/bin:$PATH"
fi

# Postgres 18 on macOS aborts at startup with "postmaster became multithreaded
# during startup" if the locale is unset. Harmless for a client, set anyway so
# this file can be sourced or copied without carrying a latent trap.
export LC_ALL="${LC_ALL:-en_US.UTF-8}"

DB="${ZERO_UPSTREAM_DB:-mailapp}"
MIGRATIONS="packages/sidecar/migrations"
LEDGER="alap_meta.schema_migration"

psql_q() { psql -tAX -d "$DB" -c "$1"; }

command -v psql >/dev/null 2>&1 || {
  echo "error: psql not found — run 'make setup' first" >&2
  exit 69
}

psql_q "SELECT 1" >/dev/null 2>&1 || {
  echo "error: cannot connect to database '$DB'" >&2
  echo "  is postgres running? try: make setup" >&2
  exit 69
}

# ── 1. Ensure the ledger exists, baselining if the schema predates it ────────
had_ledger="$(psql_q "SELECT to_regclass('$LEDGER') IS NOT NULL")"

# client_min_messages: Zero installs an event trigger that NOTICEs on every DDL
# statement, and "already exists, skipping" fires on each idempotent re-run. Both
# are noise that makes a clean run look like it did something.
psql -qX -d "$DB" <<SQL
SET client_min_messages = warning;
CREATE SCHEMA IF NOT EXISTS alap_meta;
CREATE TABLE IF NOT EXISTS $LEDGER (
  filename   TEXT PRIMARY KEY,
  applied_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
SQL

if [[ "$had_ledger" != "t" ]]; then
  has_schema="$(psql_q "SELECT to_regclass('public.message') IS NOT NULL")"
  if [[ "$has_schema" == "t" ]]; then
    echo "▸ existing schema found — baselining without replaying"
    for file in "$MIGRATIONS"/*.sql; do
      psql -qX -d "$DB" -c \
        "INSERT INTO $LEDGER (filename) VALUES ('$(basename "$file")')
           ON CONFLICT DO NOTHING"
      echo "  = $(basename "$file") (assumed already applied)"
    done
    echo "✓ baselined; nothing was executed"
    exit 0
  fi
fi

# ── 2. Apply anything not yet recorded ──────────────────────────────────────
applied=0
for file in "$MIGRATIONS"/*.sql; do
  name="$(basename "$file")"
  seen="$(psql_q "SELECT 1 FROM $LEDGER WHERE filename = '$name'")"
  [[ "$seen" == "1" ]] && continue

  echo "▸ applying $name"
  # ON_ERROR_STOP plus a single-statement transaction: a migration that fails
  # halfway must leave nothing behind, or the next run starts from a state no
  # file describes. The ledger INSERT rides the same transaction so a rollback
  # takes the bookkeeping with it.
  psql -qX -v ON_ERROR_STOP=1 -d "$DB" <<SQL
BEGIN;
\i $file
INSERT INTO $LEDGER (filename) VALUES ('$name');
COMMIT;
SQL
  applied=$((applied + 1))
done

if [[ "$applied" -eq 0 ]]; then
  echo "✓ database up to date"
else
  echo "✓ applied $applied migration(s)"
fi
