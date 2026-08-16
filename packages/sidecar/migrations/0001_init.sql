-- ============================================================================
-- 0001_init.sql — core mail schema
--
-- Design notes that apply to every table below:
--
--   * Every table has a single-column TEXT primary key. Zero requires a primary
--     key on all replicated tables, and text IDs let us use natural, stable
--     keys of the form '<account_id>:<provider_id>'. That makes the C++ sync
--     engine's writes idempotent: re-fetching a message produces the same ID,
--     so an INSERT ... ON CONFLICT DO UPDATE is always safe to retry.
--
--   * Every table carries account_id. Unified inbox is then a query with no
--     account filter; switching accounts adds one predicate.
--
--   * timestamptz columns surface in Zero/TypeScript as `number` (epoch millis),
--     NOT as Date objects.
-- ============================================================================

BEGIN;

-- ── Enums ───────────────────────────────────────────────────────────────────
-- Postgres enums map to Zero's enumeration<>() helper, which gives the Swift
-- and TS layers a closed set of values instead of free-form strings.

CREATE TYPE account_provider AS ENUM ('gmail', 'imap');
CREATE TYPE label_kind       AS ENUM ('system', 'user');
CREATE TYPE outbox_status    AS ENUM ('pending', 'in_flight', 'done', 'failed');
CREATE TYPE outbox_op        AS ENUM (
  'modify_labels',  -- add/remove labels (this is how Gmail archives, stars, trashes)
  'mark_read',
  'send',
  'delete_forever'
);

-- ── account ─────────────────────────────────────────────────────────────────
-- One row per connected mailbox.
--
-- SECURITY: no OAuth tokens live here. The refresh token is the real
-- credential and belongs in the macOS Keychain, keyed by account id. Postgres
-- holds only the non-secret identity of the account. This table replicates to
-- every client via Zero — anything in it should be considered readable.
CREATE TABLE account (
  id                TEXT PRIMARY KEY,
  email_address     TEXT        NOT NULL,
  display_name      TEXT        NOT NULL DEFAULT '',
  provider          account_provider NOT NULL,

  -- UI affordance: the accent colour used for this account's badge, so a
  -- unified inbox can show provenance without a text label.
  color             TEXT        NOT NULL DEFAULT '#6E7B8B',
  sort_order        INTEGER     NOT NULL DEFAULT 0,

  -- Gmail incremental sync watermark. We ask history.list for everything since
  -- this ID rather than re-scanning the mailbox — this is the mechanism that
  -- makes refresh fast instead of "frustratingly slow".
  -- NULL means "never synced": the engine must do a full backfill first.
  last_history_id   TEXT,
  last_synced_at    TIMESTAMPTZ,

  -- Set when the user disconnects an account. Soft delete so in-flight outbox
  -- rows can drain before the data is purged.
  disconnected_at   TIMESTAMPTZ,

  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),

  CONSTRAINT account_email_provider_unique UNIQUE (email_address, provider)
);

-- ── label ───────────────────────────────────────────────────────────────────
-- Gmail labels AND IMAP folders. Gmail has no folders: a message carries many
-- labels, and "archive" simply removes INBOX. IMAP folders are the degenerate
-- case of this model — a message with exactly one label.
CREATE TABLE label (
  id            TEXT PRIMARY KEY,
  account_id    TEXT       NOT NULL REFERENCES account(id) ON DELETE CASCADE,

  -- Provider-side identifier, e.g. 'INBOX', 'STARRED', 'Label_42'.
  remote_id     TEXT       NOT NULL,
  name          TEXT       NOT NULL,
  kind          label_kind NOT NULL DEFAULT 'user',
  color         TEXT,
  sort_order    INTEGER    NOT NULL DEFAULT 0,

  -- Denormalised counters. ZQL has no aggregates (no COUNT/GROUP BY as of 1.7),
  -- so sidebar badges read these columns directly. Maintained by trigger below
  -- rather than by application code, because BOTH the C++ engine and Zero
  -- mutators write to message_label — a trigger is the only place that sees
  -- every writer and therefore the only place the count cannot drift.
  unread_count  INTEGER    NOT NULL DEFAULT 0,
  total_count   INTEGER    NOT NULL DEFAULT 0,

  CONSTRAINT label_account_remote_unique UNIQUE (account_id, remote_id)
);
CREATE INDEX label_account_idx ON label (account_id, sort_order);

