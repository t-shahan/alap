import Foundation

/// A selectable destination in the sidebar.
///
/// The design's sidebar mixes two different things under one visual treatment:
/// real Gmail labels (Inbox, Sent, Drafts) and derived views (Archive, Unread,
/// Attachments) that have no label behind them. Modelling both as one type
/// keeps the sidebar uniform while letting each resolve to a different query.
enum Mailbox: Hashable, Identifiable {
  /// Unified inbox across every connected account.
  case allInboxes
  /// A real Gmail label, by its provider-side id (`INBOX`, `STARRED`, …).
  case label(remoteId: String)
  /// Mail that is filed: no INBOX label, and not trash or spam.
  ///
  /// Gmail has no archive label — archiving IS removing INBOX — so this is a
  /// negation rather than a lookup.
  case archived
  case unread
  case attachments
  /// Everything in one account, for when unified is not what you want.
  case account(id: String)

  var id: String {
    switch self {
    case .allInboxes: "all"
    case .label(let remoteId): "label:\(remoteId)"
    case .archived: "archived"
    case .unread: "unread"
    case .attachments: "attachments"
    case .account(let id): "account:\(id)"
    }
  }

  /// The registered ZQL query name this resolves to.
  var queryName: String {
    switch self {
    case .allInboxes: "threads.unifiedInbox"
    case .label: "threads.inLabel"
    case .archived: "threads.archived"
    case .unread: "threads.unread"
    case .attachments: "threads.withAttachments"
    case .account: "threads.forAccount"
    }
  }

  var title: String {
    switch self {
    case .allInboxes: "All Inboxes"
    case .label(let remoteId): Mailbox.displayName(for: remoteId)
    case .archived: "Archive"
    case .unread: "Unread"
    case .attachments: "Attachments"
    case .account: "Account"
    }
  }

  /// SF Symbol standing in for the design's Lucide glyph.
  var systemImage: String {
    switch self {
    case .allInboxes: "tray.2"
    case .label(let remoteId): Mailbox.symbol(for: remoteId)
    case .archived: "archivebox"
    case .unread: "circle.slash"
    case .attachments: "paperclip"
    case .account: "person.crop.circle"
    }
  }

  /// The mailboxes the design lists under MAILBOXES.
  ///
  /// Gmail's own names are shouty (`CATEGORY_UPDATES`, `DRAFT`), so system
  /// labels are retitled here. Absent from the design and therefore from this
  /// list: VIPs, which has no equivalent in the schema or in Gmail.
  static let standard: [Mailbox] = [
    .label(remoteId: "INBOX"),
    .label(remoteId: "STARRED"),
    .label(remoteId: "SENT"),
    .label(remoteId: "DRAFT"),
    .archived,
    .label(remoteId: "TRASH"),
  ]

  /// The design's SMART FILTERS section.
  static let smartFilters: [Mailbox] = [.unread, .attachments]

  /// Friendly names for Gmail's system labels.
  static func displayName(for remoteId: String) -> String {
    switch remoteId {
    case "INBOX": "Inbox"
    // The design calls starred mail "Flagged", following Apple Mail rather
    // than Gmail. Kept, since the app is a Mac app first.
    case "STARRED": "Flagged"
    case "SENT": "Sent"
    case "DRAFT": "Drafts"
    case "TRASH": "Trash"
    case "SPAM": "Spam"
    case "IMPORTANT": "Important"
    case "UNREAD": "Unread"
    case "CATEGORY_PERSONAL": "Personal"
    case "CATEGORY_SOCIAL": "Social"
    case "CATEGORY_PROMOTIONS": "Promotions"
    case "CATEGORY_UPDATES": "Updates"
    case "CATEGORY_FORUMS": "Forums"
    default:
      // User labels arrive as "[Mailbox]/To Read"; show the leaf.
      remoteId.split(separator: "/").last.map(String.init) ?? remoteId
    }
  }

  static func symbol(for remoteId: String) -> String {
    switch remoteId {
    case "INBOX": "tray"
    case "STARRED": "star"
    case "SENT": "paperplane"
    case "DRAFT": "doc"
    case "TRASH": "trash"
    case "SPAM": "exclamationmark.octagon"
    case "IMPORTANT": "bookmark"
    default: "tag"
    }
  }
}
