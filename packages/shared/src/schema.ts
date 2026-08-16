/**
 * Zero schema — the typed mirror of `migrations/0001_init.sql`.
 *
 * This file does two jobs:
 *   1. Gives ZQL queries full type safety end-to-end.
 *   2. Declares first-class relationships, so `.related('messages')` works
 *      without hand-written joins.
 *
 * Two mappings to keep in mind when reading this against the SQL:
 *   - Postgres `timestamptz` becomes `number()` here — epoch milliseconds in
 *     TypeScript, NOT a Date object.
 *   - Postgres is snake_case, TypeScript is camelCase. `.from()` bridges the
 *     two, so nothing downstream has to think about it.
 */

import {
  boolean,
  createBuilder,
  createSchema,
  enumeration,
  json,
  number,
  relationships,
  string,
  table,
} from '@rocicorp/zero'
import type {ReadonlyJSONValue} from '@rocicorp/zero'

/**
 * Shape of the `outbox.payload` column.
 *
 * Deliberately loose: each `outbox_op` carries different arguments, and the
 * authoritative validation happens in the mutator's Zod schema rather than
 * here. `json<T>()` constrains T to JSON-compatible types, so `unknown` is not
 * usable as the value type.
 */
export type JsonObject = Readonly<Record<string, ReadonlyJSONValue>>

/** A mail participant as stored in the JSONB recipient columns. */
export type Participant = {
  readonly name: string
  readonly email: string
}

// ─── account ─────────────────────────────────────────────────────────────────
// Note the absence of any token field: OAuth refresh tokens live in the macOS
// Keychain, never in a replicated table.
const account = table('account')
  .columns({
    id: string(),
    emailAddress: string().from('email_address'),
    displayName: string().from('display_name'),
    provider: enumeration<'gmail' | 'imap'>(),
    color: string(),
    sortOrder: number().from('sort_order'),
    lastHistoryId: string().from('last_history_id').optional(),
    lastSyncedAt: number().from('last_synced_at').optional(),
    disconnectedAt: number().from('disconnected_at').optional(),
    createdAt: number().from('created_at'),
  })
  .primaryKey('id')

// ─── label ───────────────────────────────────────────────────────────────────
const label = table('label')
  .columns({
    id: string(),
    accountId: string().from('account_id'),
    remoteId: string().from('remote_id'),
    name: string(),
    kind: enumeration<'system' | 'user'>(),
    color: string().optional(),
    sortOrder: number().from('sort_order'),
    // Trigger-maintained. Read these directly for sidebar badges — ZQL has no
    // COUNT, so a live aggregate is not an option.
    unreadCount: number().from('unread_count'),
    totalCount: number().from('total_count'),
  })
  .primaryKey('id')

// ─── thread ──────────────────────────────────────────────────────────────────
const thread = table('thread')
  .columns({
    id: string(),
    accountId: string().from('account_id'),
    remoteThreadId: string().from('remote_thread_id'),
    subject: string(),
    snippet: string(),
    participants: json<readonly Participant[]>(),
    lastMessageAt: number().from('last_message_at'),
    messageCount: number().from('message_count'),
    unreadCount: number().from('unread_count'),
    hasAttachments: boolean().from('has_attachments'),
    isStarred: boolean().from('is_starred'),
    createdAt: number().from('created_at'),
    updatedAt: number().from('updated_at'),
  })
  .primaryKey('id')

// ─── message ─────────────────────────────────────────────────────────────────
// Metadata only — deliberately cheap to sync in bulk for the list view.
const message = table('message')
  .columns({
    id: string(),
    accountId: string().from('account_id'),
    threadId: string().from('thread_id'),
    remoteMessageId: string().from('remote_message_id'),
    rfc822MessageId: string().from('rfc822_message_id').optional(),
    fromName: string().from('from_name'),
    fromEmail: string().from('from_email'),
    toRecipients: json<readonly Participant[]>().from('to_recipients'),
    ccRecipients: json<readonly Participant[]>().from('cc_recipients'),
    bccRecipients: json<readonly Participant[]>().from('bcc_recipients'),
    subject: string(),
    snippet: string(),
    sentAt: number().from('sent_at'),
    isRead: boolean().from('is_read'),
    isStarred: boolean().from('is_starred'),
    isDraft: boolean().from('is_draft'),
    hasAttachments: boolean().from('has_attachments'),
    sizeBytes: number().from('size_bytes'),
    createdAt: number().from('created_at'),
  })
  .primaryKey('id')

// ─── messageBody ─────────────────────────────────────────────────────────────
// Separate table so the list view never drags HTML bodies across the wire.
// Only the reading-pane query pulls this in, via `.related('body')`.
const messageBody = table('messageBody')
  .from('message_body')
  .columns({
    messageId: string().from('message_id'),
    accountId: string().from('account_id'),
    textBody: string().from('text_body').optional(),
    htmlBody: string().from('html_body').optional(),
    rawHeaders: json<Record<string, string>>().from('raw_headers'),
    fetchedAt: number().from('fetched_at'),
  })
  .primaryKey('messageId')

