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
  let search = SearchIndex()

  /// Current search text. Empty means the normal label view.
  var searchText: String = "" {
    didSet {
      guard searchText != oldValue else { return }
      searchTask?.cancel()
      searchTask = Task { [weak self] in
        try? await Task.sleep(for: MailStore.searchDebounce)
        guard !Task.isCancelled else { return }
        self?.resubscribeThreads()
      }
    }
  }

  var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespaces).isEmpty }

  private(set) var accounts: [AccountRow] = []
  private(set) var labels: [LabelRow] = []
  private(set) var threads: [ThreadRow] = []
  private(set) var threadsLoaded = false

  /// Currently selected label, or nil for the unified inbox.
  var selectedLabel: LabelRow? {
    didSet { resubscribeThreads() }
  }

  /// Selection is stored as an ID, not a whole row.
  ///
  /// `List(selection:)` hashes and compares its selection value constantly. A
  /// `ThreadRow` hashes every field including the participants array, so
  /// binding the struct made arrow-key navigation quadratic in row size. A
  /// String is a single cheap comparison.
  var selectedThreadID: String? {
    didSet {
      guard selectedThreadID != oldValue else { return }
      selectedThread = threads.first { $0.id == selectedThreadID }
      scheduleDetailSubscription()
    }
  }

  private(set) var selectedThread: ThreadRow?

  /// The fully-hydrated thread behind the reading pane.
  private(set) var detail: ThreadDetailRow?
  private(set) var detailLoaded = false

  private let threadSubscriptionID = "threads"
  private let detailSubscriptionID = "detail"

  /// Pending detail subscription, cancelled when selection moves again.
  @ObservationIgnored private var detailTask: Task<Void, Never>?
  /// Pending search re-query, cancelled on each keystroke.
  @ObservationIgnored private var searchTask: Task<Void, Never>?

  /// How long selection must settle before the reading pane loads.
  ///
  /// Holding an arrow key generates selections far faster than a body can be
  /// fetched, and each one previously issued a subscribe across the bridge
  /// that pulled full message bodies. Debouncing means a held key costs ONE
  /// load at the end rather than one per row, while still feeling immediate
  /// for a deliberate click.
  private static let detailDebounce = Duration.milliseconds(180)

  /// Search re-queries hit FTS5 plus a Zero subscription, so they wait for a
  /// typing pause rather than firing per character.
  private static let searchDebounce = Duration.milliseconds(150)

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

  /// Subscribes the reading pane to the selected thread.
  ///
  /// This is the ONLY query that pulls `message_body`. Reusing one
  /// subscription id means selecting a different thread tears down the
  /// previous view rather than accumulating one per click — otherwise every
  /// message you ever opened would stay synced for the session.
  /// Debounces the reading-pane load. See `detailDebounce`.
  private func scheduleDetailSubscription() {
    detailTask?.cancel()

    guard selectedThread != nil else {
      bridge.unsubscribe(id: detailSubscriptionID)
      detail = nil
      detailLoaded = false
      return
    }

    // Clear immediately so the pane never shows the PREVIOUS message's body
    // while the new one loads.
    detail = nil
    detailLoaded = false

    detailTask = Task { [weak self] in
      try? await Task.sleep(for: MailStore.detailDebounce)
      guard !Task.isCancelled else { return }
      self?.subscribeDetailNow()
    }
  }

  private func subscribeDetailNow() {
    guard let thread = selectedThread else { return }

    bridge.subscribeOne(
      id: detailSubscriptionID,
      query: "threads.detail",
      args: ["threadId": .string(thread.id)],
      as: ThreadDetailRow.self
    ) { [weak self] row, isComplete in
      // A late reply from a subscription the user has already moved past must
      // not overwrite the current pane.
      guard self?.selectedThreadID == thread.id else { return }
      self?.detail = row
      if isComplete { self?.detailLoaded = true }
    }
  }

  /// Swaps the thread-list query when the selected label changes.
  ///
  /// Reusing the same subscription id means the JS side tears the old view
  /// down and materialises the new one, rather than leaking a subscription per
  /// sidebar click.
  private func resubscribeThreads() {
    threadsLoaded = false

    // STAGE TWO of search. FTS5 has already matched and returned thread ids;
    // feeding them through ZQL rather than rendering SQLite rows directly is
    // what keeps results live — a thread marked read while the results are on
    // screen updates itself.
    if isSearching {
      let ids = search.threadIDs(matching: searchText)
      if ids.isEmpty {
        threads = []
        threadsLoaded = true
        bridge.unsubscribe(id: threadSubscriptionID)
        return
      }
      bridge.subscribe(
        id: threadSubscriptionID,
        query: "threads.byIds",
        args: ["ids": .array(ids.map { .string($0) })],
        as: ThreadRow.self
      ) { [weak self] rows, isComplete in
        // FTS5 ranked these by relevance; ZQL returns them by recency. Restore
        // the relevance order, since that is what the user asked for.
        let rank = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
        self?.threads = rows.sorted { (rank[$0.id] ?? .max) < (rank[$1.id] ?? .max) }
        if isComplete { self?.threadsLoaded = true }
      }
      return
    }

    if let label = selectedLabel {
      bridge.subscribe(
        id: threadSubscriptionID,
        query: "threads.inLabel",
        args: ["labelId": .string(label.id)],
        as: ThreadRow.self
      ) { [weak self] rows, isComplete in
        self?.threads = rows
        self?.reconcileSelection()
        if isComplete { self?.threadsLoaded = true }
      }
    } else {
      bridge.subscribe(
        id: threadSubscriptionID,
        query: "threads.unifiedInbox",
        as: ThreadRow.self
      ) { [weak self] rows, isComplete in
        self?.threads = rows
        self?.reconcileSelection()
        if isComplete { self?.threadsLoaded = true }
      }
    }
  }

  /// Keeps `selectedThread` pointing at a row that still exists after the list
  /// refreshes — archiving the selected thread, for instance.
  private func reconcileSelection() {
    guard let id = selectedThreadID else { return }
    selectedThread = threads.first { $0.id == id }
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
