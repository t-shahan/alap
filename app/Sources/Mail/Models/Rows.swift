import Foundation

/// Swift mirrors of the Zero schema rows.
///
/// One conversion trap worth internalising: Postgres `timestamptz` arrives as
/// a JSON **number** — epoch milliseconds — not an ISO string and not a Date.
/// Every timestamp here is a `Double`, with a computed `Date` beside it, so
/// the conversion happens in exactly one place.

struct ThreadRow: Decodable, Identifiable, Hashable {
  let id: String
  let accountId: String
  let subject: String
  let snippet: String
  let participants: [Participant]
  let lastMessageAt: Double
  let messageCount: Int
  let unreadCount: Int
  let hasAttachments: Bool
  let isStarred: Bool

  var isUnread: Bool { unreadCount > 0 }
  var lastMessageDate: Date { Date(timeIntervalSince1970: lastMessageAt / 1000) }

  /// Who to show in the list row. Falls back to the subject line's absence
  /// rather than rendering an empty cell.
  var displayName: String {
    participants.first.map { $0.name.isEmpty ? $0.email : $0.name } ?? "Unknown"
  }
}

struct Participant: Decodable, Hashable {
  let name: String
  let email: String
}

struct LabelRow: Decodable, Identifiable, Hashable {
  let id: String
  let accountId: String
  let remoteId: String
  let name: String
  let kind: String
  let sortOrder: Int
  /// Trigger-maintained in Postgres. ZQL has no aggregates, so this is read
  /// directly rather than counted.
  let unreadCount: Int
  let totalCount: Int

  var systemImage: String {
    switch remoteId {
    case "INBOX": "tray"
    case "STARRED": "star"
    case "SENT": "paperplane"
    case "DRAFT": "doc"
    case "ARCHIVE": "archivebox"
    default: "tag"
    }
  }
}

struct AccountRow: Decodable, Identifiable, Hashable {
  let id: String
  let emailAddress: String
  let displayName: String
  let provider: String
  let color: String
  let sortOrder: Int
}

// MARK: - Formatting

enum RelativeTime {
  /// Mail-style timestamp: time for today, weekday within the week, date beyond.
  static func short(_ date: Date, now: Date = .now) -> String {
    let calendar = Calendar.current
    if calendar.isDateInToday(date) {
      return date.formatted(.dateTime.hour().minute())
    }
    if let days = calendar.dateComponents([.day], from: date, to: now).day, days < 7 {
      return date.formatted(.dateTime.weekday(.abbreviated))
    }
    return date.formatted(.dateTime.month(.abbreviated).day())
  }
}

// MARK: - Reading pane

/// A message with its body, as returned by `threads.detail`.
///
/// The body arrives through a `.related('body')` hop, so it is optional in two
/// senses: the relationship may be absent, and the columns within it are
/// nullable. A message whose body has not been backfilled yet is normal, not
/// an error.
struct MessageRow: Decodable, Identifiable, Hashable {
  let id: String
  let threadId: String
  let fromName: String
  let fromEmail: String
  let toRecipients: [Participant]
  let ccRecipients: [Participant]
  let subject: String
  let snippet: String
  let sentAt: Double
  let isRead: Bool
  let isStarred: Bool
  let hasAttachments: Bool
  let body: MessageBodyRow?
  let attachments: [AttachmentRow]

  var sentDate: Date { Date(timeIntervalSince1970: sentAt / 1000) }
  var displayName: String { fromName.isEmpty ? fromEmail : fromName }

  /// Best available rendering of the message.
  ///
  /// Prefers `text_body`. HTML is converted to text rather than rendered,
  /// because the schema promises sanitised HTML and the C++ engine does not
  /// sanitise yet — rendering unsanitised remote HTML would be an XSS and
  /// tracking-pixel vector. See `plainTextFromHTML`.
  var displayBody: String {
    if let text = body?.textBody, !text.isEmpty { return text }
    if let html = body?.htmlBody, !html.isEmpty { return plainTextFromHTML(html) }
    return snippet
  }

  /// True when we are showing a downgraded rendering of an HTML-only message.
  var isDowngradedFromHTML: Bool {
    (body?.textBody?.isEmpty ?? true) && !(body?.htmlBody?.isEmpty ?? true)
  }

  /// True when the body simply has not been fetched yet.
  var isBodyMissing: Bool { body == nil }
}

struct MessageBodyRow: Decodable, Hashable {
  let messageId: String
  let textBody: String?
  let htmlBody: String?
}

struct AttachmentRow: Decodable, Identifiable, Hashable {
  let id: String
  let filename: String
  let mimeType: String
  let sizeBytes: Int
  let isInline: Bool

  var displaySize: String {
    ByteCountFormatter.string(fromByteCount: Int64(sizeBytes), countStyle: .file)
  }
}

/// A thread with its messages hydrated — the reading-pane query's shape.
struct ThreadDetailRow: Decodable, Identifiable, Hashable {
  let id: String
  let subject: String
  let messages: [MessageRow]
}

/// Converts HTML to readable plain text.
///
/// Deliberately conservative and lossy. This is NOT a sanitiser and is not a
/// substitute for one — it exists so HTML-only mail is readable without
/// executing anything. Script and style contents are dropped entirely rather
/// than being surfaced as text.
func plainTextFromHTML(_ html: String) -> String {
  var text = html

  // Remove whole elements whose contents should never be shown.
  for tag in ["script", "style", "head", "noscript"] {
    text = text.replacingOccurrences(
      of: "<\(tag)[^>]*>.*?</\(tag)>",
      with: " ",
      options: [.regularExpression, .caseInsensitive]
    )
  }

  // Preserve the block structure that carries meaning.
  for (pattern, replacement) in [
    ("<br[^>]*>", "\n"),
    ("</p>", "\n\n"),
    ("</div>", "\n"),
    ("</tr>", "\n"),
    ("<li[^>]*>", "\n  • "),
  ] {
    text = text.replacingOccurrences(
      of: pattern, with: replacement, options: [.regularExpression, .caseInsensitive])
  }

  text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)

  // Decode the entities that actually appear in mail.
  for (entity, character) in [
    ("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
    ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&mdash;", "—"),
    ("&ndash;", "–"), ("&hellip;", "…"), ("&rsquo;", "'"), ("&lsquo;", "'"),
    ("&ldquo;", "\""), ("&rdquo;", "\""),
  ] {
    text = text.replacingOccurrences(of: entity, with: character, options: .caseInsensitive)
  }

  // Collapse the runs of blank lines that HTML mail is full of.
  text = text.replacingOccurrences(
    of: "\n{3,}", with: "\n\n", options: .regularExpression)
  text = text.replacingOccurrences(
    of: "[ \t]{2,}", with: " ", options: .regularExpression)

  return text.trimmingCharacters(in: .whitespacesAndNewlines)
}