-- ── thread ──────────────────────────────────────────────────────────────────
-- Threads are stored rows, not a GROUP BY over messages. The list view reads
-- thread-level state constantly and ZQL cannot aggregate, so subject, snippet,
-- participants and counts must be materialised here.
CREATE TABLE thread (
  id                TEXT PRIMARY KEY,
  account_id        TEXT        NOT NULL REFERENCES account(id) ON DELETE CASCADE,
  remote_thread_id  TEXT        NOT NULL,

  subject           TEXT        NOT NULL DEFAULT '',
  -- Preview text for the list row, denormalised from the newest message so the
  -- list view never has to join to message_body.
  snippet           TEXT        NOT NULL DEFAULT '',

  -- [{name, email}] of everyone in the thread, in first-appearance order.
  -- JSONB rather than a join table: this is display-only, always read as a
  -- whole, and never queried by element.
  participants      JSONB       NOT NULL DEFAULT '[]'::jsonb,

  last_message_at   TIMESTAMPTZ NOT NULL,
  message_count     INTEGER     NOT NULL DEFAULT 0,
  unread_count      INTEGER     NOT NULL DEFAULT 0,
  has_attachments   BOOLEAN     NOT NULL DEFAULT FALSE,
  is_starred        BOOLEAN     NOT NULL DEFAULT FALSE,

  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),

  CONSTRAINT thread_account_remote_unique UNIQUE (account_id, remote_thread_id)
);
-- The primary list-view query: newest threads first, per account.
CREATE INDEX thread_account_recent_idx ON thread (account_id, last_message_at DESC);
-- The unified-inbox variant: newest across all accounts.
CREATE INDEX thread_recent_idx ON thread (last_message_at DESC);

-- ── message ─────────────────────────────────────────────────────────────────
-- METADATA ONLY. Bodies live in message_body. This split is the biggest lever
-- on perceived speed: a list-view query syncs ~200 bytes per message instead of
-- dragging every HTML body the user will never open.
CREATE TABLE message (
  id                 TEXT PRIMARY KEY,
  account_id         TEXT        NOT NULL REFERENCES account(id) ON DELETE CASCADE,
  thread_id          TEXT        NOT NULL REFERENCES thread(id)  ON DELETE CASCADE,
  remote_message_id  TEXT        NOT NULL,

  -- The RFC 5322 Message-ID header. Distinct from remote_message_id (which is
  -- provider-assigned). Needed to reconstruct threading over plain IMAP, where
  -- there is no server-side thread concept.
  rfc822_message_id  TEXT,

  from_name          TEXT        NOT NULL DEFAULT '',
  from_email         TEXT        NOT NULL,
  -- [{name, email}] — same reasoning as thread.participants.
  to_recipients      JSONB       NOT NULL DEFAULT '[]'::jsonb,
  cc_recipients      JSONB       NOT NULL DEFAULT '[]'::jsonb,
  bcc_recipients     JSONB       NOT NULL DEFAULT '[]'::jsonb,

  subject            TEXT        NOT NULL DEFAULT '',
  snippet            TEXT        NOT NULL DEFAULT '',
  sent_at            TIMESTAMPTZ NOT NULL,

  is_read            BOOLEAN     NOT NULL DEFAULT FALSE,
  is_starred         BOOLEAN     NOT NULL DEFAULT FALSE,
  is_draft           BOOLEAN     NOT NULL DEFAULT FALSE,
  has_attachments    BOOLEAN     NOT NULL DEFAULT FALSE,
  size_bytes         INTEGER     NOT NULL DEFAULT 0,

  created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),

  CONSTRAINT message_account_remote_unique UNIQUE (account_id, remote_message_id)
);
CREATE INDEX message_thread_idx  ON message (thread_id, sent_at);
CREATE INDEX message_account_idx ON message (account_id, sent_at DESC);

