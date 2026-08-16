/**
 * Mutator integration tests.
 *
 * Unlike the trigger tests, these cannot use transaction rollback: the writes
 * have to commit so zero-cache's replication stream can see them. Isolation
 * instead comes from a disposable, uniquely-named account per test.
 *
 * These need the full stack running (Postgres, zero-cache, sidecar) and are
 * skipped automatically when it is not up, so `npm test` stays useful for the
 * fast tier alone.
 */

import assert from 'node:assert/strict'
import {after, before, describe, it} from 'node:test'
import {Zero} from '@rocicorp/zero'
import {labelId} from '@mailapp/shared/ids'
import {mutators} from '@mailapp/shared/mutators'
import {queries} from '@mailapp/shared/queries'
import {schema} from '@mailapp/shared/schema'
import {labelCounts, seedThread, withAccount} from './fixtures.ts'

const CACHE_URL = 'http://localhost:4848'
const SIDECAR_URL = 'http://localhost:3000'

/** Replication is async; poll rather than guess a sleep duration. */
async function eventually<T>(
  fn: () => Promise<T>,
  predicate: (value: T) => boolean,
  {timeoutMs = 8000, intervalMs = 100} = {},
): Promise<T> {
  const deadline = Date.now() + timeoutMs
  let last: T = await fn()
  while (Date.now() < deadline) {
    if (predicate(last)) return last
    await new Promise(r => setTimeout(r, intervalMs))
    last = await fn()
  }
  throw new Error(`condition not met within ${timeoutMs}ms; last value: ${JSON.stringify(last)}`)
}

/**
 * Awaits a mutation all the way to the server.
 *
 * `zero.mutate()` does NOT return a Promise — it returns `{client, server}`.
 * Awaiting the call itself resolves immediately and tells you nothing, which
 * makes tests silently racy. Always await `.server` when asserting on
 * committed state.
 */
async function applied(write: {
  client: Promise<{type: string; error?: unknown}>
  server: Promise<{type: string; error?: unknown}>
}): Promise<void> {
  const clientRes = await write.client
  if (clientRes.type === 'error') {
    throw new Error('mutator failed on client', {cause: clientRes.error})
  }
  const serverRes = await write.server
  if (serverRes.type === 'error') {
    throw new Error('mutator failed on server', {cause: serverRes.error})
  }
}

async function stackIsUp(): Promise<boolean> {
  const probe = async (url: string) => {
    try {
      const res = await fetch(url, {signal: AbortSignal.timeout(1500)})
      return res.ok
    } catch {
      return false
    }
  }
  const [cache, sidecar] = await Promise.all([
    probe(`${CACHE_URL}/keepalive`),
    probe(`${SIDECAR_URL}/health`),
  ])
  return cache && sidecar
}

/**
 * Factory exists so the client's type can be INFERRED. Annotating
 * `Zero<typeof schema, typeof mutators>` by hand does not typecheck: the
 * generic expects `CustomMutatorDefs`, not the `MutatorRegistry` that
 * `defineMutators` returns.
 */
const createClient = () =>
  new Zero({cacheURL: CACHE_URL, schema, mutators, kvStore: 'mem'})

describe('mutators (integration)', {concurrency: false}, async () => {
  let up = false
  let zero: ReturnType<typeof createClient> | undefined

  before(async () => {
    up = await stackIsUp()
    if (!up) return
    zero = createClient()
  })

  after(async () => {
    await zero?.close()
  })

  it('archive removes INBOX and writes exactly one outbox row', async t => {
    if (!up) return t.skip('stack not running (need zero-cache + sidecar)')

    await withAccount(async (db, accountId) => {
      // Arrange
      const {threadId: tid} = await seedThread(db, accountId, {
        remoteId: 'arch1',
        labels: ['INBOX'],
        isRead: false,
      })
      await eventually(
        () => zero!.run(queries.threads.detail({threadId: tid}), {type: 'complete'}),
        t => t !== undefined,
      )

      // Act
      const idempotencyKey = crypto.randomUUID()
      await applied(
        zero!.mutate(
          mutators.threads.archive({
            accountId,
            threadId: tid,
            inboxLabelId: labelId(accountId, 'INBOX'),
            idempotencyKey,
          }),
        ),
      )

      // Assert — the label link is gone
      await eventually(
        async () =>
          (
            await db.query(
              `SELECT count(*)::int AS n FROM message_label ml
               JOIN message m ON m.id = ml.message_id
               WHERE m.thread_id = $1 AND ml.label_id = $2`,
              [tid, labelId(accountId, 'INBOX')],
            )
          ).rows[0].n,
        n => n === 0,
      )

      // ...and the counters followed, via the trigger
      assert.deepEqual(await labelCounts(db, accountId, 'INBOX'), {unread: 0, total: 0})

      // ...and the remote intent was recorded in the SAME transaction
      const {rows} = await db.query(
        `SELECT op, status, payload FROM outbox WHERE idempotency_key = $1`,
        [idempotencyKey],
      )
      assert.equal(rows.length, 1, 'expected exactly one outbox row')
      assert.equal(rows[0].op, 'modify_labels')
      assert.equal(rows[0].status, 'pending')
      assert.deepEqual(rows[0].payload.removeLabelIds, ['INBOX'])
    })
  })

  it('setRead is a no-op when the thread is already read', async t => {
    if (!up) return t.skip('stack not running')

    await withAccount(async (db, accountId) => {
      const {threadId: tid} = await seedThread(db, accountId, {
        remoteId: 'read1',
        labels: ['INBOX'],
        isRead: true,
      })
      await eventually(
        () => zero!.run(queries.threads.detail({threadId: tid}), {type: 'complete'}),
        t => t !== undefined,
      )

      await applied(
        zero!.mutate(
          mutators.threads.setRead({
            accountId,
            threadId: tid,
            isRead: true,
            idempotencyKey: crypto.randomUUID(),
          }),
        ),
      )

      // No pointless Gmail call should be queued for a state that already holds.
      const {rows} = await db.query(
        `SELECT count(*)::int AS n FROM outbox WHERE account_id = $1`,
        [accountId],
      )
      assert.equal(rows[0].n, 0, 'expected no outbox row for a no-op setRead')
    })
  })

  it('the same idempotency key cannot produce two outbox rows', async t => {
    if (!up) return t.skip('stack not running')

    await withAccount(async (db, accountId) => {
      const {threadId: tid} = await seedThread(db, accountId, {
        remoteId: 'idem1',
        labels: ['INBOX'],
        isRead: false,
      })
      await eventually(
        () => zero!.run(queries.threads.detail({threadId: tid}), {type: 'complete'}),
        t => t !== undefined,
      )

      const idempotencyKey = crypto.randomUUID()
      const archive = () =>
        applied(
          zero!.mutate(
            mutators.threads.archive({
              accountId,
              threadId: tid,
              inboxLabelId: labelId(accountId, 'INBOX'),
              idempotencyKey,
            }),
          ),
        )

      await archive()
      // A retry with the same key must collapse onto the same row rather than
      // sending Gmail the same batchModify twice. The second attempt may well
      // reject on the unique constraint — that is the dedupe working.
      await archive().catch(() => {})

      const {rows} = await db.query(
        `SELECT count(*)::int AS n FROM outbox WHERE idempotency_key = $1`,
        [idempotencyKey],
      )
      assert.equal(rows[0].n, 1, 'idempotency key should dedupe to one row')
    })
  })
})
