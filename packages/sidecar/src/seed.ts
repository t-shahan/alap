/**
 * Development seed data.
 *
 * Writes plain SQL through `pg` — deliberately NOT through Zero mutators —
 * because that is exactly what the C++ engine will do in Phase 3. The engine
 * is a producer into Postgres; it has no Zero dependency. Seeding the same way
 * means any UI built against this data is already validated against the real
 * ingestion path.
 *
 *   npm run seed --workspace=@mailapp/sidecar
 */

import pg from 'pg'
import {labelId, messageId, messageLabelId, threadId} from '@mailapp/shared/ids'

const connectionString = process.env.ZERO_UPSTREAM_DB
if (!connectionString) {
  throw new Error('ZERO_UPSTREAM_DB is not set — did you source .env?')
}

const ACCOUNT_ID = 'acct_dev'

type SeedThread = {
  readonly remoteId: string
  readonly subject: string
  readonly snippet: string
  readonly from: readonly [name: string, email: string]
  readonly labels: readonly string[]
  readonly isRead: boolean
  readonly isStarred: boolean
  /** Minutes ago the newest message arrived. */
  readonly ageMinutes: number
}

const THREADS: readonly SeedThread[] = [
  {
    remoteId: 't_001',
    subject: 'Design review moved to Thursday',
    snippet: 'Pushing this a day so Priya can join — same room, same time.',
    from: ['Ada Okonkwo', 'ada@example.com'],
    labels: ['INBOX'],
    isRead: false,
    isStarred: false,
    ageMinutes: 4,
  },
  {
    remoteId: 't_002',
    subject: 'Q3 infrastructure spend',
    snippet: 'Attaching the breakdown. The Postgres line is the one to look at.',
    from: ['Marcus Bell', 'marcus@example.com'],
    labels: ['INBOX', 'STARRED'],
    isRead: false,
    isStarred: true,
    ageMinutes: 47,
  },
  {
    remoteId: 't_003',
    subject: 'Re: onboarding docs feedback',
    snippet: 'Mostly small stuff. The install section needs a rewrite though.',
    from: ['Jun Watanabe', 'jun@example.com'],
    labels: ['INBOX'],
    isRead: true,
    isStarred: false,
    ageMinutes: 190,
  },
  {
    remoteId: 't_004',
    subject: 'Your receipt from Foundry Coffee',
    snippet: 'Order #4471 — 1x Filter, 1x Croissant. Thanks for stopping by.',
    from: ['Foundry Coffee', 'receipts@foundry.example'],
    labels: ['INBOX'],
    isRead: true,
    isStarred: false,
    ageMinutes: 400,
  },
  {
    remoteId: 't_005',
    subject: 'Draft: incident writeup',
    snippet: 'First pass at the timeline. Still missing the rollback window.',
    from: ['You', 'dev@example.com'],
    labels: ['DRAFT'],
    isRead: true,
    isStarred: false,
    ageMinutes: 1500,
  },
  {
    remoteId: 't_006',
    subject: 'Conference talk accepted',
    snippet: 'Congratulations — your submission was selected for the systems track.',
    from: ['Program Committee', 'talks@conf.example'],
    labels: ['INBOX', 'STARRED'],
    isRead: true,
    isStarred: true,
    ageMinutes: 2900,
  },
]

const LABELS: readonly (readonly [remoteId: string, name: string, kind: 'system' | 'user'])[] = [
  ['INBOX', 'Inbox', 'system'],
  ['STARRED', 'Starred', 'system'],
  ['SENT', 'Sent', 'system'],
  ['DRAFT', 'Drafts', 'system'],
  ['ARCHIVE', 'Archive', 'system'],
]

async function main(): Promise<void> {
  const client = new pg.Client({connectionString})
  await client.connect()

  try {
    await client.query('BEGIN')

    // Idempotent: wipe and rebuild the dev account. ON DELETE CASCADE clears
    // every dependent row, so re-running this is always safe.
    await client.query('DELETE FROM account WHERE id = $1', [ACCOUNT_ID])

    await client.query(
      `INSERT INTO account (id, email_address, display_name, provider, color, sort_order)
       VALUES ($1, $2, $3, 'gmail', $4, 0)`,
      [ACCOUNT_ID, 'dev@example.com', 'Dev Account', '#E4572E'],
    )

    for (const [i, [remoteId, name, kind]] of LABELS.entries()) {
      await client.query(
        `INSERT INTO label (id, account_id, remote_id, name, kind, sort_order)
         VALUES ($1, $2, $3, $4, $5, $6)`,
        [labelId(ACCOUNT_ID, remoteId), ACCOUNT_ID, remoteId, name, kind, i],
      )
    }

    for (const t of THREADS) {
      const tid = threadId(ACCOUNT_ID, t.remoteId)
      const mid = messageId(ACCOUNT_ID, `m_${t.remoteId}`)
      const sentAt = new Date(Date.now() - t.ageMinutes * 60_000)
      const [fromName, fromEmail] = t.from

      await client.query(
        `INSERT INTO thread
           (id, account_id, remote_thread_id, subject, snippet, participants,
            last_message_at, message_count, unread_count, is_starred)
         VALUES ($1,$2,$3,$4,$5,$6,$7,1,$8,$9)`,
        [
          tid,
          ACCOUNT_ID,
          t.remoteId,
          t.subject,
          t.snippet,
          JSON.stringify([{name: fromName, email: fromEmail}]),
          sentAt,
          t.isRead ? 0 : 1,
          t.isStarred,
        ],
      )

      await client.query(
        `INSERT INTO message
           (id, account_id, thread_id, remote_message_id, rfc822_message_id,
            from_name, from_email, to_recipients, subject, snippet, sent_at,
            is_read, is_starred, is_draft, size_bytes)
         VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15)`,
        [
          mid,
          ACCOUNT_ID,
          tid,
          `m_${t.remoteId}`,
          `<${t.remoteId}@example.com>`,
          fromName,
          fromEmail,
          JSON.stringify([{name: 'Dev Account', email: 'dev@example.com'}]),
          t.subject,
          t.snippet,
          sentAt,
          t.isRead,
          t.isStarred,
          t.labels.includes('DRAFT'),
          2048,
        ],
      )

      await client.query(
        `INSERT INTO message_body (message_id, account_id, text_body, html_body, raw_headers)
         VALUES ($1,$2,$3,$4,$5)`,
        [
          mid,
          ACCOUNT_ID,
          `${t.snippet}\n\n— ${fromName}`,
          `<p>${t.snippet}</p><p>— ${fromName}</p>`,
          JSON.stringify({From: `${fromName} <${fromEmail}>`, Subject: t.subject}),
        ],
      )

      // The junction rows. Inserting these fires the counter trigger, so
      // label.unread_count is correct without the seed script computing it.
      for (const remoteLabel of t.labels) {
        const lid = labelId(ACCOUNT_ID, remoteLabel)
        await client.query(
          `INSERT INTO message_label (id, account_id, message_id, label_id)
           VALUES ($1,$2,$3,$4)`,
          [messageLabelId(mid, lid), ACCOUNT_ID, mid, lid],
        )
      }
    }

    await client.query('COMMIT')

    const {rows} = await client.query(
      `SELECT name, unread_count, total_count FROM label
       WHERE account_id = $1 AND total_count > 0 ORDER BY sort_order`,
      [ACCOUNT_ID],
    )
    console.log(`seeded ${THREADS.length} threads into ${ACCOUNT_ID}`)
    console.table(rows)
  } catch (err) {
    await client.query('ROLLBACK')
    throw err
  } finally {
    await client.end()
  }
}

await main()
