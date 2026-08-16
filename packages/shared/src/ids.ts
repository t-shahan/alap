/**
 * Canonical row-ID construction.
 *
 * Every ID in this schema is a deterministic function of stable, provider-side
 * identifiers. That is what makes the C++ sync engine's writes idempotent:
 * re-fetching the same Gmail message always produces the same primary key, so
 * `INSERT ... ON CONFLICT DO UPDATE` is safe to retry after a crash or a
 * partial sync.
 *
 * IMPORTANT: the C++ engine constructs these same IDs independently. If you
 * change a format here, `engine/` must change in lockstep or the two writers
 * will produce duplicate rows that look identical to a human.
 */

/**
 * Separator between ID segments.
 *
 * `|` is chosen because it cannot appear in a Gmail message/thread/label ID
 * (which are base64url-ish) nor in our own account IDs. Using `:` would be
 * ambiguous, since composite IDs are themselves used as segments — e.g.
 * `acct_1:INBOX` as a label ID inside a message-label ID.
 */
export const ID_SEP = '|'

/** Stable ID for an account. Generated once at connect time, never derived. */
export const accountId = (uuid: string): string => `acct_${uuid}`

/** `<accountId>|<gmail label id>`, e.g. `acct_1|INBOX`. */
export const labelId = (account: string, remoteLabelId: string): string =>
  `${account}${ID_SEP}${remoteLabelId}`

/** `<accountId>|<gmail thread id>`. */
export const threadId = (account: string, remoteThreadId: string): string =>
  `${account}${ID_SEP}${remoteThreadId}`

/** `<accountId>|<gmail message id>`. */
export const messageId = (account: string, remoteMessageId: string): string =>
  `${account}${ID_SEP}${remoteMessageId}`

/**
 * `<messageId>|<labelId>` for the junction table.
 *
 * Deriving this rather than using a random UUID means a label can be attached
 * idempotently: applying the same label twice produces the same row.
 */
export const messageLabelId = (message: string, label: string): string =>
  `${message}${ID_SEP}${label}`

/** `<messageId>|<gmail attachment id>`. */
export const attachmentId = (message: string, remoteAttachmentId: string): string =>
  `${message}${ID_SEP}${remoteAttachmentId}`
