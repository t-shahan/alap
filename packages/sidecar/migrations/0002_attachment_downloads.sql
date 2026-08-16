-- ─────────────────────────────────────────────────────────────────────────────
-- Attachment downloads.
--
-- The columns this needs (local_path, content_hash, downloaded_at) already
-- exist from 0001; what is missing is a way to ASK for a download. That goes
-- through the outbox like every other operation the engine performs, because
-- the engine owns all network I/O and mutators are forbidden from doing any.
--
-- A download is a read rather than a mutation, which makes it the odd one out
-- in this table. It is here anyway for three reasons: the app and the engine
-- share no other channel (they communicate only through Postgres), the outbox
-- already provides durable retry with attempt counting, and failures already
-- surface in the UI. Inventing a second mechanism to avoid a naming quibble
-- would cost more than it saved.
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TYPE outbox_op ADD VALUE IF NOT EXISTS 'download_attachment';

-- Downloads are requested by clicking, and clicking happens more than once.
-- A partial index over just the live rows keeps the drainer's claim query on
-- an index scan even if thousands of completed download rows accumulate.
CREATE INDEX IF NOT EXISTS outbox_live_idx
  ON outbox (account_id, created_at)
  WHERE status IN ('pending', 'in_flight');

-- Serving an attachment means finding it by content hash; deleting one means
-- knowing whether any other row still references the same blob. Both are hash
-- lookups, and without this they are sequential scans over every attachment.
CREATE INDEX IF NOT EXISTS attachment_content_hash_idx
  ON attachment (content_hash)
  WHERE content_hash IS NOT NULL;

-- ─────────────────────────────────────────────────────────────────────────────
-- Wake the engine the moment there is work.
--
-- The daemon otherwise learns about a new outbox row only when its poll
-- interval elapses. For an archive that is invisible. For "download this
-- attachment and show it to me", a wait of up to 30 seconds with no feedback is
-- indefensible — the user is sitting there.
--
-- NOTIFY is delivered on COMMIT, not on the statement, so the engine can never
-- be woken for a row it would not yet be able to see.
--
-- This is an optimisation, not a mechanism: the daemon still polls on a timer,
-- so a missed notification delays work rather than losing it.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION notify_outbox() RETURNS trigger AS $$
BEGIN
  -- Only pending rows represent work. Without this, the drainer's own
  -- transitions to in_flight/done/failed would each wake it again, and it
  -- would spin against itself.
  IF NEW.status = 'pending' THEN
    PERFORM pg_notify('outbox', NEW.account_id);
  END IF;
  RETURN NULL;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS outbox_notify ON outbox;
CREATE TRIGGER outbox_notify
  AFTER INSERT OR UPDATE OF status ON outbox
  FOR EACH ROW EXECUTE FUNCTION notify_outbox();
