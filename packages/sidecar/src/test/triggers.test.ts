/**
 * Counter-trigger tests.
 *
 * These run entirely inside rolled-back transactions, so they need no running
 * services beyond Postgres and leave no residue. They are the fast tier: every
 * case here would otherwise only surface as a wrong badge number in the UI.
 */

import assert from 'node:assert/strict'
import {describe, it} from 'node:test'
import {labelId, messageLabelId} from '@mailapp/shared/ids'
import {labelCounts, seedAccount, seedThread, uniqueAccountId, withRollback} from './fixtures.ts'

describe('label counter triggers', () => {
  it('increments total and unread when an unread message is labelled', async () => {
    await withRollback(async db => {
      // Arrange
      const account = uniqueAccountId()
      await seedAccount(db, account)

      // Act
      await seedThread(db, account, {remoteId: 't1', labels: ['INBOX'], isRead: false})

      // Assert
      assert.deepEqual(await labelCounts(db, account, 'INBOX'), {unread: 1, total: 1})
    })
  })

  it('increments total but not unread for an already-read message', async () => {
    await withRollback(async db => {
      const account = uniqueAccountId()
      await seedAccount(db, account)

      await seedThread(db, account, {remoteId: 't1', labels: ['INBOX'], isRead: true})

      assert.deepEqual(await labelCounts(db, account, 'INBOX'), {unread: 0, total: 1})
    })
  })

  it('decrements unread when a message is marked read', async () => {
    await withRollback(async db => {
      const account = uniqueAccountId()
      await seedAccount(db, account)
      const {messageIds} = await seedThread(db, account, {
        remoteId: 't1',
        labels: ['INBOX'],
        isRead: false,
      })

      await db.query('UPDATE message SET is_read = TRUE WHERE id = $1', [messageIds[0]])

      assert.deepEqual(await labelCounts(db, account, 'INBOX'), {unread: 0, total: 1})
    })
  })

  it('restores unread when a message is marked unread again', async () => {
    await withRollback(async db => {
      const account = uniqueAccountId()
      await seedAccount(db, account)
      const {messageIds} = await seedThread(db, account, {
        remoteId: 't1',
        labels: ['INBOX'],
        isRead: false,
      })

      await db.query('UPDATE message SET is_read = TRUE WHERE id = $1', [messageIds[0]])
      await db.query('UPDATE message SET is_read = FALSE WHERE id = $1', [messageIds[0]])

      assert.deepEqual(await labelCounts(db, account, 'INBOX'), {unread: 1, total: 1})
    })
  })

  it('does not move counters when is_read is written with an unchanged value', async () => {
    // Guards the `IF NEW.is_read = OLD.is_read THEN RETURN` early exit. Without
    // it, a no-op UPDATE (which sync engines emit constantly) would drift the
    // count on every pass.
    await withRollback(async db => {
      const account = uniqueAccountId()
      await seedAccount(db, account)
      const {messageIds} = await seedThread(db, account, {
        remoteId: 't1',
        labels: ['INBOX'],
        isRead: false,
      })

      await db.query('UPDATE message SET is_read = FALSE WHERE id = $1', [messageIds[0]])
      await db.query('UPDATE message SET is_read = FALSE WHERE id = $1', [messageIds[0]])

      assert.deepEqual(await labelCounts(db, account, 'INBOX'), {unread: 1, total: 1})
    })
  })

  it('decrements both counters when an unread message is archived', async () => {
    await withRollback(async db => {
      const account = uniqueAccountId()
      await seedAccount(db, account)
      const {messageIds} = await seedThread(db, account, {
        remoteId: 't1',
        labels: ['INBOX'],
        isRead: false,
      })

      // Archiving IS removing the INBOX label.
      await db.query('DELETE FROM message_label WHERE id = $1', [
        messageLabelId(messageIds[0]!, labelId(account, 'INBOX')),
      ])

      assert.deepEqual(await labelCounts(db, account, 'INBOX'), {unread: 0, total: 0})
    })
  })

  it('tracks each label independently for a multi-labelled message', async () => {
    await withRollback(async db => {
      const account = uniqueAccountId()
      await seedAccount(db, account)
      const {messageIds} = await seedThread(db, account, {
        remoteId: 't1',
        labels: ['INBOX', 'STARRED'],
        isRead: false,
      })

      assert.deepEqual(await labelCounts(db, account, 'INBOX'), {unread: 1, total: 1})
      assert.deepEqual(await labelCounts(db, account, 'STARRED'), {unread: 1, total: 1})

      // Archiving must not touch STARRED — the message stays starred.
      await db.query('DELETE FROM message_label WHERE id = $1', [
        messageLabelId(messageIds[0]!, labelId(account, 'INBOX')),
      ])

      assert.deepEqual(await labelCounts(db, account, 'INBOX'), {unread: 0, total: 0})
      assert.deepEqual(await labelCounts(db, account, 'STARRED'), {unread: 1, total: 1})
    })
  })

  it('marking read updates every label the message carries', async () => {
    await withRollback(async db => {
      const account = uniqueAccountId()
      await seedAccount(db, account)
      const {messageIds} = await seedThread(db, account, {
        remoteId: 't1',
        labels: ['INBOX', 'STARRED'],
        isRead: false,
      })

      await db.query('UPDATE message SET is_read = TRUE WHERE id = $1', [messageIds[0]])

      assert.deepEqual(await labelCounts(db, account, 'INBOX'), {unread: 0, total: 1})
      assert.deepEqual(await labelCounts(db, account, 'STARRED'), {unread: 0, total: 1})
    })
  })

  it('aggregates a multi-message thread correctly', async () => {
    await withRollback(async db => {
      const account = uniqueAccountId()
      await seedAccount(db, account)
      await seedThread(db, account, {
        remoteId: 't1',
        labels: ['INBOX'],
        isRead: false,
        messageCount: 3,
      })

      assert.deepEqual(await labelCounts(db, account, 'INBOX'), {unread: 3, total: 3})
    })
  })

  it('never drives a counter below zero', async () => {
    // The GREATEST(..., 0) guards. A counter that goes negative would render
    // as a nonsense badge and is worth failing loudly on.
    await withRollback(async db => {
      const account = uniqueAccountId()
      await seedAccount(db, account)
      const {messageIds} = await seedThread(db, account, {
        remoteId: 't1',
        labels: ['INBOX'],
        isRead: true,
      })

      // Corrupt the counter, then archive — the decrement must clamp.
      await db.query('UPDATE label SET total_count = 0 WHERE id = $1', [
        labelId(account, 'INBOX'),
      ])
      await db.query('DELETE FROM message_label WHERE id = $1', [
        messageLabelId(messageIds[0]!, labelId(account, 'INBOX')),
      ])

      const counts = await labelCounts(db, account, 'INBOX')
      assert.ok(counts.total >= 0, `total went negative: ${counts.total}`)
      assert.ok(counts.unread >= 0, `unread went negative: ${counts.unread}`)
    })
  })

  it('cascades cleanly when an account is deleted', async () => {
    await withRollback(async db => {
      const account = uniqueAccountId()
      await seedAccount(db, account)
      await seedThread(db, account, {remoteId: 't1', labels: ['INBOX'], messageCount: 2})

      await db.query('DELETE FROM account WHERE id = $1', [account])

      for (const table of ['label', 'thread', 'message', 'message_label']) {
        const {rows} = await db.query(
          `SELECT count(*)::int AS n FROM ${table} WHERE account_id = $1`,
          [account],
        )
        assert.equal(rows[0].n, 0, `${table} rows survived account delete`)
      }
    })
  })
})
