<div align="center">

<img src="app/Resources/icon.png" width="128" alt="">

# Alap

**A local-first macOS email client built for speed.**

Search 32,000 messages in under a millisecond. Open a conversation in a frame.
Triage a mailbox without waiting for anything.

[Why](#why) · [How it works](#how-it-works) · [Zero](#zero) · [Running it](#running-it) · [Architecture](#architecture) · [Status](#status)

</div>

---

<img width="2000" height="1627" alt="CleanShot2026-08-20at18 48 03-ezgif com-optimize" src="https://github.com/user-attachments/assets/6659de86-0749-427c-a26c-cffaeee21e92" />

## Why

This began as an excuse to learn. I wanted real time with C++, Swift, and Zero,
and a mail client turned out to be an honest way to use all three at once: a
sync engine that has to stay correct under retry, an interface that has to feel
immediate, and a replication model that decides what "immediate" can even mean.

It stopped being an exercise somewhere around the point it became the client I
read my own mail in. That is the whole of its endorsement — used daily, by one
person, against a real mailbox.

<img width="2000" height="1613" alt="CleanShot2026-08-20at18 50 26-ezgif com-optimize" src="https://github.com/user-attachments/assets/24c9c2d0-aa5d-47d4-b266-f561b95d6521" />

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
  replica and answers queries from it. This is why reads are instant
  [What that bought, and what it cost](#zero).
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

## Zero

Every claim above about speed comes down to one decision, so it is worth being
explicit about what that decision was and what it cost.

### What Zero is

[Zero](https://zero.rocicorp.dev) is a sync engine. It sits in front of
Postgres and gives the client a *queryable local replica* rather than an API:

- **`zero-cache`** attaches to Postgres as a logical replication subscriber and
  keeps a SQLite copy of the tables in sync, continuously.
- **Clients subscribe to queries**, not endpoints. A query is written in ZQL, a
  typed relational query language, and what comes back is a *materialised view*
  that stays live: when a row it depends on changes anywhere, the view updates
  and the UI re-renders. There is no refresh path to write, because there is
  nothing to refresh.
- **Replication is partial and query-driven.** The client holds the rows its
  queries touch, not the mailbox. A 32,000-message account does not have to be
  on the client for a query over it to be instant.
- **Writes are custom mutators** that run *twice* — once on the client against
  the local store, where the effect is visible in the same frame, then again on
  the server inside a Postgres transaction, where it is authoritative. The
  server's version replicates back and replaces the optimistic guess.

The short version: reads are local because a replica is local, and reads stay
correct because something else is responsible for keeping that replica honest.

### Why it is here

Mail is the case that makes the argument. The data is already downloaded, it
changes underneath you constantly, and every interesting operation is a write
that has to reach a third party eventually. A conventional client answers this
with a cache and an invalidation strategy, and the invalidation strategy is
where mail clients go to be slow.

Three things fall out of Zero that would otherwise each be a subsystem:

**Reads never touch the network.** The list view queries SQLite on the same
machine. 0.5 ms is not an optimisation, it is what a local query costs.

**Reactivity is not plumbed, it is inherent.** The engine writes a newly-synced
message into Postgres; replication carries it to the replica; every query whose
result changed re-fires. New mail appearing in the list ~6 s after it arrives,
a sidebar badge decrementing when a thread is read, a search result updating
while it is on screen, an attachment row gaining a local path when the download
lands — those are all the same mechanism, and none of them has a code path.

**Optimistic writes come with their own rollback.** Archiving fifty threads
paints instantly and reconciles later; if the server's version of the mutator
disagrees, the authoritative rows replace the guess without anyone writing the
diff.

### What makes this an unusual thing to build on Zero

Zero is built for multi-user web apps: React on the front, zero-cache in the
cloud, many clients, permissions per user. Almost none of that describes this.

- **There is one user and no cloud.** Every process runs on the same Mac. The
  WebSocket to zero-cache never leaves the loopback interface, `userID` is
  `null` on every request, and the three database URLs Zero wants —
  upstream, CVR, change — all point at the same local Postgres. The sync
  boundary is not client-to-server, it is *interface-to-replica*.
- **The client is Swift.** Zero's client is TypeScript; the app is SwiftUI and
  AppKit. The whole bridge below exists to close that gap.
- **The upstream is itself a replica.** Postgres is not this app's system of
  record in the usual sense — it is a mirror of Gmail, maintained by the C++
  engine. So Zero replicates a replica, and user writes do not travel back up
  the pipe they arrived on: they land in Postgres and leave for Gmail through
  the outbox, on a completely separate path.
- **Two writers, one replica.** The sidecar writes user intent; the engine
  writes what Gmail said. Neither knows about the other, and replication fans
  both into the same live queries. That is the part that makes "the app has no
  refresh button" true rather than aspirational.

### What it cost

None of this was free, and a fair reading of the choice needs the bill.

| The cost | What it broke | What fixed it |
|---|---|---|
| The client is TypeScript-only | A native app cannot import it | Host the real client in a headless `WKWebView` and speak JSON to it |
| ZQL has no aggregates | Sidebar unread badges need a `COUNT(*)` | Postgres triggers denormalise `unread_count` onto the row; the query reads a column |
| ZQL has no full-text search | Search, entirely | FTS5 in the C++ engine matches; ZQL re-queries by id so results stay live |
| A query the client has never run must round-trip | ~1 s before a message body appeared | `preload()` the reading-pane shape for the top 40 threads → ~3 ms |
| Mutators run twice | `now()` and `randomUUID()` differ between the two runs | Pass timestamps and idempotency keys in as arguments |
| Mutators may not do I/O | Gmail calls cannot happen inside a write | The transactional outbox, drained by the engine |
| Everything in schema `public` replicates | Secrets and bookkeeping would ship to the client | Tokens in the Keychain; the migration ledger in its own schema; attachments store paths, not bytes |
| Zero stops retrying after a fatal error | Mail silently stopped arriving while the app looked fine | An explicit `reconnect` command, backed off, behind a visible indicator |
| `wal_level` defaults to `replica` | zero-cache cannot open a replication slot | `make setup` switches Postgres to `logical` |

The four that were genuinely interesting to solve:

<details>
<summary><b>A TypeScript sync engine inside a native app</b></summary>

Zero's client is TypeScript, and reimplementing its sync protocol in Swift
would mean owning a wire format someone else evolves. So the app hosts the
*real, unmodified* client in a headless `WKWebView` and speaks a small JSON
protocol to it: Swift sends `subscribe` / `preload` / `mutate` commands,
JavaScript sends `update` / `mutateResult` / `connection` events back, every
command carrying an id its reply echoes.

WebKit is a system framework, so this adds nothing to sign, notarise or ship.
It also supplies IndexedDB, WebSocket and fetch, which is precisely why the
client runs unpatched.

Four things about it that were not obvious:

- The web view is mounted in the window hierarchy at zero size. A view that is
  never attached to a window is not reliably scheduled by WebKit — it can sit
  forever without executing anything.
- The bundle loads from `file://`, whose origin is opaque, so it cannot reach
  `http://localhost:4848` without `allowFileAccessFromFileURLs`. The exposure
  is contained by the view being headless, loading only our own bundle, and
  carrying a CSP that allows exactly one `connect-src`.
- zero-cache is plain HTTP on loopback, which App Transport Security blocks by
  default. `NSAllowsLocalNetworking` permits localhost without weakening ATS
  for anything that is actually on a network.
- The bundle is a *build product* declared as a SwiftPM resource, so
  `swift build` fails on a clean checkout until `npm run client:build` has run.
  `make app` does both in order.

The escape hatch, if the JSON relay ever became the bottleneck: JavaScriptCore
with a `kvStore` backed by the C++ SQLite layer — the same seam React Native
uses. It would not change the protocol.

</details>

<details>
<summary><b>Search, when the query language cannot search</b></summary>

ZQL has no full-text search, and the obvious workaround — run FTS5 and render
its rows — throws away the only thing that made the rest of the app feel alive.
A SQLite result set is a snapshot. It does not notice that one of its threads
was just read, or that a reply arrived in another.

So search is two stages. The engine's FTS5 index does the matching and returns
nothing but thread ids; those ids go back through ZQL as `threads.byIds`, and
what renders is a live Zero view like every other list. Mark a result read and
the row updates under the cursor.

Two details this costs: FTS5 ranks by relevance and ZQL returns by recency, so
the original ranking is restored on the Swift side; and the id list is capped
at 500, because it travels as query arguments.

Typing is debounced 150 ms — a search runs on a pause, not a keystroke. Fuzzy
matching is 6.6 ms, so the debounce is about not doing pointless work rather
than about hiding latency.

</details>

<details>
<summary><b>Why opening a thread was slow, and then was not</b></summary>

The reading-pane query is per-thread, so every selection is a query the client
has never run — and a query the client has never run cannot be answered locally.
It goes to zero-cache and comes back about a second later. In a mail client
that second is the whole experience.

The fix is not caching the answer, it is having the rows already: `preload()`
syncs the reading-pane *shape* — messages, bodies, attachments, labels — for
the 40 most recent inbox threads, streaming them into the local store without
materialising JavaScript objects for any of them. The subsequent detail query
then resolves locally and paints in a frame. ~1000 ms became ~3 ms.

40, not 500, deliberately. Bodies are the expensive rows — that is why
`message_body` is a separate table the list query never touches — and 40 covers
essentially all arrow-key navigation before the reader pauses. Selection is
still debounced 70 ms, which now exists only to coalesce a held arrow key
rather than to hide a network round trip.

</details>

<details>
<summary><b>The consequences of a mutator running twice</b></summary>

A mutator's body executes on the client against the local store *and* on the
server against Postgres. Anything non-deterministic therefore has two different
answers, and the server's wins.

The sharp edge is that Zero does not consult database defaults when it builds
the optimistic row — on the client there is no Postgres to ask. A column with
`DEFAULT now()` and `NOT NULL` is simply missing, so timestamps are computed in
the mutator and the resulting clock skew self-heals when the server's row
replicates back. Ids are the same problem, which is why the outbox row's
idempotency key is a UUID generated by the *caller* and passed in: both runs
write the same key, so a retried mutation collapses onto one row instead of
sending the same Gmail call twice.

The other rule is that a mutator may not perform network I/O — it has to be a
fast local transaction, twice. That constraint is what produced the outbox, and
the outbox turned out to be the right design regardless: the label change and
the record of remote intent commit atomically, so a crash cannot archive a
thread locally and not on Gmail.

</details>

<details>
<summary><b>Smaller things that only bite once</b></summary>

- **`resultType` never reports `complete` across the bridge.** Zero delivers
  locally-cached rows immediately and confirms afterwards, and the UI was meant
  to distinguish "empty mailbox" from "not loaded yet" on that flag. It never
  arrived, and gating on it left the app saying *Loading…* forever. The list
  and the reading pane now treat the first update as loaded.
- **A list that grows has no pagination.** Growing means re-subscribing with a
  larger `limit`, which Zero extends rather than re-fetching. There is a
  50,000-row ceiling because these rows decode into Swift structs at ~456 bytes
  each, and past that the array is the cost, not the query.
- **Wide queries are the enemy.** The list query has no `.related()` at all —
  bare thread rows, ~200 bytes, with subject, snippet, participants and counts
  denormalised onto them. Only the reading pane pulls bodies.
- **Subscribe twice, render twice.** `addListener` fires immediately with
  whatever is cached, so also pushing the view's current data emits every
  update twice — which in SwiftUI is two invalidations per change.
- **Replication is a security boundary.** Zero's publication is `FOR TABLES IN
  SCHEMA public`, so anything created there reaches every client. Refresh
  tokens live in the Keychain for that reason, and the migration ledger lives
  in its own schema so it never lands in the replica at all.
- **Port collisions read as schema errors.** zero-cache picks :4849 for itself,
  nothing configures it, and a second copy of the stack fails there only after
  getting far enough to check schemas and open a replication slot. `make dev`
  refuses to start alongside the login agent for this reason.

</details>

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

Everything Zero is responsible for — the web view, the two-stage search, the
preload, the outbox — is in [Zero](#zero) above.

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
