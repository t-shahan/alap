#!/usr/bin/env bash
#
# Takes a fresh checkout to a running build, in one command.
#
#   ./scripts/setup.sh          # or: make setup
#
# Every step is idempotent and announces whether it changed anything, so this is
# safe to re-run on a machine that is already working — and re-running it is the
# fastest way to find out what drifted.
#
# ## What this covers that the README did not
#
#   * `wal_level = logical`. Postgres ships with `replica`, and zero-cache
#     cannot open a replication slot without logical. The failure surfaces much
#     later as an app with an empty mailbox.
#   * The migrations in packages/sidecar/migrations. There was no runner and no
#     mention of them, so a fresh database had no schema at all.
#
set -euo pipefail
cd "$(dirname "$0")/.."

BOLD=$'\033[1m'; DIM=$'\033[2m'; YEL=$'\033[33m'; OFF=$'\033[0m'
step() { printf '\n%s▸ %s%s\n' "$BOLD" "$1" "$OFF"; }
ok()   { printf '  ✓ %s\n' "$1"; }
skip() { printf '  %s= %s%s\n' "$DIM" "$1" "$OFF"; }
warn() { printf '  %s! %s%s\n' "$YEL" "$1" "$OFF"; }
die()  { printf '\nerror: %s\n' "$1" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || die "macOS only — this builds a SwiftUI app"

# ── 1. Homebrew dependencies ────────────────────────────────────────────────
step "checking dependencies"
command -v brew >/dev/null 2>&1 ||
  die "Homebrew not found — install from https://brew.sh then re-run"

BREW_PREFIX="$(brew --prefix)"
# postgresql@18 is keg-only; its binaries never land on the default PATH.
export PATH="$BREW_PREFIX/opt/postgresql@18/bin:$PATH"
# Postgres 18 on macOS aborts with "postmaster became multithreaded during
# startup" when the locale is unset.
export LC_ALL="${LC_ALL:-en_US.UTF-8}"
export LANG="${LANG:-en_US.UTF-8}"

for pkg in postgresql@18 cmake pkgconf libpq node; do
  if brew list --versions "$pkg" >/dev/null 2>&1; then
    skip "$pkg"
  else
    echo "  installing ${pkg}…"
    brew install "$pkg"
    ok "$pkg"
  fi
done

# package.json declares engines.node >= 22, and the sidecar runs .ts directly
# through node's type stripping, which is not in 20.
NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
[[ "$NODE_MAJOR" -ge 22 ]] ||
  die "node 22+ required (found $(node -v 2>/dev/null || echo none)) — try: brew upgrade node"
ok "node $(node -v)"

# ── 2. Postgres: running, logical, and holding a database ───────────────────
step "postgres"
PGDATA="$BREW_PREFIX/var/postgresql@18"

if ! pg_isready -q 2>/dev/null; then
  [[ -d "$PGDATA" ]] || die "no cluster at $PGDATA — try: brew reinstall postgresql@18"
  mkdir -p .data
  pg_ctl -D "$PGDATA" -l .data/postgres.log start >/dev/null
  until pg_isready -q; do sleep 0.3; done
  ok "started"
else
  skip "already running"
fi

# wal_level is the step whose absence is hardest to diagnose: everything builds,
# the app launches, and the mailbox is simply empty forever.
CONF="$(psql -tAX -d postgres -c 'SHOW config_file;')"
if [[ "$(psql -tAX -d postgres -c 'SHOW wal_level;')" != "logical" ]]; then
  # Appended rather than edited in place: the last assignment wins in
  # postgresql.conf, so this needs no parsing and cannot corrupt the file.
  printf '\n# Required by zero-cache (added by scripts/setup.sh)\nwal_level = logical\n' >> "$CONF"
  pg_ctl -D "$PGDATA" -l .data/postgres.log restart >/dev/null
  until pg_isready -q; do sleep 0.3; done
  [[ "$(psql -tAX -d postgres -c 'SHOW wal_level;')" == "logical" ]] ||
    die "wal_level is still not logical — check $CONF"
  ok "wal_level = logical (restarted)"
else
  skip "wal_level = logical"
fi

if psql -tAXlq | cut -d'|' -f1 | grep -qx "mailapp"; then
  skip "database mailapp"
else
  createdb mailapp
  ok "created database mailapp"
fi

# ── 3. .env ─────────────────────────────────────────────────────────────────
step "configuration"
if [[ -f .env ]]; then
  skip ".env exists"
else
  # The template ships a literal YOUR_USER placeholder; on macOS the Postgres
  # superuser is the login account, so this is always the right substitution.
  sed "s|YOUR_USER|$(whoami)|g" .env.example > .env
  ok "wrote .env from .env.example"
fi

set -a; source .env; set +a
if [[ -z "${GOOGLE_CLIENT_ID:-}" ]]; then
  warn "GOOGLE_CLIENT_ID is empty — Gmail sync will not work until it is set"
  warn "see the Google Cloud setup section of the README"
else
  skip "google oauth client configured"
fi

# ── 4. Node workspaces and the schema ───────────────────────────────────────
step "node workspaces"
npm install --silent
ok "npm install"

step "database schema"
./scripts/migrate.sh

# ── 5. Local signing identity ───────────────────────────────────────────────
#
# Not cosmetic: without a stable designated requirement the Keychain ACL holding
# the OAuth refresh token never matches, and every rebuild re-prompts.
step "code signing identity"
# Both names, matching the IDENTITIES list in sign.sh. The project was renamed,
# and sign.sh still accepts the old certificate precisely so that anyone who set
# up beforehand is not re-prompted for every stored Keychain credential.
# Checking only the new name here would mint a second certificate and cause the
# exact re-prompt the rename was careful to avoid.
if security find-identity -p codesigning 2>/dev/null | grep -qE "Alap Local Dev|Mail Local Dev" ||
   security find-identity 2>/dev/null | grep -qE "Alap Local Dev|Mail Local Dev"; then
  skip "signing identity present"
else
  ./scripts/make-signing-cert.sh
fi

# ── 6. Engine ───────────────────────────────────────────────────────────────
step "building the engine"
cmake -S engine -B engine/build >/dev/null
cmake --build engine/build -j"$(sysctl -n hw.ncpu)"
ok "engine/build/mailengined"

# ── 7. What to do next ──────────────────────────────────────────────────────
printf '\n%s✓ setup complete%s\n\n' "$BOLD" "$OFF"
if [[ -z "${GOOGLE_CLIENT_ID:-}" ]]; then
  printf '  1. put a Google OAuth client in .env  (README → Google Cloud setup)\n'
  printf '  2. make dev      # postgres + sidecar + zero-cache\n'
  printf '  3. make connect  # authorise a mailbox\n'
  printf '  4. make app      # build and launch Alap.app\n\n'
else
  printf '  make dev      # postgres + sidecar + zero-cache\n'
  printf '  make connect  # authorise a mailbox\n'
  printf '  make app      # build and launch Alap.app\n\n'
fi
