<div align="center">

<img src="app/Resources/icon.png" width="128" alt="">

# Alap

**A local-first macOS email client built for speed.**

Search 32,000 messages in under a millisecond. Open a conversation in a frame.
Triage a mailbox without waiting for anything.

[Why](#why) · [How it works](#how-it-works) · [Running it](#running-it) · [Architecture](#architecture) · [Status](#status)

</div>

---

## Why

This began as an excuse to learn. I wanted real time with C++, Swift, and Zero,
and a mail client turned out to be an honest way to use all three at once: a
sync engine that has to stay correct under retry, an interface that has to feel
immediate, and a replication model that decides what "immediate" can even mean.

It stopped being an exercise somewhere around the point it became the client I
read my own mail in. That is the whole of its endorsement — used daily, by one
person, against a real mailbox.

The technical argument came second, and it is this.

Mail clients are slow in a specific, avoidable way: they treat the network as
the source of truth and the interface as a view onto it. Every click waits for
a round trip, and the mailbox you already downloaded is queried as if it were
somewhere else.

This does the opposite. Every read is answered from a local replica before it is
answered by anything remote, and Gmail is treated as something to reconcile
with rather than something to wait on.

The measurable result, against a real 32,000-message mailbox:

| | |
|---|---|
| Full-text search | **0.5 ms** typical, 2.5 ms worst observed |
| Fuzzy search (typo correction) | **6.6 ms** |
| Open a conversation | ~3 ms (was ~1000 ms before preloading) |
| Gmail backfill | **64 messages/sec** — a 31k mailbox in ~8 minutes |
| Attachment download, click to open | **268 ms** end to end |
| Arrow-key triage | 1 query per pause, not 1 per keypress |
| New mail appearing, no refresh | **~6 s** measured end to end |

## How it works

Four processes, all on your machine. Nothing is hosted anywhere.

```
┌──────────────┐   named queries    ┌──────────────┐
│  SwiftUI app │ ◄────────────────► │  zero-cache  │
│  (AppKit)    │    WebSocket       │  + SQLite    │
└──────┬───────┘                    └──────┬───────┘
       │                                   │ logical
       │ spawns                            │ replication
       ▼                                   ▼
┌──────────────┐    reads/writes    ┌──────────────┐
│  C++ engine  │ ─────────────────► │  PostgreSQL  │
│ (mailengined)│                    └──────────────┘
└──────┬───────┘
       │ HTTPS
       ▼
   Gmail API
```

- **PostgreSQL** holds the mail. It is the only source of truth.
- **[Zero](https://zero.rocicorp.dev)** replicates Postgres into a local SQLite
  replica and answers queries from it. This is why reads are instant.
- **The C++ engine** owns every network call, the Keychain, and the search
  index. It syncs Gmail into Postgres and drains an outbox of pending writes.
  The app launches it and polls every 10 seconds, so mail arrives without
  anyone asking. Gmail's push mechanism needs a public HTTPS endpoint for Cloud
  Pub/Sub to call, which a local-only app does not have — so polling
  `history.list` is the honest option. It is incremental and costs 2 quota
  units against a budget of 250 per second.
- **The SwiftUI app** renders. It never talks to Gmail and never holds a
  credential.

### Three ideas the rest follows from

**Labels, not folders.** Gmail has no folders and no archive operation —
archiving *is* removing the `INBOX` label. Modelling that directly means one
"Inbox" entry in the sidebar can mean every connected account's inbox at once,
which is the whole answer to managing several mailboxes.

**A transactional outbox.** Mutations never perform network I/O. They write the
user-visible change *and* a row describing the remote intent in one Postgres
transaction; the engine drains that row later. A crash can never leave a thread
archived locally but not on Gmail, and a flaky network is a delay rather than a
lost operation.

**The network is not in the read path.** Reads hit the local replica first and
paint on the first frame. The remote answer arrives afterwards and replaces the
guess if it differs.

## Running it

Requires macOS 14.4+, Xcode command-line tools, and Homebrew. Everything else is
installed for you.

```bash
git clone <your-fork> && cd alap
make setup
```

`make setup` installs the Homebrew dependencies, starts PostgreSQL and switches
it to `wal_level = logical`, creates the `mailapp` database and applies the
migrations, writes a `.env`, installs the npm workspaces, creates the local
signing identity, and builds the C++ engine. It is idempotent — re-running it on
a working machine is the fastest way to find out what drifted.

Two of those steps have no obvious failure mode if skipped, which is why they
are automated rather than documented: PostgreSQL ships with `wal_level =
replica`, and zero-cache cannot open a replication slot without `logical`; and
the migrations under `packages/sidecar/migrations` have to be applied before
anything replicates. Miss either and the build still succeeds, the app still
launches, and the mailbox is simply empty forever.

Then add a Google OAuth client to `.env` (see **Google Cloud setup** below) and
run these three once:

```bash
make agent      # start the background services at login
make connect    # authorise a mailbox
make install    # put Alap.app in /Applications
```

After that there is nothing to run. Open Alap from Spotlight or the Dock like
any other application: the services it needs are already up, and the app starts
its own sync engine.

| | |
|---|---|
| `make stop` | Stop the app and every background service it runs |
| `make agent-status` | Show what is currently up |
| `make agent` | Start the services now, and at every login |
| `make agent-uninstall` | Stop starting them at login, for good |

`make stop` leaves the agent installed, so the services return at the next
login; `make agent` brings them back sooner. Postgres is left running either
way — Homebrew owns its login agent and other things on the machine may be using
it, so stopping it is `brew services stop postgresql@18` and deliberately not
Alap's business.

<details>
<summary><b>Working on the code instead</b></summary>

The installed copy is a build artefact, not the source of truth. While changing
things, run the stack in the foreground and launch straight from `build/`:

```bash
make dev        # postgres + sidecar + zero-cache, holds the terminal
make app        # rebuild and launch build/Alap.app
```

Use `make dev` **or** the login agent, never both — they want the same ports.
With the agent running, `make dev` says so and exits instead of starting a
second copy, because the collision is otherwise hard to read: the sidecar fails
immediately on :3000, while zero-cache gets as far as checking schemas and
opening a replication slot before dying on :4849 — a port nothing here
configures, because zero-cache picks it itself.

`make install` copies `.env` rather than linking it, so re-run it after changing
credentials.

</details>

`make` on its own lists every target.

<details>
<summary><b>What .env holds</b></summary>

`make setup` writes this from `.env.example`, substituting your username. Only
the two Google values need filling in by hand.

```ini
# All three point at the same local database. Zero wants them separate so they
# can diverge in a hosted deployment; locally they never do.
ZERO_UPSTREAM_DB="postgres://YOUR_USER@localhost:5432/mailapp"
ZERO_CVR_DB="postgres://YOUR_USER@localhost:5432/mailapp"
ZERO_CHANGE_DB="postgres://YOUR_USER@localhost:5432/mailapp"

# zero-cache's SQLite replica. This is what queries actually run against, which
# is why reads are fast. Keep it on an internal SSD.
ZERO_REPLICA_FILE="./.data/zero-replica.db"

# Clients never send raw ZQL — they send a query NAME that the sidecar resolves
# server-side. That indirection is the basis of Zero's permission model.
ZERO_QUERY_URL="http://localhost:3000/api/query"
ZERO_MUTATE_URL="http://localhost:3000/api/mutate"
ZERO_ENABLE_CRUD_MUTATIONS="false"
ZERO_ADMIN_PASSWORD="change-me-locally"

# From your Google Cloud OAuth client (type: Desktop app).
GOOGLE_CLIENT_ID="..."
GOOGLE_CLIENT_SECRET="..."
```

The engine reads these from the environment and does not parse `.env` itself, so
a bare `./engine/build/mailengined ...` invocation needs `set -a; source .env;
set +a` first. The `make` targets do it for you.

</details>

`make app` builds the Zero client bundle before it compiles Swift, which
matters if you ever reach for `swift build` directly: `app/Package.swift`
declares `Sources/Alap/Web` as a resource and that directory is **generated,
not committed**, so SwiftPM refuses to build without it. Run
`npm run client:build` first, or just use `make app`.

### Tests

```bash
ctest --test-dir engine/build      # 304 cases
swift test --package-path app      # 301 cases
```

Both suites are hermetic — no database, no network, no Gmail account — which is
why CI can run them. What CI does *not* cover: `tools/render-audit`, which
measures real stored messages and needs a local Postgres, and anything visual.

Click **Add Account** in the sidebar to authorise a mailbox. That is the whole
setup — the app launches the sync engine itself and polls every 10 seconds for
as long as it is open, starting with a poll as the window appears.

<details>
<summary><b>Running the engine manually</b></summary>

Useful for watching what it does, or for syncing without the app open:

```bash
set -a && . ./.env && set +a
./engine/build/mailengined daemon 10
```

Only one daemon runs at a time — it takes a Postgres advisory lock, so a second
one exits immediately rather than double-polling. If you start one here, the
app defers to it.

</details>

<details>
<summary><b>Why the signing certificate matters</b></summary>

An ad-hoc signature has no stable identity — its designated requirement is a
code-directory hash that changes on **every build**, so macOS treats each build
as a different application and re-prompts for Keychain access forever.

`make setup` creates a self-signed identity whose requirement is
`identifier + certificate fingerprint`, which is constant. It asks for your
login keychain password once, via macOS's own dialog, and never reads or stores
it.

There is no need to run `scripts/make-signing-cert.sh` by hand — `make setup`
skips it when an identity already exists, and minting a second one changes the
designated requirement, which re-prompts for every credential the Keychain
already holds.

This is *not* a substitute for a Developer ID: Gatekeeper does not trust it, so
it does nothing for distribution.

</details>

<details>
<summary><b>Google Cloud setup</b></summary>

1. Create a project and enable the **Gmail API**.
2. Create an **OAuth client ID** of type *Desktop app*.
3. Add your own address under **Audience → Test users**.

Note that refresh tokens issued while an app is in *Testing* status expire
after **7 days**. Until the app is verified or published, accounts need
reconnecting weekly. That is Google policy, not a limitation of this code.

</details>

## Architecture

```
engine/     C++20 — Gmail sync, OAuth, outbox drain, FTS5 search, MIME
app/        SwiftUI + AppKit — the interface
packages/
  shared/   Zero schema, named queries, mutators (the write API)
  sidecar/  Node service zero-cache calls for queries and mutations
  client/   the headless Zero client, hosted in a WKWebView
scripts/    build, run, signing, icon generation
```

### Notable decisions

<details>
<summary><b>Why is there a WKWebView in a native app?</b></summary>

Zero's client is TypeScript-only. Rather than reimplement its sync protocol in
Swift, the app hosts the real client in a headless web view and speaks a small
JSON protocol to it. The view is zero-sized and mounted in the window hierarchy
because WebKit will not reliably schedule a web view that has never been
attached to one.

</details>

<details>
<summary><b>Attachments are content-addressed</b></summary>

Blobs are stored under the SHA-256 of their contents, not their filename.
Filenames come from email and are attacker-controlled — an attachment named
`../../../.ssh/authorized_keys` is a real attack, and sanitising names is a
blocklist that eventually misses a case. Deriving the path from a digest makes
traversal structurally impossible.

It deduplicates too: in a real mailbox, 23 attachment rows resolved to 7 files
on disk, because the same images had been forwarded down a thread.

</details>

<details>
<summary><b>Security posture</b></summary>

- **Refresh tokens live in the macOS Keychain, never in Postgres.** Anything in
  Postgres replicates to every client.
- **HTML is sanitised on ingest** by an allowlist tokeniser in the engine. On a
  real mailbox this stripped active content from 29,028 messages and blocked
  617,916 tracking pixels.
- **The reading pane assumes the sanitiser failed.** JavaScript is disabled at
  the WebKit level, `baseURL` is nil, and a CSP of `default-src 'none'`
  forbids every remote fetch.
- **Inline images are type-sniffed from their bytes**, not trusted from the
  message's declared MIME type. SVG is refused outright — it is a document
  format that can carry script.
- **Every Postgres query is parameterised**; every SQLite statement is bound.
- OAuth uses **PKCE with a loopback redirect**. The client secret is never
  shipped in the app bundle — the engine owns it.

</details>

## Testing

```bash
make test       # all three suites
```

Or individually:

```bash
cmake --build engine/build && ctest --test-dir engine/build   # 304
swift test --package-path app                                 # 301
npm test --workspace=@mailapp/sidecar                          #  14
```

The first two are hermetic. The sidecar suite is not — it connects to
`ZERO_UPSTREAM_DB` and needs Postgres up, which is why CI runs only the other
two. It creates `acct_test_*` accounts, works inside a transaction it rolls
back, and deletes its own account afterwards, so it is safe against a real
mailbox.

**619 tests.** They lean deliberately toward the places where being wrong is
invisible: RFC 5322 header folding, path traversal, colour contrast ratios,
query arguments that silently match one account instead of all of them.

## Status

**Pre-alpha.** It runs, it is used daily against a real 32,000-message mailbox,
and it has no installed base — so anything here can change without ceremony.
There is no release build: you build it yourself.

Working: multi-account Gmail sync, unified inbox, full-text and fuzzy search,
keyboard triage, bulk actions, composing and replying, undo, HTML rendering
with inline images and a privacy-first remote-image policy, attachment download,
list density, and six themes — three dark, three light, one of them a
maximum-contrast palette for glare and low vision.

Not yet: reply-all, attachments on send, attachment cache eviction, Dynamic
Type, and anything to do with distribution — this is not notarised and will not
open on someone else's Mac without building it.

Not planned: IMAP. The sync model leans on Gmail's history API, and pretending
otherwise would be a worse client for both.

## Licence

MIT — see [LICENSE](LICENSE).
