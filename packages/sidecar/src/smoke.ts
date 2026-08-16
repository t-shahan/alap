/**
 * End-to-end smoke test for the full Zero loop.
 *
 * Drives a real Zero client against the running stack and asserts that a
 * mutator's two effects — the user-visible state change AND its outbox row —
 * both land in Postgres, in one transaction.
 *
 * Beyond verifying the loop, this doubles as a de-risking exercise for Phase 4:
 * it proves the Zero client runs in a plain non-browser JS runtime with
 * `kvStore: 'mem'`, which is the same core the WKWebView bridge will host.
 *
 * Requires zero-cache (:4848) and the sidecar (:3000) to be running.
 *
 *   npm run smoke --workspace=@mailapp/sidecar
 */

import {Zero} from '@rocicorp/zero'
import pg from 'pg'
import {labelId, threadId} from '@mailapp/shared/ids'
import {mutators} from '@mailapp/shared/mutators'
import {queries} from '@mailapp/shared/queries'
import {schema} from '@mailapp/shared/schema'

const ACCOUNT_ID = 'acct_dev'
const connectionString = process.env.ZERO_UPSTREAM_DB
if (!connectionString) {
  throw new Error('ZERO_UPSTREAM_DB is not set')
}

let failures = 0
function check(label: string, actual: unknown, expected: unknown): void {
  const ok = JSON.stringify(actual) === JSON.stringify(expected)
  if (!ok) failures++
  console.log(`  ${ok ? '✓' : '✗'} ${label}${ok ? '' : ` — got ${JSON.stringify(actual)}, want ${JSON.stringify(expected)}`}`)
}

async function main(): Promise<void> {
  const zero = new Zero({
    cacheURL: 'http://localhost:4848',
    schema,
    mutators,
    // No IndexedDB outside a browser. The React Native adapters prove this hook
    // can be backed by native SQLite instead — that is the same seam Phase 4
    // would use if we ever move off WKWebView.
    kvStore: 'mem',
  })

  console.log('\n── reading through Zero (not SQL) ──')

  // `{type: 'complete'}` waits for the server's authoritative result rather
  // than returning only what is already cached locally.
  const threads = await zero.run(queries.threads.unifiedInbox({}), {type: 'complete'})
  console.log(`  inbox threads: ${threads.length}`)
  for (const t of threads) {
    console.log(`    ${t.unreadCount > 0 ? '●' : ' '} ${t.subject}`)
  }
  check('unified inbox returns 5 threads', threads.length, 5)

  const labels = await zero.run(queries.labels.forAccount({accountId: ACCOUNT_ID}), {
    type: 'complete',
  })
  const inbox = labels.find(l => l.remoteId === 'INBOX')
  check('inbox unread badge', inbox?.unreadCount, 2)

  // Reading-pane query: the only one that pulls bodies.
  const target = threads.find(t => t.remoteThreadId === 't_001')
  const detail = await zero.run(queries.threads.detail({threadId: target!.id}), {
    type: 'complete',
  })
  check('detail hydrates 1 message', detail?.messages.length, 1)
  check('detail includes body', typeof detail?.messages[0]?.body?.htmlBody, 'string')

  console.log('\n── archiving through a mutator ──')

  const tid = threadId(ACCOUNT_ID, 't_001')
  const idempotencyKey = crypto.randomUUID()

  await zero.mutate(
    mutators.threads.archive({
      accountId: ACCOUNT_ID,
      threadId: tid,
      inboxLabelId: labelId(ACCOUNT_ID, 'INBOX'),
      idempotencyKey,
    }),
  )

  // Give the server round-trip and replication a moment to settle.
  await new Promise(r => setTimeout(r, 1500))

  const after = await zero.run(queries.threads.unifiedInbox({}), {type: 'complete'})
  check('thread left the inbox', after.length, 4)

  const labelsAfter = await zero.run(queries.labels.forAccount({accountId: ACCOUNT_ID}), {
    type: 'complete',
  })
  const inboxAfter = labelsAfter.find(l => l.remoteId === 'INBOX')
  check('inbox total decremented by trigger', inboxAfter?.totalCount, 4)
  check('inbox unread decremented by trigger', inboxAfter?.unreadCount, 1)

  console.log('\n── verifying Postgres directly (the C++ engine\'s view) ──')

  const client = new pg.Client({connectionString})
  await client.connect()
  try {
    const {rows: links} = await client.query(
      `SELECT count(*)::int AS n FROM message_label ml
       JOIN message m ON m.id = ml.message_id
       WHERE m.thread_id = $1 AND ml.label_id = $2`,
      [tid, labelId(ACCOUNT_ID, 'INBOX')],
    )
    check('INBOX junction rows removed', links[0].n, 0)

    const {rows: outbox} = await client.query(
      `SELECT op, status, payload FROM outbox WHERE idempotency_key = $1`,
      [idempotencyKey],
    )
    check('exactly one outbox row written', outbox.length, 1)
    check('outbox op', outbox[0]?.op, 'modify_labels')
    check('outbox status', outbox[0]?.status, 'pending')
    check('outbox removes INBOX', outbox[0]?.payload?.removeLabelIds, ['INBOX'])
    console.log(`    payload: ${JSON.stringify(outbox[0]?.payload)}`)
  } finally {
    await client.end()
  }

  await zero.close()

  console.log(failures === 0 ? '\n✓ all checks passed\n' : `\n✗ ${failures} check(s) failed\n`)
  process.exit(failures === 0 ? 0 : 1)
}

await main()
