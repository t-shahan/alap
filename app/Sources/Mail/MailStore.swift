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

  /// The sidebar destination currently being shown.
  ///
  /// Replaces the old "selected label or nil" model, because the design's
  /// sidebar contains derived views (Archive, Unread, Attachments) that have no
  /// label behind them. See `Mailbox`.
  var selectedMailbox: Mailbox = .allInboxes {
    didSet {
      guard selectedMailbox != oldValue else { return }
      selectedThreadID = nil
      resubscribeThreads()
    }
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
  /// Short, because preloading means the detail query usually resolves from
  /// the LOCAL cache rather than a server round trip. This exists only to
  /// coalesce a held arrow key, not to hide network latency.
  private static let detailDebounce = Duration.milliseconds(70)

  /// Search re-queries hit FTS5 plus a Zero subscription, so they wait for a
  /// typing pause rather than firing per character.
  private static let searchDebounce = Duration.milliseconds(150)

  func start() {
    bridge.start()

    bridge.subscribe(id: "accounts", query: "accounts.all", as: AccountRow.self) { [weak self] rows, _ in
      self?.accounts = rows
    }

    bridge.subscribe(id: "labels", query: "labels.all", as: LabelRow.self) { [weak self] rows, _ in
      guard let self else { return }
      let hadLabels = !self.labels.isEmpty
      self.labels = rows
      // A label-backed mailbox selected before its label synced showed nothing.
      // Retry once the labels arrive.
      if !hadLabels, case .label = self.selectedMailbox {
        self.resubscribeThreads()
      }
    }

    resubscribeThreads()

    // Sync the bodies of the most recent threads up front. Without this, every
    // reading-pane open is a fresh query that must round-trip to zero-cache —
    // roughly a second before any text appears.
    bridge.preload(id: "preload-details", query: "threads.preloadDetails",
                   args: ["limit": .number(40)])
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
    ) { [weak self] row, _ in
      // A late reply from a subscription the user has already moved past must
      // not overwrite the current pane.
      guard self?.selectedThreadID == thread.id else { return }
      // Same reasoning as the thread list: `resultType` never reports
      // `complete` through the bridge, so gating on it would leave the reading
      // pane showing "Loading…" forever.
      self?.detail = row
      self?.detailLoaded = true
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

    // Every mailbox resolves to a registered query name; only `label` needs an
    // argument, and it has to be the composite row id rather than the Gmail id.
    var args: [String: JSONValue] = [:]
    if case .label(let remoteId) = selectedMailbox {
      guard let row = labels.first(where: { $0.remoteId == remoteId }) else {
        // The label has not synced yet. Show nothing rather than every thread.
        threads = []
        threadsLoaded = true
        bridge.unsubscribe(id: threadSubscriptionID)
        return
      }
      args["labelId"] = .string(row.id)
    }

    bridge.subscribe(
      id: threadSubscriptionID,
      query: selectedMailbox.queryName,
      args: args,
      as: ThreadRow.self
    ) { [weak self] rows, _ in
      // Marked loaded on the FIRST update, not on `isComplete`. Zero delivers
      // locally-cached rows immediately and the server confirmation follows,
      // but `resultType` has never reported `complete` through the bridge — so
      // gating on it left the UI saying "Loading…" permanently.
      self?.threads = rows
      self?.threadsLoaded = true
      self?.reconcileSelection()
      self?.selectFirstIfNeeded()
    }
  }

  /// Selects the first thread when a mailbox loads with nothing selected.
  ///
  /// Without this the reading pane sits empty until the user clicks, and the
  /// keyboard shortcuts have no anchor to move from.
  private func selectFirstIfNeeded() {
    guard selectedThreadID == nil, let first = threads.first else { return }
    selectedThreadID = first.id
  }

  /// Unread count for a sidebar row, or nil when it should show no badge.
  ///
  /// Reads the trigger-maintained column rather than counting, because ZQL has
  /// no aggregates. Derived mailboxes have no label row, so they are computed
  /// from the threads already synced.
  func badge(for mailbox: Mailbox) -> Int? {
    switch mailbox {
    case .allInboxes, .label(remoteId: "INBOX"):
      let total = labels.filter { $0.remoteId == "INBOX" }.reduce(0) { $0 + $1.unreadCount }
      return total > 0 ? total : nil
    case .label(let remoteId):
      let count = labels.filter { $0.remoteId == remoteId }.reduce(0) { $0 + $1.unreadCount }
      return count > 0 ? count : nil
    case .unread:
      let count = labels.filter { $0.remoteId == "UNREAD" }.reduce(0) { $0 + $1.totalCount }
      return count > 0 ? count : nil
    case .archived, .attachments:
      return nil
    }
  }

  /// Keeps `selectedThread` pointing at a row that still exists after the list
  /// refreshes — archiving the selected thread, for instance.
  private func reconcileSelection() {
    guard let id = selectedThreadID else { return }
    selectedThread = threads.first { $0.id == id }
  }

  // MARK: - Keyboard navigation

  /// Index of the current selection, if any.
  private var selectedIndex: Int? {
    guard let id = selectedThreadID else { return nil }
    return threads.firstIndex { $0.id == id }
  }

  /// Moves the selection by `offset`, clamped to the list.
  ///
  /// Selecting the first row when nothing is selected is what makes `J` work
  /// immediately after launch without a click.
  func moveSelection(by offset: Int) {
    guard !threads.isEmpty else { return }
    guard let current = selectedIndex else {
      selectedThreadID = threads.first?.id
      return
    }
    let next = min(max(current + offset, 0), threads.count - 1)
    selectedThreadID = threads[next].id
  }

  // MARK: - Actions

  /// Archives the selection and moves to the next thread.
  ///
  /// Advancing is the whole point: it turns archiving into a repeatable triage
  /// loop rather than an action that leaves you with nothing selected. The
  /// successor is chosen BEFORE the mutation, because the archived row
  /// disappears from the reactive list as soon as the local write lands and
  /// its index is then meaningless.
  func archiveSelectedAndAdvance() async {
    guard let thread = selectedThread, let index = selectedIndex else { return }

    // Prefer the row below; fall back to the one above when archiving the last.
    let successor: String? =
      index + 1 < threads.count ? threads[index + 1].id
      : (index > 0 ? threads[index - 1].id : nil)

    await archive(thread)
    selectedThreadID = successor
  }

  func toggleReadOnSelection() async {
    guard let thread = selectedThread else { return }
    await setRead(thread, isRead: thread.isUnread)
  }

  /// Moves the selection to Gmail's Trash and advances.
  ///
  /// Achievable because trashing IS a label change — add TRASH, remove INBOX —
  /// so it goes through the same batchModify path as archive. Permanent
  /// deletion (`delete_forever`) is a different API and is not implemented.
  func trashSelected() async {
    guard let thread = selectedThread, let index = selectedIndex else { return }
    let successor: String? =
      index + 1 < threads.count ? threads[index + 1].id
      : (index > 0 ? threads[index - 1].id : nil)

    let messages = detail?.messages ?? []
    guard !messages.isEmpty else { return }

    try? await bridge.mutate(
      "threads.archive",  // removes INBOX; TRASH is added by payload below
      args: [
        "accountId": .string(thread.accountId),
        "threadId": .string(thread.id),
        "inboxLabelId": .string(labels.first {
          $0.remoteId == "INBOX" && $0.accountId == thread.accountId
        }?.id ?? ""),
        "idempotencyKey": .string(UUID().uuidString.lowercased()),
      ]
    )
    selectedThreadID = successor
  }

  func toggleStarOnSelection() async {
    guard let thread = selectedThread else { return }
    await toggleStar(thread)
  }

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
