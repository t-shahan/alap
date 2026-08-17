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

Requires macOS 14+, Xcode command-line tools, Node 20+, PostgreSQL 18, CMake,
and a Google Cloud project with the Gmail API enabled.

```bash
brew install postgresql@18 cmake pkgconf libpq
createdb mailapp

git clone <your-fork> && cd alap
npm install
```

Create a `.env` in the repository root:

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

Then build and run:

```bash
./scripts/make-signing-cert.sh          # stable local code signing (see below)
cmake -S engine -B engine/build
cmake --build engine/build -j8

npm run dev                             # postgres + sidecar + zero-cache
npm run app                             # build and launch Alap.app
```

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

`make-signing-cert.sh` creates a self-signed identity whose requirement is
`identifier + certificate fingerprint`, which is constant. It asks for your
login keychain password once, via macOS's own dialog, and never reads or stores
it.

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
cmake --build engine/build && ctest --test-dir engine/build   # 197
swift test --package-path app                                 # 101
npm test --workspace=@mailapp/sidecar                          #  14
```

**312 tests.** They lean deliberately toward the places where being wrong is
invisible: RFC 5322 header folding, path traversal, colour contrast ratios,
query arguments that silently match one account instead of all of them.

## Status

Working: multi-account Gmail sync, unified inbox, full-text and fuzzy search,
keyboard triage, HTML rendering with inline images, attachment download,
replies, three themes.

Not yet: composing new messages, reply-all, attachments on send, undo,
attachment cache eviction, and anything to do with distribution — this is not
notarised and will not open on someone else's Mac without building it.

Not planned: IMAP. The sync model leans on Gmail's history API, and pretending
otherwise would be a worse client for both.

## Licence

MIT — see [LICENSE](LICENSE).
