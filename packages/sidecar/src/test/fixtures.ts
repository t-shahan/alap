/**
 * Test fixtures.
 *
 * Two isolation strategies, used for two different kinds of test:
 *
 *   `withRollback` — wraps a test in a Postgres transaction that is ALWAYS
 *     rolled back. Nothing escapes, nothing needs cleaning up, and tests can
 *     run against a database that already has dev seed data in it. Used for
 *     schema- and trigger-level tests.
 *
 *   `withAccount` — creates a uniquely-named account, runs the test, then
 *     deletes it (ON DELETE CASCADE clears everything beneath). Needed for
 *     integration tests that go through Zero, because those commit for real
 *     and must be visible to zero-cache's replication stream.
 *
 * Both give each test its own account ID, so tests never collide with the dev
 * seed or with each other, even running against the same database.
 */

import pg from 'pg'
import {labelId, messageId, messageLabelId, threadId} from '@mailapp/shared/ids'

const connectionString = process.env.ZERO_UPSTREAM_DB
if (!connectionString) {
  throw new Error('ZERO_UPSTREAM_DB is not set — run tests with `npm test` so .env is loaded')
}

/** Standard Gmail system labels every test account gets. */
export const SYSTEM_LABELS = ['INBOX', 'STARRED', 'UNREAD', 'DRAFT'] as const

/** A fresh, collision-proof account id per test. */
export const uniqueAccountId = (): string => `acct_test_${crypto.randomUUID().slice(0, 8)}`

/** Anything that can run a query — a Client or a Pool both satisfy this. */
export type Queryable = {
  query: (text: string, values?: readonly unknown[]) => Promise<pg.QueryResult>
}

/**
 * Runs `fn` inside a transaction that is always rolled back.
 *
 * Note the rollback happens even when `fn` succeeds — that is the point. The
 * database is left byte-identical to how it started.
 */
export async function withRollback<T>(fn: (db: Queryable) => Promise<T>): Promise<T> {
  const client = new pg.Client({connectionString})
  await client.connect()
  try {
    await client.query('BEGIN')
    return await fn(client)
  } finally {
    await client.query('ROLLBACK').catch(() => {})
    await client.end()
  }
}

/**
 * Creates a committed, uniquely-named account and guarantees its removal.
 *
 * Unlike `withRollback`, these writes are real and will replicate. Use only
 * where that is required — integration tests driving a Zero client.
 */
export async function withAccount<T>(
  fn: (db: Queryable, accountId: string) => Promise<T>,
): Promise<T> {
  const client = new pg.Client({connectionString})
  await client.connect()
  const accountId = uniqueAccountId()
  try {
    await seedAccount(client, accountId)
    return await fn(client, accountId)
  } finally {
    await client.query('DELETE FROM account WHERE id = $1', [accountId]).catch(() => {})
    await client.end()
  }
}

/** Inserts an account plus the standard system labels. */
export async function seedAccount(db: Queryable, accountId: string): Promise<void> {
  await db.query(
    `INSERT INTO account (id, email_address, display_name, provider)
     VALUES ($1, $2, 'Test', 'gmail')`,
    [accountId, `${accountId}@test.example`],
  )
  for (const [i, remoteId] of SYSTEM_LABELS.entries()) {
    await db.query(
      `INSERT INTO label (id, account_id, remote_id, name, kind, sort_order)
       VALUES ($1, $2, $3, $4, 'system', $5)`,
      [labelId(accountId, remoteId), accountId, remoteId, remoteId, i],
    )
  }
}

export type SeededThread = {
  readonly threadId: string
  readonly messageIds: readonly string[]
}

/**
 * Inserts a thread with `messageCount` messages, each linked to `labels`.
 *
 * Returns the generated IDs so tests can assert against them without
 * re-deriving the ID format.
 */
export async function seedThread(
  db: Queryable,
  accountId: string,
  opts: {
    readonly remoteId: string
    readonly labels: readonly string[]
    readonly isRead?: boolean
    readonly messageCount?: number
  },
): Promise<SeededThread> {
  const {remoteId, labels, isRead = false, messageCount = 1} = opts
  const tid = threadId(accountId, remoteId)
  const now = new Date()

  await db.query(
    `INSERT INTO thread
       (id, account_id, remote_thread_id, subject, snippet, participants,
        last_message_at, message_count, unread_count)
     VALUES ($1,$2,$3,$4,'',$5,$6,$7,$8)`,
    [
      tid,
      accountId,
      remoteId,
      `Subject ${remoteId}`,
      JSON.stringify([{name: 'Sender', email: 'sender@test.example'}]),
      now,
      messageCount,
      isRead ? 0 : messageCount,
    ],
  )

  const messageIds: string[] = []
  for (let i = 0; i < messageCount; i++) {
    const mid = messageId(accountId, `${remoteId}_m${i}`)
    messageIds.push(mid)
    await db.query(
      `INSERT INTO message
         (id, account_id, thread_id, remote_message_id, from_name, from_email,
          subject, snippet, sent_at, is_read)
       VALUES ($1,$2,$3,$4,'Sender','sender@test.example',$5,'',$6,$7)`,
      [mid, accountId, tid, `${remoteId}_m${i}`, `Subject ${remoteId}`, now, isRead],
    )
    for (const remoteLabel of labels) {
      const lid = labelId(accountId, remoteLabel)
      await db.query(
        `INSERT INTO message_label (id, account_id, message_id, label_id)
         VALUES ($1,$2,$3,$4)`,
        [messageLabelId(mid, lid), accountId, mid, lid],
      )
    }
  }

  return {threadId: tid, messageIds}
}

/** Reads a label's maintained counters. */
export async function labelCounts(
  db: Queryable,
  accountId: string,
  remoteLabel: string,
): Promise<{unread: number; total: number}> {
  const {rows} = await db.query(
    `SELECT unread_count::int AS unread, total_count::int AS total
     FROM label WHERE id = $1`,
    [labelId(accountId, remoteLabel)],
  )
  const row = rows[0]
  if (!row) throw new Error(`no label ${remoteLabel} for ${accountId}`)
  return {unread: row.unread, total: row.total}
}
