-- Attachment rows were keyed on Gmail's `attachmentId`, which is EPHEMERAL:
-- fetching the same message twice seconds apart returns a different id for the
-- same part. With it in the primary key every sync INSERTed instead of
-- updating, so a message accumulated one row per sync ever run against it.
--
-- Measured before this migration: 7,350 surplus rows of 9,175 (80%), across
-- 967 messages, worst case 15 copies of a single file.
--
-- The id is now a digest of what actually identifies a part — filename, size
-- and Content-ID — matching mailengine::ids::attachment(). Keep the two in
-- step: the separator is Unit Separator (chr(31)) because Postgres text cannot
-- hold a NUL, and the digest is truncated to 32 hex characters.

BEGIN;

-- 1. Collapse duplicates. Prefer a row whose bytes are already on disk; among
--    equals, keep the lowest id so the choice is deterministic and re-running
--    this migration is a no-op.
DELETE FROM attachment a
USING attachment b
WHERE a.message_id = b.message_id
  AND a.filename = b.filename
  AND a.size_bytes = b.size_bytes
  AND COALESCE(a.content_id, '') = COALESCE(b.content_id, '')
  AND a.id <> b.id
  AND (
        (a.local_path IS NULL AND b.local_path IS NOT NULL)
     OR ((a.local_path IS NULL) = (b.local_path IS NULL) AND a.id > b.id)
      );

-- 2. Re-key the survivors so the next sync UPDATEs them rather than inserting
--    alongside them. Without this the new scheme would simply start a second
--    generation of duplicates.
UPDATE attachment
SET id = message_id || '|' || substr(
      encode(
        sha256(convert_to(
          filename || chr(31) || size_bytes::text || chr(31)
                   || COALESCE(content_id, ''), 'UTF8')),
        'hex'),
      1, 32);

COMMIT;
