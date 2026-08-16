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
