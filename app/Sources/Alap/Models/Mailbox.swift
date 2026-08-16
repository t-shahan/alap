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

extension Mailbox {
  /// Empty-state wording, per destination.
  ///
  /// "This mailbox is empty" is technically true everywhere and useful
  /// nowhere. An empty Trash and an empty Inbox mean opposite things — one is
  /// an achievement, the other is usually a sync that has not finished.
  var emptyTitle: String {
    switch self {
    case .allInboxes, .label(remoteId: "INBOX"): "Inbox zero"
    case .label(remoteId: "TRASH"): "Trash is empty"
    case .label(remoteId: "DRAFT"): "No drafts"
    case .label(remoteId: "SENT"): "Nothing sent yet"
    case .label(remoteId: "STARRED"): "Nothing flagged"
    case .label: "Nothing here"
    case .archived: "Nothing archived"
    case .unread: "All caught up"
    case .attachments: "No attachments"
    case .account: "Nothing in this account"
    }
  }

  var emptyMessage: String {
    switch self {
    case .allInboxes, .label(remoteId: "INBOX"):
      "You have read everything. Enjoy it while it lasts."
    case .label(remoteId: "TRASH"): "Deleted mail will appear here."
    case .label(remoteId: "DRAFT"): "Messages you start and do not send land here."
    case .label(remoteId: "SENT"): "Messages you send will appear here."
    case .label(remoteId: "STARRED"): "Flag a conversation to keep it close."
    case .label: "This label has no conversations."
    case .archived: "Archived mail is filed out of the inbox but never deleted."
    case .unread: "Every message has been read."
    case .attachments: "Conversations carrying files will appear here."
    case .account: "This mailbox has no conversations yet."
    }
  }
}
