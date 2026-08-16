# Environment Setup

Local-sidecar topology: Postgres, `zero-cache`, the TypeScript sidecar, and the
C++ engine all run on this Mac. Nothing leaves the machine.

## One-time

```bash
# 1. Accept the Xcode license (required after installing Xcode.app — blocks ALL
#    compilation, including plain clang++, until accepted)
sudo xcodebuild -license accept

# 2. Toolchain
brew install postgresql@18 pkgconf

# 3. Postgres: enable logical replication (Zero requires wal_level=logical)
export PATH="/opt/homebrew/opt/postgresql@18/bin:$PATH"
export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
pg_ctl -D /opt/homebrew/var/postgresql@18 -l .data/postgres.log start
psql -d postgres -c "ALTER SYSTEM SET wal_level = 'logical';"
psql -d postgres -c "ALTER SYSTEM SET max_wal_senders = 10;"
psql -d postgres -c "ALTER SYSTEM SET max_replication_slots = 10;"
pg_ctl -D /opt/homebrew/var/postgresql@18 restart
createdb mailapp

# 4. Node deps
npm install

# 5. Config
cp .env.example .env   # then fill in GOOGLE_CLIENT_ID / GOOGLE_CLIENT_SECRET
```

## Daily

```bash
npm run dev        # postgres + sidecar (:3000) + zero-cache (:4848)
```

```bash
cd engine && cmake -S . -B build && cmake --build build -j8 && ctest --test-dir build
```

## Gotchas hit during setup

These are non-obvious and cost real time. Recorded so they aren't rediscovered.

### Postgres 18 refuses to start with an unset locale

```
FATAL: postmaster became multithreaded during startup
HINT:  Set the LC_ALL environment variable to a valid locale.
```

macOS spawns threads during startup when the locale is invalid, and Postgres 18
aborts because a multithreaded postmaster cannot safely `fork()`. Fix: export
`LC_ALL=en_US.UTF-8` before starting. `scripts/dev.sh` does this; the launchd
plist at `~/Library/LaunchAgents/homebrew.mxcl.postgresql@18.plist` needs an
`EnvironmentVariables` block with the same for `brew services` to work.

### npm 11 blocks install scripts by default

Zero's docs warn about this for pnpm/bun/yarn, but **npm 11.19 does it too**.
`@rocicorp/zero-sqlite3` is a native module — if its `node-gyp-build` step is
skipped, `zero-cache` fails at runtime rather than at install time, which is a
confusing failure. Approvals are recorded in `package.json` under
`allowScripts`, so this is reproducible:

```bash
npm install-scripts approve @rocicorp/zero-sqlite3 esbuild protobufjs
npm rebuild @rocicorp/zero-sqlite3 esbuild
```

### libpq is not where CMake looks

Homebrew's `postgresql@18` is keg-only *and* nests its libraries under
`lib/postgresql/`, so `find_library(pq)` misses it. `engine/CMakeLists.txt`
goes through `pkg-config` instead, which also requires `brew install pkgconf` —
not installed by default on macOS.

### `zero-cache-dev` must be run through npm, not by path

`zero-cache-dev` is a thin wrapper that shells out to `zero-cache` and expects
it on `PATH`. Invoking `node_modules/.bin/zero-cache-dev` directly fails with
`/bin/sh: zero-cache: command not found`. Use `npx zero-cache-dev` or an npm
script — both put `node_modules/.bin` on `PATH`. `scripts/dev.sh` goes through
`npm run`, so it is unaffected.

### `std::println` is C++23

This project is pinned to C++20 (`CXX_STANDARD 20`, `CXX_EXTENSIONS OFF`). Use
`<iostream>` or `<format>`. Apple clang will reject `<print>`.

## Architecture invariants

Rules that keep the design coherent. Violating these is how this project goes
wrong.

1. **The C++ engine never talks to Zero.** It writes rows to Postgres; logical
   replication carries them to `zero-cache`. The engine has no Zero dependency.

2. **Mutators never do network I/O.** A Zero mutator is a fast, transactional
   Postgres operation. Gmail/IMAP side effects are written as rows into a
   command outbox table *in the same transaction* as the state change, then
   drained by the C++ engine. This is what preserves optimistic UI and gives
   retries and idempotency.

3. **Attachments do not go in Postgres.** `zero-cache` replicates the whole
   table into SQLite and is only recommended below ~100GB. Blobs go on disk,
   content-addressed; Postgres stores metadata and a path.

4. **Unread counts are denormalized columns.** ZQL has no aggregates
   (`count`/`group-by` are unshipped as of 1.7), so sidebar badges read a
   maintained column, not a live `COUNT(*)`.

5. **Search is FTS5, not ZQL.** ZQL has no text search. C++ owns a SQLite FTS5
   index; it returns thread IDs, which are then fed into a reactive ZQL
   `where('id', 'IN', ids)` so results still update live.
