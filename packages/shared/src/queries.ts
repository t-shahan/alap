/**
 * ZQL query definitions.
 *
 * Every query is defined once and runs in two places: optimistically on the
 * client against the local store, and authoritatively on the server (via the
 * `/api/query` endpoint) to produce the ZQL that zero-cache actually executes.
 * Clients never send raw ZQL — they send a query *name* plus arguments, which
 * is why every parameterised query needs a validator: those arguments arrive
 * from an untrusted client.
 */

import {defineQueries, defineQuery} from '@rocicorp/zero'
import {z} from 'zod'
import {zql} from './schema.ts'

/** Default page size for the thread list. */
const THREAD_PAGE_SIZE = 100

export const queries = defineQueries({
  accounts: {
    /** Every connected account, for the sidebar and account badges. */
    all: defineQuery(() => zql.account.orderBy('sortOrder', 'asc')),
  },

  labels: {
    /**
     * Sidebar labels with their unread badges.
     *
     * `unreadCount` is read straight off the row. ZQL has no aggregates, so
     * this is not a `COUNT(*)` — it is the denormalised column maintained by
     * the Postgres trigger. That is the whole reason the trigger exists.
     */
    forAccount: defineQuery(z.object({accountId: z.string()}), ({args: {accountId}}) =>
      zql.label.where('accountId', accountId).orderBy('sortOrder', 'asc'),
    ),

    /** All labels across all accounts, for the unified sidebar. */
    all: defineQuery(() => zql.label.orderBy('sortOrder', 'asc')),
  },

  threads: {
    /**
     * THE LIST VIEW QUERY.
     *
     * Note what this does *not* do: no `.related()` at all. It returns bare
     * `thread` rows and nothing else, because subject, snippet, participants
     * and counts are all denormalised onto the thread. No message rows, no
     * bodies, no attachment metadata crosses the wire to render the list.
     *
     * That is the single biggest lever on perceived speed — roughly 200 bytes
     * per row instead of tens of kilobytes.
     */
    inLabel: defineQuery(
      z.object({
        /**
         * The PROVIDER-side label name (`INBOX`, `STARRED`), not a row id.
         *
         * This used to take a composite row id like `acct_1|STARRED`, which
         * quietly broke the moment a second account existed: each account has
         * its own row for the same label, so a single id could only ever match
         * one mailbox and "Starred" would show half your mail. Matching on
         * remoteId is what makes one sidebar entry mean every account's copy
         * of that label — the same reasoning as `unifiedInbox`.
         */
        remoteId: z.string(),
        limit: z.number().int().positive().max(1000).optional(),
      }),
      ({args: {remoteId, limit}}) =>
        zql.thread
          // thread → messages → labels. Threads have no direct label link
          // because labels are per-message in Gmail: a thread is "in the
          // inbox" if *any* of its messages still carries INBOX.
          .whereExists('messages', m =>
            m.whereExists('labels', l => l.where('remoteId', remoteId)),
          )
          .orderBy('lastMessageAt', 'desc')
          .limit(limit ?? THREAD_PAGE_SIZE),
    ),

    /**
     * Unified inbox across every connected account.
     *
     * Filters on `remoteId` rather than `id`: each account has its own INBOX
     * label row (`acct_1|INBOX`, `acct_2|INBOX`), but they all share the
     * provider-side name.
     */
    unifiedInbox: defineQuery(
      z.object({limit: z.number().int().positive().max(1000).optional()}),
      ({args: {limit}}) =>
        zql.thread
          .whereExists('messages', m =>
            m.whereExists('labels', l => l.where('remoteId', 'INBOX')),
          )
          .orderBy('lastMessageAt', 'desc')
          .limit(limit ?? THREAD_PAGE_SIZE),
    ),

    /**
     * One account's inbox.
     *
     * The unified inbox is the primary way to read mail here — the whole point
     * of modelling labels rather than folders is that "Inbox" can mean every
     * account at once. This exists for the times that is not what you want:
     * checking what actually arrived on your work address, or confirming a
     * newly-connected mailbox synced.
     *
     * Still filtered to INBOX rather than returning everything, so it matches
     * what the unified view would show for that account and does not quietly
     * become an "all mail" list.
     */
    forAccount: defineQuery(
      z.object({
        accountId: z.string(),
        limit: z.number().int().positive().max(1000).optional(),
      }),
      ({args: {accountId, limit}}) =>
        zql.thread
          .where('accountId', accountId)
          .whereExists('messages', m =>
            m.whereExists('labels', l => l.where('remoteId', 'INBOX')),
          )
          .orderBy('lastMessageAt', 'desc')
          .limit(limit ?? THREAD_PAGE_SIZE),
    ),

    /**
     * THE READING PANE QUERY.
     *
     * The mirror image of `inLabel`: one thread, but fully hydrated —
     * messages in chronological order, each with its body, attachments and
     * labels. This is the only query that ever pulls `messageBody`, which is
     * why that table was split out in the first place.
     */
    detail: defineQuery(z.object({threadId: z.string()}), ({args: {threadId}}) =>
      zql.thread
        .where('id', threadId)
        .related('messages', m =>
          m
            .orderBy('sentAt', 'asc')
            .related('body')
            .related('attachments')
            .related('labels'),
        )
        .one(),
    ),

    /**
     * Archived mail — the design's "Archive" mailbox.
     *
     * Gmail has NO archive label. Archiving is the REMOVAL of INBOX, so this
     * is a negation: threads none of whose messages still carry INBOX. Trash
     * and spam are excluded so the mailbox means "filed", not "everything".
     */
    archived: defineQuery(
      z.object({limit: z.number().int().positive().max(1000).optional()}),
      ({args: {limit}}) =>
        zql.thread
          .where(({not, exists}) =>
            not(
              exists('messages', m =>
                m.whereExists('labels', l =>
                  l.where('remoteId', 'IN', ['INBOX', 'TRASH', 'SPAM']),
                ),
              ),
            ),
          )
          .orderBy('lastMessageAt', 'desc')
          .limit(limit ?? THREAD_PAGE_SIZE),
    ),

    /**
     * Unread smart filter.
     *
     * Reads the denormalised `unreadCount` rather than joining to the UNREAD
     * label — the column is maintained by the Postgres trigger and is far
     * cheaper than an existence check across messages.
     */
    unread: defineQuery(
      z.object({limit: z.number().int().positive().max(1000).optional()}),
      ({args: {limit}}) =>
        zql.thread
          .where('unreadCount', '>', 0)
          .orderBy('lastMessageAt', 'desc')
          .limit(limit ?? THREAD_PAGE_SIZE),
    ),

    /** Threads carrying at least one attachment. */
    withAttachments: defineQuery(
      z.object({limit: z.number().int().positive().max(1000).optional()}),
      ({args: {limit}}) =>
        zql.thread
          .where('hasAttachments', true)
          .orderBy('lastMessageAt', 'desc')
          .limit(limit ?? THREAD_PAGE_SIZE),
    ),

    /**
     * PRELOAD — what makes opening a thread instant.
     *
     * `threads.detail` is a *new* query every time the selection moves, so it
     * cannot be answered from the client's local cache and must round-trip to
     * zero-cache. That round trip is the ~1s delay before a body appears.
     *
     * Preloading the same shape for the visible list syncs those rows to the
     * client in advance, so the subsequent detail query resolves locally and
     * paints in a frame. Zero's `preload()` streams without materialising JS
     * objects, which is why this can cover far more than a screenful.
     *
     * Deliberately smaller than the list limit: the first 40 threads cover
     * essentially all arrow-key navigation before the user pauses, and syncing
     * every body would defeat the point of splitting message_body out.
     */
    preloadDetails: defineQuery(
      z.object({limit: z.number().int().positive().max(200).optional()}),
      ({args: {limit}}) =>
        zql.thread
          .whereExists('messages', m =>
            m.whereExists('labels', l => l.where('remoteId', 'INBOX')),
          )
          .orderBy('lastMessageAt', 'desc')
          .limit(limit ?? 40)
          .related('messages', m =>
            m.orderBy('sentAt', 'asc').related('body').related('attachments').related('labels'),
          ),
    ),

    /**
     * SEARCH — stage two of the two-stage pattern.
     *
     * ZQL has no full-text search, so the C++ engine's SQLite FTS5 index does
     * the matching and returns thread IDs. Feeding them back through ZQL keeps
     * the result set *reactive*: if a new mail arrives in a matching thread,
     * or someone marks one read, the search results update live. A plain FTS5
     * query would return a dead snapshot.
     */
    byIds: defineQuery(
      z.object({ids: z.array(z.string()).max(500)}),
      ({args: {ids}}) => zql.thread.where('id', 'IN', ids).orderBy('lastMessageAt', 'desc'),
    ),
  },

  outbox: {
    /**
     * In-flight and failed remote operations, for sync status in the UI.
     *
     * Surfacing this is what stops the app from silently diverging from Gmail:
     * if an archive fails permanently, the user finds out.
     */
    unresolved: defineQuery(() =>
      zql.outbox.where('status', 'IN', ['pending', 'in_flight', 'failed']).orderBy('createdAt', 'asc'),
    ),
  },
})
