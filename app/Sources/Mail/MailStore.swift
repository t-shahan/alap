import Foundation
import Observation

/// The app's reactive view of Zero.
///
/// Owns the bridge and holds the decoded rows every view reads. Because each
/// property is `@Observable`, a row arriving over the bridge invalidates only
/// the views that actually read it.
///
/// Note there is no loading spinner state beyond `threadsLoaded`. Zero's whole
/// premise is that reads hit the local cache first, so the list paints from
/// cached data on the very first frame; `threadsLoaded` exists only to tell an
/// *actually empty* inbox apart from one that has not synced yet.
@MainActor
@Observable
final class MailStore {
  let bridge = ZeroBridge()

  private(set) var accounts: [AccountRow] = []
  private(set) var labels: [LabelRow] = []
  private(set) var threads: [ThreadRow] = []
  private(set) var threadsLoaded = false

  /// Currently selected label, or nil for the unified inbox.
  var selectedLabel: LabelRow? {
    didSet { resubscribeThreads() }
  }

  var selectedThread: ThreadRow?

  private let threadSubscriptionID = "threads"

  func start() {
    bridge.start()

    bridge.subscribe(id: "accounts", query: "accounts.all", as: AccountRow.self) { [weak self] rows, _ in
      self?.accounts = rows
    }

    bridge.subscribe(id: "labels", query: "labels.all", as: LabelRow.self) { [weak self] rows, _ in
      // Only labels that hold something are worth sidebar space.
      self?.labels = rows.filter { $0.totalCount > 0 || $0.remoteId == "INBOX" }
    }

    resubscribeThreads()
  }

  /// Swaps the thread-list query when the selected label changes.
  ///
  /// Reusing the same subscription id means the JS side tears the old view
  /// down and materialises the new one, rather than leaking a subscription per
  /// sidebar click.
  private func resubscribeThreads() {
    threadsLoaded = false

    if let label = selectedLabel {
      bridge.subscribe(
        id: threadSubscriptionID,
        query: "threads.inLabel",
        args: ["labelId": .string(label.id)],
        as: ThreadRow.self
      ) { [weak self] rows, isComplete in
        self?.threads = rows
        if isComplete { self?.threadsLoaded = true }
      }
    } else {
      bridge.subscribe(
        id: threadSubscriptionID,
        query: "threads.unifiedInbox",
        as: ThreadRow.self
      ) { [weak self] rows, isComplete in
        self?.threads = rows
        if isComplete { self?.threadsLoaded = true }
      }
    }
  }

  // MARK: - Actions

  /// Archives a thread — which in Gmail's model means removing INBOX.
  ///
  /// The UI updates before this returns: the mutator writes locally first, and
  /// the row disappears from the list via the same reactive path as any other
  /// change. No manual list manipulation.
  func archive(_ thread: ThreadRow) async {
    guard let inbox = labels.first(where: {
      $0.remoteId == "INBOX" && $0.accountId == thread.accountId
    }) else {
      return
    }
    try? await bridge.mutate(
      "threads.archive",
      args: [
        "accountId": .string(thread.accountId),
        "threadId": .string(thread.id),
        "inboxLabelId": .string(inbox.id),
        "idempotencyKey": .string(UUID().uuidString.lowercased()),
      ]
    )
    if selectedThread == thread { selectedThread = nil }
  }

  func setRead(_ thread: ThreadRow, isRead: Bool) async {
    try? await bridge.mutate(
      "threads.setRead",
      args: [
        "accountId": .string(thread.accountId),
        "threadId": .string(thread.id),
        "isRead": .bool(isRead),
        "idempotencyKey": .string(UUID().uuidString.lowercased()),
      ]
    )
  }

  func toggleStar(_ thread: ThreadRow) async {
    try? await bridge.mutate(
      "threads.setStarred",
      args: [
        "accountId": .string(thread.accountId),
        "threadId": .string(thread.id),
        "isStarred": .bool(!thread.isStarred),
        "idempotencyKey": .string(UUID().uuidString.lowercased()),
      ]
    )
  }
}