-- ── message_body ────────────────────────────────────────────────────────────
-- Large payloads, fetched on demand by the reading-pane query.
CREATE TABLE message_body (
  message_id   TEXT PRIMARY KEY REFERENCES message(id) ON DELETE CASCADE,
  account_id   TEXT        NOT NULL REFERENCES account(id) ON DELETE CASCADE,

  text_body    TEXT,
  -- Sanitised HTML. The C++ engine strips scripts, event handlers and remote
  -- resources before this is ever written, so the Swift renderer can trust it.
  html_body    TEXT,
  -- Full header set, for "show original" and for debugging sync issues.
  raw_headers  JSONB       NOT NULL DEFAULT '{}'::jsonb,

  fetched_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ── message_label ───────────────────────────────────────────────────────────
-- The junction that makes labels-not-folders work. A message has many labels;
-- a label has many messages.
CREATE TABLE message_label (
  id          TEXT PRIMARY KEY,       -- '<message_id>:<label_id>'
  account_id  TEXT NOT NULL REFERENCES account(id) ON DELETE CASCADE,
  message_id  TEXT NOT NULL REFERENCES message(id) ON DELETE CASCADE,
  label_id    TEXT NOT NULL REFERENCES label(id)   ON DELETE CASCADE,

  CONSTRAINT message_label_unique UNIQUE (message_id, label_id)
);
CREATE INDEX message_label_label_idx   ON message_label (label_id);
CREATE INDEX message_label_message_idx ON message_label (message_id);

-- ── attachment ──────────────────────────────────────────────────────────────
-- Metadata only. Blobs are content-addressed files on disk: zero-cache
-- replicates every replicated table into SQLite, and putting binaries in
-- Postgres would blow past the ~100GB practical ceiling and slow every sync.
CREATE TABLE attachment (
  id                    TEXT PRIMARY KEY,
  account_id            TEXT    NOT NULL REFERENCES account(id) ON DELETE CASCADE,
  message_id            TEXT    NOT NULL REFERENCES message(id) ON DELETE CASCADE,

  filename              TEXT    NOT NULL,
  mime_type             TEXT    NOT NULL DEFAULT 'application/octet-stream',
  size_bytes            INTEGER NOT NULL DEFAULT 0,

  -- Inline images referenced by cid: URLs in html_body.
  content_id            TEXT,
  is_inline             BOOLEAN NOT NULL DEFAULT FALSE,

  remote_attachment_id  TEXT,
  -- SHA-256 of the content; also the on-disk filename. Deduplicates the same
  -- attachment across messages and accounts.
  content_hash          TEXT,
  -- NULL until downloaded. Attachments are fetched lazily.
  local_path            TEXT,
  downloaded_at         TIMESTAMPTZ
);
CREATE INDEX attachment_message_idx ON attachment (message_id);

-- ── outbox ──────────────────────────────────────────────────────────────────
-- The transactional outbox. Zero mutators must never perform network I/O —
-- they are fast, local, transactional Postgres operations. So a mutator writes
-- the user-visible state change AND a row here in the same transaction; the
-- C++ engine drains this table and performs the actual Gmail call.
--
-- This is what makes optimistic UI correct: the UI updates instantly, and the
-- remote effect is durable, retryable and idempotent even across a crash.
CREATE TABLE outbox (
  id               TEXT          PRIMARY KEY,
  account_id       TEXT          NOT NULL REFERENCES account(id) ON DELETE CASCADE,

  op               outbox_op     NOT NULL,
  -- Operation-specific arguments, e.g.
  -- {"messageIds": [...], "addLabelIds": [...], "removeLabelIds": ["INBOX"]}
  payload          JSONB         NOT NULL,

  status           outbox_status NOT NULL DEFAULT 'pending',
  attempts         INTEGER       NOT NULL DEFAULT 0,
  last_error       TEXT,

  -- Deduplicates retries from the client. Two mutations with the same key
  -- collapse into one remote call.
  idempotency_key  TEXT          NOT NULL UNIQUE,

  created_at       TIMESTAMPTZ   NOT NULL DEFAULT now(),
  updated_at       TIMESTAMPTZ   NOT NULL DEFAULT now()
);
-- The engine's claim query: oldest pending work first.
CREATE INDEX outbox_pending_idx ON outbox (status, created_at) WHERE status = 'pending';

-- ── Counter maintenance ─────────────────────────────────────────────────────
-- Keeps label.unread_count / label.total_count honest.
--
-- Implemented as triggers rather than in application code because there are two
-- independent writers (the C++ sync engine and Zero's server-side mutators).
-- A trigger is the only layer that observes both, so it is the only place the
-- counter cannot drift.
--
-- NOTE: during the initial full backfill of a large mailbox, these fire once
-- per row. Phase 3 will disable them for the bulk load and recompute counts
-- once at the end.

CREATE FUNCTION label_counts_on_link() RETURNS TRIGGER AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    UPDATE label SET
      total_count  = total_count + 1,
      unread_count = unread_count
        + (SELECT CASE WHEN m.is_read THEN 0 ELSE 1 END
           FROM message m WHERE m.id = NEW.message_id)
    WHERE id = NEW.label_id;
    RETURN NEW;
  ELSE
    UPDATE label SET
      total_count  = GREATEST(total_count - 1, 0),
      unread_count = GREATEST(unread_count
        - (SELECT CASE WHEN m.is_read THEN 0 ELSE 1 END
           FROM message m WHERE m.id = OLD.message_id), 0)
    WHERE id = OLD.label_id;
    RETURN OLD;
  END IF;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER message_label_counts
  AFTER INSERT OR DELETE ON message_label
  FOR EACH ROW EXECUTE FUNCTION label_counts_on_link();

-- Read/unread transitions have to move the counter on every label the message
-- currently carries, plus its thread.
CREATE FUNCTION label_counts_on_read_change() RETURNS TRIGGER AS $$
DECLARE
  delta INTEGER;
BEGIN
  IF NEW.is_read = OLD.is_read THEN
    RETURN NEW;
  END IF;
  delta := CASE WHEN NEW.is_read THEN -1 ELSE 1 END;

  UPDATE label SET unread_count = GREATEST(unread_count + delta, 0)
  WHERE id IN (SELECT label_id FROM message_label WHERE message_id = NEW.id);

  UPDATE thread SET unread_count = GREATEST(unread_count + delta, 0)
  WHERE id = NEW.thread_id;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER message_read_counts
  AFTER UPDATE OF is_read ON message
  FOR EACH ROW EXECUTE FUNCTION label_counts_on_read_change();

COMMIT;