// ─── messageLabel ────────────────────────────────────────────────────────────
// The junction table that makes labels-not-folders work.
const messageLabel = table('messageLabel')
  .from('message_label')
  .columns({
    id: string(),
    accountId: string().from('account_id'),
    messageId: string().from('message_id'),
    labelId: string().from('label_id'),
  })
  .primaryKey('id')

// ─── attachment ──────────────────────────────────────────────────────────────
const attachment = table('attachment')
  .columns({
    id: string(),
    accountId: string().from('account_id'),
    messageId: string().from('message_id'),
    filename: string(),
    mimeType: string().from('mime_type'),
    sizeBytes: number().from('size_bytes'),
    contentId: string().from('content_id').optional(),
    isInline: boolean().from('is_inline'),
    remoteAttachmentId: string().from('remote_attachment_id').optional(),
    contentHash: string().from('content_hash').optional(),
    // NULL until the blob has been downloaded to disk.
    localPath: string().from('local_path').optional(),
    downloadedAt: number().from('downloaded_at').optional(),
  })
  .primaryKey('id')

// ─── outbox ──────────────────────────────────────────────────────────────────
// Synced to the client on purpose: it is what lets the UI show "Sending…" or
// surface a failed remote operation, rather than silently diverging from Gmail.
const outbox = table('outbox')
  .columns({
    id: string(),
    accountId: string().from('account_id'),
    op: enumeration<'modify_labels' | 'mark_read' | 'send' | 'delete_forever'>(),
    payload: json<JsonObject>(),
    status: enumeration<'pending' | 'in_flight' | 'done' | 'failed'>(),
    attempts: number(),
    lastError: string().from('last_error').optional(),
    idempotencyKey: string().from('idempotency_key'),
    createdAt: number().from('created_at'),
    updatedAt: number().from('updated_at'),
  })
  .primaryKey('id')

// ─── Relationships ───────────────────────────────────────────────────────────

const accountRelationships = relationships(account, ({many}) => ({
  labels: many({sourceField: ['id'], destSchema: label, destField: ['accountId']}),
  threads: many({sourceField: ['id'], destSchema: thread, destField: ['accountId']}),
}))

const labelRelationships = relationships(label, ({one, many}) => ({
  account: one({sourceField: ['accountId'], destSchema: account, destField: ['id']}),
  // Many-to-many, hopping through the junction table. Zero supports exactly
  // two levels of chaining, which is all this needs.
  messages: many(
    {sourceField: ['id'], destSchema: messageLabel, destField: ['labelId']},
    {sourceField: ['messageId'], destSchema: message, destField: ['id']},
  ),
}))

const threadRelationships = relationships(thread, ({one, many}) => ({
  account: one({sourceField: ['accountId'], destSchema: account, destField: ['id']}),
  messages: many({sourceField: ['id'], destSchema: message, destField: ['threadId']}),
}))

const messageRelationships = relationships(message, ({one, many}) => ({
  account: one({sourceField: ['accountId'], destSchema: account, destField: ['id']}),
  thread: one({sourceField: ['threadId'], destSchema: thread, destField: ['id']}),
  // Pulled in only by the reading-pane query.
  body: one({sourceField: ['id'], destSchema: messageBody, destField: ['messageId']}),
  attachments: many({sourceField: ['id'], destSchema: attachment, destField: ['messageId']}),
  labels: many(
    {sourceField: ['id'], destSchema: messageLabel, destField: ['messageId']},
    {sourceField: ['labelId'], destSchema: label, destField: ['id']},
  ),
}))

const attachmentRelationships = relationships(attachment, ({one}) => ({
  message: one({sourceField: ['messageId'], destSchema: message, destField: ['id']}),
}))

const outboxRelationships = relationships(outbox, ({one}) => ({
  account: one({sourceField: ['accountId'], destSchema: account, destField: ['id']}),
}))

// ─── Schema ──────────────────────────────────────────────────────────────────

export const schema = createSchema({
  tables: [
    account,
    label,
    thread,
    message,
    messageBody,
    messageLabel,
    attachment,
    outbox,
  ],
  relationships: [
    accountRelationships,
    labelRelationships,
    threadRelationships,
    messageRelationships,
    attachmentRelationships,
    outboxRelationships,
  ],
})

export type Schema = typeof schema

/** Typed ZQL query builder. Import this anywhere you write a query. */
export const zql = createBuilder(schema)

// Registering the schema globally means Zero's APIs infer it automatically
// instead of needing an explicit type parameter at every call site.
declare module '@rocicorp/zero' {
  interface DefaultTypes {
    schema: Schema
  }
}
