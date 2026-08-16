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
  /// Gmail's own thread id, needed when sending so the reply joins the
  /// existing conversation in Gmail's UI.
  let remoteThreadId: String
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

  /// Formatted once per row rather than per render.
  ///
  /// SwiftUI rebuilds every visible row's body whenever the list's selection
  /// changes, so anything computed inside `body` runs on each keypress.
  let displayTime: String

  /// Who to show in the list row. Falls back to the subject line's absence
  /// rather than rendering an empty cell.
  var displayName: String {
    participants.first.map { $0.name.isEmpty ? $0.email : $0.name } ?? "Unknown"
  }

  private enum CodingKeys: String, CodingKey {
    case id, accountId, remoteThreadId, subject, snippet, participants, lastMessageAt
    case messageCount, unreadCount, hasAttachments, isStarred
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    accountId = try container.decode(String.self, forKey: .accountId)
    remoteThreadId = try container.decode(String.self, forKey: .remoteThreadId)
    subject = try container.decode(String.self, forKey: .subject)
    snippet = try container.decode(String.self, forKey: .snippet)
    participants = try container.decode([Participant].self, forKey: .participants)
    lastMessageAt = try container.decode(Double.self, forKey: .lastMessageAt)
    messageCount = try container.decode(Int.self, forKey: .messageCount)
    unreadCount = try container.decode(Int.self, forKey: .unreadCount)
    hasAttachments = try container.decode(Bool.self, forKey: .hasAttachments)
    isStarred = try container.decode(Bool.self, forKey: .isStarred)
    displayTime = RelativeTime.short(Date(timeIntervalSince1970: lastMessageAt / 1000))
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
  /// Reused formatters.
  ///
  /// `Date.formatted(.dateTime...)` builds a new FormatStyle on every call, and
  /// a list row calls it on every render. With 100 rows re-rendering as the
  /// selection moves, that allocation dominated scrolling. A cached
  /// DateFormatter is roughly an order of magnitude cheaper.
  private static let timeOnly: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "h:mm a"
    return formatter
  }()

  private static let weekday: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "EEE"
    return formatter
  }()

  private static let monthDay: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "MMM d"
    return formatter
  }()

  /// Mail-style timestamp: time for today, weekday within the week, date beyond.
  static func short(_ date: Date, now: Date = .now) -> String {
    let calendar = Calendar.current
    if calendar.isDateInToday(date) {
      return timeOnly.string(from: date)
    }
    if let days = calendar.dateComponents([.day], from: date, to: now).day, days < 7 {
      return weekday.string(from: date)
    }
    return monthDay.string(from: date)
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
  /// RFC 5322 Message-ID, without angle brackets. Needed to thread a reply.
  let rfc822MessageId: String?
  let body: MessageBodyRow?
  let attachments: [AttachmentRow]

  var sentDate: Date { Date(timeIntervalSince1970: sentAt / 1000) }
  var displayName: String { fromName.isEmpty ? fromEmail : fromName }

  /// Best available rendering of the message, computed ONCE at decode.
  ///
  /// This must not be a computed property. SwiftUI reads it inside `body`, and
  /// `plainTextFromHTML` runs several full-string regex passes — so a 100KB
  /// newsletter was being re-parsed on every render, on the main thread.
  ///
  /// Prefers `text_body`. HTML is converted to text rather than rendered,
  /// because the schema promises sanitised HTML and the C++ engine does not
  /// sanitise yet — rendering unsanitised remote HTML would be an XSS and
  /// tracking-pixel vector. See `plainTextFromHTML`.
  let displayBody: String

  /// True when `displayBody` was truncated for rendering.
  let isTruncated: Bool

  /// True when we are showing a downgraded rendering of an HTML-only message.
  let isDowngradedFromHTML: Bool

  /// True when the body simply has not been fetched yet.
  var isBodyMissing: Bool { body == nil }

  /// True when there is sanitised HTML worth rendering.
  ///
  /// The engine sanitises on ingest, so anything here has already been through
  /// the allowlist. The web view still assumes nothing — see `MessageWebView`.
  var hasRenderableHTML: Bool { !(body?.htmlBody?.isEmpty ?? true) }

  /// Longest body rendered inline.
  ///
  /// A single `Text` holding hundreds of kilobytes with `textSelection` and
  /// `fixedSize` forces SwiftUI to lay out the whole string synchronously.
  /// Mail like that exists — machine-generated reports, long digests — and it
  /// stalls the pane.
  private static let maxRenderedCharacters = 20_000

  private enum CodingKeys: String, CodingKey {
    case id, threadId, fromName, fromEmail, toRecipients, ccRecipients
    case subject, snippet, sentAt, isRead, isStarred, hasAttachments
    case rfc822MessageId, body, attachments
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    threadId = try container.decode(String.self, forKey: .threadId)
    fromName = try container.decode(String.self, forKey: .fromName)
    fromEmail = try container.decode(String.self, forKey: .fromEmail)
    toRecipients = try container.decode([Participant].self, forKey: .toRecipients)
    ccRecipients = try container.decode([Participant].self, forKey: .ccRecipients)
    subject = try container.decode(String.self, forKey: .subject)
    snippet = try container.decode(String.self, forKey: .snippet)
    sentAt = try container.decode(Double.self, forKey: .sentAt)
    isRead = try container.decode(Bool.self, forKey: .isRead)
    isStarred = try container.decode(Bool.self, forKey: .isStarred)
    hasAttachments = try container.decode(Bool.self, forKey: .hasAttachments)
    rfc822MessageId = try container.decodeIfPresent(String.self, forKey: .rfc822MessageId)
    body = try container.decodeIfPresent(MessageBodyRow.self, forKey: .body)
    attachments = try container.decode([AttachmentRow].self, forKey: .attachments)

    // Resolve the rendered text once, here, rather than on every render.
    let text = body?.textBody ?? ""
    let html = body?.htmlBody ?? ""
    isDowngradedFromHTML = text.isEmpty && !html.isEmpty

    let resolved: String
    if !text.isEmpty {
      resolved = text
    } else if !html.isEmpty {
      resolved = plainTextFromHTML(html)
    } else {
      resolved = snippet
    }

    if resolved.count > Self.maxRenderedCharacters {
      displayBody = String(resolved.prefix(Self.maxRenderedCharacters))
      isTruncated = true
    } else {
      displayBody = resolved
      isTruncated = false
    }
  }
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
