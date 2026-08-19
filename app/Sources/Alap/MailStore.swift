import AppKit
import Foundation
import os
import SwiftUI
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
/// Selection and triage events, for diagnosing input that appears to do
/// nothing. Info level, so `log show --info` retrieves it.
private let storeLog = Logger(subsystem: AppIdentity.bundleID, category: "store")

@MainActor
@Observable
final class MailStore {
  let bridge: any MailBridge
  let search: SearchIndex

  /// Hands a downloaded file to the system.
  ///
  /// Injected rather than calling `NSWorkspace` directly so tests can assert
  /// *which* file would be opened without actually launching Preview — a test
  /// suite that opens windows is one nobody runs.
  @ObservationIgnored private let openFile: (URL) -> Void

  /// - Parameters:
  ///   - bridge: Defaults to the real Zero bridge. Tests inject a fake so the
  ///     store's logic runs without WebKit or a network.
  ///   - openFile: Defaults to Launch Services.
  init(
    bridge: any MailBridge = ZeroBridge(),
    search: SearchIndex = SearchIndex(),
    openFile: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }
  ) {
    self.bridge = bridge
    self.search = search
    self.openFile = openFile
  }

  /// Current search text. Empty means the normal label view.
  var searchText: String = "" {
    didSet {
      guard searchText != oldValue else { return }
      searchTask?.cancel()
      searchTask = Task { [weak self] in
        try? await Task.sleep(for: MailStore.searchDebounce)
        guard !Task.isCancelled else { return }
        // Each new search is a fresh result set; keeping a grown limit would
        // ask for thousands of rows to show a handful of matches.
        self?.threadLimit = MailStore.threadPageSize
        self?.isGrowingThreads = false
        self?.resubscribeThreads()
      }
    }
  }

  var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespaces).isEmpty }

  private(set) var accounts: [AccountRow] = []
  private(set) var labels: [LabelRow] = []
  /// Queued and failed remote operations, mirrored from the outbox.
  private(set) var unresolvedOutbox: [OutboxRow] = []
  /// Attachments to open as soon as their bytes arrive.
  ///
  /// Not observed by the UI — this is intent, not state. The chip's appearance
  /// comes from `state(of:)`, which reads the outbox and the disk.
  @ObservationIgnored private var openWhenDownloaded: Set<String> = []
  private(set) var threads: [ThreadRow] = []
  private(set) var threadsLoaded = false

  /// Threads that arrived in a live update within the last moment.
  ///
  /// Drives the row's arrival flash; ids leave the set `arrivalDecay` after
  /// entering, animated, and the removal is what fades the tint out. The sync
  /// loop delivers new mail in about six seconds with no refresh, and the app
  /// used to render that as a silent list mutation — a genuinely magic moment
  /// shown as nothing at all.
  private(set) var recentlyArrived: Set<String> = []

  /// How long a row stays marked as newly arrived.
  static let arrivalDecay: Duration = .seconds(1.5)

  /// When a live update last actually changed which conversations exist.
  ///
  /// Not persisted across launches, deliberately: "synced 3 days ago" at
  /// launch, before the first poll has completed, is stale information
  /// presented as current.
  private(set) var lastDelivery: Date?

  /// What the last search cost, or nil when nothing is being searched.
  ///
  /// The direction's whole pitch rests on numbers the app never measured. This
  /// is the measurement, and it doubles as a regression sentinel: if it ever
  /// reads 40 ms, someone has broken the early-termination design
  /// `SearchIndex` documents.
  private(set) var lastSearch: SearchStats?

  /// Total messages in the local index, or nil when the index is unavailable.
  ///
  /// Measured at open and after each delivery, never per render.
  private(set) var indexedMessageCount: Int?

  /// The sidebar destination currently being shown.
  ///
  /// Replaces the old "selected label or nil" model, because the design's
  /// sidebar contains derived views (Archive, Unread, Attachments) that have no
  /// label behind them. See `Mailbox`.
  var selectedMailbox: Mailbox = .allInboxes {
    didSet {
      guard selectedMailbox != oldValue else { return }
      selectedThreadID = nil
      // A limit earned by scrolling a large mailbox must not carry into a
      // small one, or switching pays for rows that do not exist.
      threadLimit = MailStore.threadPageSize
      isGrowingThreads = false
      resubscribeThreads()
    }
  }

  /// Selection is stored as an ID, not a whole row.
  ///
  /// `List(selection:)` hashes and compares its selection value constantly. A
  /// `ThreadRow` hashes every field including the participants array, so
  /// binding the struct made arrow-key navigation quadratic in row size. A
  /// String is a single cheap comparison.
  /// Every selected thread.
  ///
  /// The SOURCE OF TRUTH for selection, including the single-selection case.
  /// Keeping a separate `selectedThreadID` as the real value and deriving the
  /// set from it would mean two representations that can disagree, and every
  /// bulk action would have to ask which one to trust.
  /// Rows the reader has TICKED, for a bulk action. Independent of what is
  /// open: ticking a checkbox does not change what is being read, and reading
  /// a message does not tick it.
  ///
  /// These were one value, with `selectedThreadID` writing back into this set.
  /// That made clicking a row to READ it tick its checkbox and put the window
  /// into bulk-selection mode — a state the reader never asked for and could
  /// only leave by finding the toggle.
  var selection: Set<String> = []

  var selectionCount: Int { selection.count }

  /// Whether an action that operates on the selection can run.
  ///
  /// NOT `selectedThread != nil`. That is the SINGLE selected thread, which is
  /// deliberately nil once several are selected — so testing it disabled every
  /// bulk action during exactly the operation those actions exist for.
  var hasSelection: Bool { !selection.isEmpty }

  /// Whether the select-all control does anything.
  ///
  /// True whenever there are threads at all, because the control TOGGLES: with
  /// nothing selected it selects everything, and with anything selected it
  /// clears. It is never a dead end, so it is never disabled for having already
  /// done its job.
  var canSelectAll: Bool { !threads.isEmpty }

  /// What the select-all control will do if pressed.
  ///
  /// Any selection at all means the next press clears — including a partial
  /// one. Selecting the remainder is not what someone reaches for after
  /// picking a few by hand; getting back to nothing is.
  var selectAllWouldClear: Bool { !selection.isEmpty }
  var hasMultipleSelected: Bool { selection.count > 1 }

  /// Threads currently selected, in list order.
  ///
  /// Ordered so bulk actions read predictably in the UI and so the successor
  /// after a bulk archive is chosen from a stable position.
  var selectedThreads: [ThreadRow] {
    threads.filter { selection.contains($0.id) }
  }

  var selectedThreadID: String? {
    didSet {
      guard selectedThreadID != oldValue else { return }
      selectedThread = threads.first { $0.id == selectedThreadID }
      scheduleDetailSubscription()
      scheduleMarkRead()
    }
  }

  private(set) var selectedThread: ThreadRow?

  /// The fully-hydrated thread behind the reading pane.
  private(set) var detail: ThreadDetailRow?
  private(set) var detailLoaded = false

  /// How many threads the list currently holds.
  ///
  /// There is no pagination. The list grows as it is scrolled, so this is a
  /// high-water mark rather than a page number: growing it re-subscribes with a
  /// larger limit and Zero extends the existing result rather than re-fetching.
  ///
  /// It starts well above a screenful so the first growth is never visible, and
  /// it resets when the mailbox changes — otherwise switching to a small
  /// mailbox would keep paying for a limit earned in a large one.
  private(set) var threadLimit = MailStore.threadPageSize

  /// Rows fetched initially, and added per growth.
  ///
  /// 500, not 200. A real inbox here matches 17,683 threads, so at 200 a page
  /// reaching the thousandth conversation meant five separate scroll-triggered
  /// fetches — and every one of them depended on a scroll signal arriving.
  /// Fewer, larger pages means fewer chances to stall.
  static let threadPageSize = 500

  /// Rows added per growth, once past the first page.
  ///
  /// Larger than the initial page: the first is on the critical path to
  /// painting the window, later ones are not.
  static let threadGrowthSize = 1000

  /// Rows from the end at which more are requested.
  ///
  /// Far enough ahead that the fetch completes before the user arrives, close
  /// enough that a flick to the bottom does not request several pages at once.
  private static let growthTrigger = 40

  /// True between asking for more and receiving it, so a burst of row
  /// appearances cannot queue several growths for the same scroll.
  @ObservationIgnored private var isGrowingThreads = false

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
    refreshIndexCount()

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

    // Queued and failed remote operations. This drives the attachment
    // download indicators, and — more importantly — is what stops the app from
    // silently diverging from Gmail when an operation fails for good.
    bridge.subscribe(id: "outbox", query: "outbox.unresolved", as: OutboxRow.self) {
      [weak self] rows, _ in
      self?.unresolvedOutbox = rows
      // A download that failed must disarm its pending open, or the request
      // would sit armed and fire later against a stale click.
      self?.cancelOpensForFailedDownloads()
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

  /// How long a conversation must stay open before it counts as read.
  ///
  /// Not zero. Holding ↓ moves through the list far faster than anyone reads,
  /// and marking each row as it flashes past would silently clear the unread
  /// state of everything between where you started and where you stopped — at
  /// 500 rows that is not a mistake anyone can undo row by row.
  ///
  /// Long enough to survive a keypress, short enough that landing on a message
  /// and looking at it counts. Apple Mail and Outlook both settled on a dwell
  /// for the same reason.
  static let defaultMarkReadDwell = Duration.milliseconds(600)

  /// Overridable so tests can use a short dwell.
  ///
  /// Tests that waited out the real 600ms passed alone and failed in the full
  /// suite: Swift Testing runs suites in parallel, and a contended MainActor
  /// resumes the sleep late enough to blow any fixed tolerance. A short dwell
  /// plus polling for the result removes the race rather than padding it.
  @ObservationIgnored var markReadDwell = MailStore.defaultMarkReadDwell

  @ObservationIgnored private var markReadTask: Task<Void, Never>?

  /// Marks the open conversation read once it has been open long enough.
  ///
  /// Cancelled and rescheduled on every selection change, so only the row the
  /// selection comes to REST on is ever marked.
  private func scheduleMarkRead() {
    markReadTask?.cancel()

    // Keyed to the OPEN conversation. It used to also require exactly one
    // ticked row, which was the same thing back when opening ticked; now that
    // they are separate, ticking a batch has no bearing on whether the message
    // being read counts as read.
    guard let thread = selectedThread, thread.isUnread else { return }

    let dwell = markReadDwell
    markReadTask = Task { [weak self] in
      try? await Task.sleep(for: dwell)
      guard !Task.isCancelled else { return }
      // The selection may have moved on while the dwell elapsed.
      guard self?.selectedThreadID == thread.id else { return }
      // recordUndo: false — auto-marking is a side effect of looking at
      // something, not an action the user took. Recording it would mean ⌘Z
      // after reading a message un-reads it instead of undoing the archive
      // that came before, which is both surprising and destructive.
      await self?.setRead([thread], isRead: true, recordUndo: false)
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
      // The bytes of a requested attachment may have just landed.
      self?.openAnyArrivedAttachments()
      // Embedded images are part of the message, so fetch them without asking.
      self?.downloadInlineImages()
    }
  }

  /// Swaps the thread-list query when the selected label changes.
  ///
  /// Reusing the same subscription id means the JS side tears the old view
  /// down and materialises the new one, rather than leaking a subscription per
  /// sidebar click.
  private func resubscribeThreads() {
    threadsLoaded = false
    if !isSearching { lastSearch = nil }

    // STAGE TWO of search. FTS5 has already matched and returned thread ids;
    // feeding them through ZQL rather than rendering SQLite rows directly is
    // what keeps results live — a thread marked read while the results are on
    // screen updates itself.
    if isSearching {
      // Timed here because this is the only call site, and because a claim
      // about being fast that the product cannot measure is a claim nobody can
      // check — including whoever later changes the query.
      let clock = ContinuousClock()
      let started = clock.now
      let ids = search.threadIDs(matching: searchText)
      let elapsed = started.duration(to: clock.now)
      lastSearch = SearchStats(
        matched: ids.count,
        milliseconds: Double(elapsed.components.attoseconds) / 1e15
          + Double(elapsed.components.seconds) * 1000
      )
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
        // NEVER animated, and not an oversight. Results chase keystrokes, so
        // motion here would sit between typing and seeing — which is lag
        // wearing the costume of polish. The live subscription below is the
        // one that animates, because mail arriving IS an event and a search
        // result updating is not.
        self?.threads = rows.sorted { (rank[$0.id] ?? .max) < (rank[$1.id] ?? .max) }
        if isComplete { self?.threadsLoaded = true }
      }
      return
    }

    // Every mailbox resolves to a registered query name; two of them need an
    // argument.
    var args: [String: JSONValue] = ["limit": .number(Double(threadLimit))]
    switch selectedMailbox {
    case .label(let remoteId):
      // The PROVIDER id, not a row id. Every account has its own row for the
      // same label, so passing one row id would show a single mailbox's mail
      // under a sidebar entry that claims to cover all of them.
      guard labels.contains(where: { $0.remoteId == remoteId }) else {
        // The label has not synced yet. Show nothing rather than every thread.
        threads = []
        threadsLoaded = true
        bridge.unsubscribe(id: threadSubscriptionID)
        return
      }
      args["remoteId"] = .string(remoteId)

    case .account(let id):
      args["accountId"] = .string(id)

    default:
      break
    }

    storeLog.info("subscribe \(self.selectedMailbox.queryName, privacy: .public) limit=\(self.threadLimit, privacy: .public)")
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
      storeLog.info("threads update: \(rows.count, privacy: .public) rows")
      self?.applyLiveThreads(rows)
    }
  }

  /// Applies a live thread-list update, animating it when it represents events.
  ///
  /// ## Why `withAnimation` lives in the store
  ///
  /// The alternative is the view diffing consecutive arrays to decide whether
  /// to animate — which re-derives `threadsLoaded` and `isGrowingThreads`
  /// somewhere they are not available. Every list change in the app flows
  /// through this one assignment, so there is exactly one place to get right.
  ///
  /// The guards are load-bearing, and `ThreadListDelta` states them:
  ///
  ///   - The first delivery of any list never animates. `resubscribeThreads()`
  ///     clears `threadsLoaded` before every mailbox switch and every search,
  ///     so switching from Inbox to Sent does not play 500 insert animations.
  ///     A mailbox switch is navigation, not events.
  ///   - Pagination never animates. Two hundred appended rows of history are
  ///     not arriving mail.
  ///
  /// Archive and trash arrive here too, as Zero-confirmed list changes — so
  /// the archived row physically collapses and the list closes over it,
  /// without a single line written for that case.
  private func applyLiveThreads(_ rows: [ThreadRow]) {
    let delta = ThreadListDelta(
      previous: threads.map(\.id),
      current: rows.map(\.id),
      listWasLive: threadsLoaded,
      isGrowing: isGrowingThreads
    )

    if delta.animates {
      withAnimation(Theme.Motion.standard) { threads = rows }
    } else {
      threads = rows
    }
    threadsLoaded = true
    isGrowingThreads = false
    reconcileSelection()

    guard delta.animates else { return }
    if delta.changedMembership {
      lastDelivery = .now
      refreshIndexCount()
    }
    for id in delta.arrivals { markArrived(id) }
  }

  /// Marks one id as newly arrived and schedules its decay.
  ///
  /// Guarded by identity on the way out, in the same shape as
  /// `UndoStack.show`: a second arrival for the same conversation restarts the
  /// clock rather than letting the first one clear it early.
  ///
  /// One welcome side effect, on purpose: **undo restores flash too.** A
  /// restored thread re-enters as a new id in a live update, so the flash shows
  /// you where the conversation went back to. It is not special-cased away.
  private func markArrived(_ id: String) {
    recentlyArrived.insert(id)
    arrivalTasks[id]?.cancel()
    arrivalTasks[id] = Task { [weak self] in
      try? await Task.sleep(for: MailStore.arrivalDecay)
      guard !Task.isCancelled else { return }
      guard let self else { return }
      self.arrivalTasks[id] = nil
      // `fade`: this is an opacity/colour decay with no physical reading, and
      // a spring would overshoot it.
      withAnimation(Theme.Motion.fade) { _ = self.recentlyArrived.remove(id) }
    }
  }

  @ObservationIgnored private var arrivalTasks: [String: Task<Void, Never>] = [:]

  /// Clears the arrival set without waiting out the decay. For tests.
  func clearArrivalsForTesting() {
    for task in arrivalTasks.values { task.cancel() }
    arrivalTasks.removeAll()
    recentlyArrived.removeAll()
  }

  /// Re-reads the index size. Cheap, and never called per render.
  private func refreshIndexCount() {
    indexedMessageCount = search.isAvailable ? search.messageCount() : nil
  }

  /// Asks for more threads when a row near the end comes on screen.
  ///
  /// Called from the row itself rather than from a scroll offset: `List` is
  /// lazy, so a row appearing IS the signal that the viewport reached it, and
  /// it costs nothing to observe. Watching scroll offsets would mean measuring
  /// content height on every frame.
  func growThreadsIfNeeded(reaching threadID: String) {
    guard !isGrowingThreads else { return }
    // A short list is the whole result, not a truncated one — asking for more
    // would re-subscribe forever against a mailbox that has nothing further.
    guard threads.count >= threadLimit else { return }
    guard threadLimit < MailStore.maxThreadLimit else { return }
    guard let index = threads.firstIndex(where: { $0.id == threadID }),
          index >= threads.count - MailStore.growthTrigger
    else { return }

    storeLog.info("grow: \(self.threadLimit, privacy: .public) -> \(self.threadLimit + MailStore.threadPageSize, privacy: .public)")
    growThreads()
  }

  /// Loads the next page, whatever triggered it.
  ///
  /// Public because scrolling is not the only way to ask: the list carries an
  /// explicit control, so a stalled or missed scroll signal is never the end of
  /// the road. That was the actual failure — growth depended entirely on a row
  /// near the end appearing, and when that did not happen the mailbox simply
  /// ended at 200 with nothing to say otherwise.
  func growThreads() {
    guard canGrowThreads else { return }
    isGrowingThreads = true
    threadLimit = min(threadLimit + MailStore.threadGrowthSize,
                      MailStore.maxThreadLimit)
    storeLog.info("grow -> limit \(self.threadLimit, privacy: .public)")
    resubscribeThreads()
  }

  /// Clears the in-flight flag without a bridge round trip.
  ///
  /// Exists so a test can drive repeated growth; production clears it when the
  /// larger page actually arrives.
  func markGrowthFinishedForTesting() { isGrowingThreads = false }

  /// Whether more conversations may exist beyond those loaded.
  ///
  /// A full page means there is probably more; a short one is the whole
  /// result. This drives the footer, so the list can SAY that it is not
  /// showing everything rather than just ending.
  var hasMoreThreads: Bool {
    threads.count >= threadLimit && threadLimit < MailStore.maxThreadLimit
  }

  var canGrowThreads: Bool { hasMoreThreads && !isGrowingThreads }

  /// True while a larger page is in flight, so the footer can say so.
  var isLoadingMoreThreads: Bool { isGrowingThreads }

  /// Must match `MAX_THREAD_LIMIT` in queries.ts, which rejects anything above
  /// it — exceeding it would fail the query rather than return fewer rows.
  static let maxThreadLimit = 50_000

  /// Unread across every connected mailbox's inbox.
  ///
  /// The rail's reading, not a badge — so it returns a number rather than a
  /// nil-when-zero optional. Zero unread is information.
  var unreadTotal: Int {
    labels.filter { $0.remoteId == "INBOX" }.reduce(0) { $0 + $1.unreadCount }
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
    case .account(let id):
      return unreadCount(forAccount: id)
    case .archived, .attachments:
      return nil
    }
  }

  /// The colour marking mail from this account in a unified list.
  ///
  /// Nil while a single account is connected. The stripe exists to answer
  /// "whose mailbox did this arrive in", and with one mailbox that question
  /// has no content — showing it anyway would be decoration pretending to be
  /// information.
  func tint(forAccount accountId: String) -> Color? {
    guard accounts.count > 1,
          let account = accounts.first(where: { $0.id == accountId })
    else { return nil }
    return AccountPalette.tint(for: account.color)
  }

  /// Renames or recolours an account.
  ///
  /// Local presentation only — nothing here reaches Gmail, so unlike almost
  /// every other mutation in this store it produces no outbox row.
  func updateAccount(_ accountId: String, displayName: String? = nil,
                     color: String? = nil) async {
    var args: [String: JSONValue] = ["accountId": .string(accountId)]
    if let displayName {
      let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty { args["displayName"] = .string(trimmed) }
    }
    if let color { args["color"] = .string(color) }
    guard args.count > 1 else { return }

    try? await bridge.mutate("accounts.update", args: args)
  }

  /// Unread messages in one account's inbox.
  ///
  /// Read from the label row's trigger-maintained counter rather than counted
  /// here: ZQL has no aggregates, and the synced thread list is only the first
  /// page, so counting locally would under-report on any real mailbox.
  func unreadCount(forAccount accountId: String) -> Int {
    labels
      .filter { $0.accountId == accountId && $0.remoteId == "INBOX" }
      .reduce(0) { $0 + $1.unreadCount }
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
    guard let thread = selectedThread else { return }
    await trash([thread])
  }

  /// Moves threads to Trash.
  ///
  /// A real trash, not an archive. This used to call `threads.archive`, which
  /// only removes INBOX — so "Trash" filed mail away into All Mail and deleted
  /// nothing. Adding the TRASH label is what Gmail treats as deleted.
  func trash(_ rows: [ThreadRow]) async {
    for (accountId, group) in Dictionary(grouping: rows, by: \.accountId) {
      guard let inbox = labels.first(where: {
        $0.remoteId == "INBOX" && $0.accountId == accountId
      }) else { continue }

      try? await bridge.mutate(
        "threads.trash",
        args: [
          "accountId": .string(accountId),
          "threadIds": .array(group.map { .string($0.id) }),
          "inboxLabelId": .string(inbox.id),
          "idempotencyKey": .string(UUID().uuidString.lowercased()),
        ]
      )
    }
    let trashed = Set(rows.map(\.id))
    selection.subtract(trashed)
    if let current = selectedThread, trashed.contains(current.id) {
      selectedThread = nil
    }

    undoStack.record(rows.count == 1 ? "Trashed 1 conversation"
                                     : "Trashed \(rows.count) conversations") {
      [weak self] in await self?.restore(rows)
    }
  }


  /// The composer panel's state. Owned here so menu commands can reach it.
  let composer = Composer()

  /// The last reversible action.
  let undoStack = UndoStack()

  /// Opens the composer as a reply to the selected thread.
  ///
  /// Recipients and threading are resolved HERE rather than in the composer,
  /// because this is where the conversation is loaded — handing the composer
  /// the whole store to work them out itself would invert the dependency for
  /// no gain.
  func startReply() {
    guard let thread = selectedThread,
          let parent = detail?.messages.last,
          let account = accounts.first(where: { $0.id == thread.accountId })
    else { return }

    // Reply to the sender, unless that is us — in which case reply to whoever
    // the parent was addressed to, so replying to your own sent mail works.
    let recipients: [String] =
      parent.fromEmail.caseInsensitiveCompare(account.emailAddress) == .orderedSame
      ? parent.toRecipients.map(\.email)
      : [parent.fromEmail]
    guard !recipients.isEmpty else { return }

    let sendingAccount = replyAccount(for: thread, parent: parent)

    // References is the ancestry: whatever the parent carried, plus the parent.
    var references: [String] = []
    if let parentId = parent.rfc822MessageId, !parentId.isEmpty {
      references.append(parentId)
    }

    composer.reply(
      to: recipients,
      subject: MailStore.replySubject(parent.subject),
      quoting: MailStore.quotedBody(of: parent),
      context: Composer.ReplyContext(
        accountId: sendingAccount,
        remoteThreadId: thread.remoteThreadId,
        inReplyTo: parent.rfc822MessageId ?? "",
        references: references
      )
    )
  }

  /// Which of your addresses a reply should come from.
  ///
  /// Prefers whichever connected address the message was actually ADDRESSED
  /// to. Mail that arrived at your work address should be answered from your
  /// work address — replying from the wrong identity is the kind of mistake
  /// that is only visible to the recipient, and only after it is sent.
  ///
  /// Falls back to the account that owns the thread, which is right whenever
  /// the message reached you some other way: a mailing list, a Bcc, or an
  /// alias that forwards.
  func replyAccount(for thread: ThreadRow, parent: MessageRow) -> String {
    let addressed = Set(
      (parent.toRecipients + parent.ccRecipients).map { $0.email.lowercased() })
    if let match = accounts.first(where: { addressed.contains($0.emailAddress.lowercased()) }) {
      return match.id
    }
    return thread.accountId
  }

  /// The parent message, quoted beneath a reply.
  ///
  /// Every other mail client does this, and its absence is not neutral: a reply
  /// with no quoted context reads as abrupt, and in a long exchange the
  /// recipient loses the thread entirely — particularly on a phone, where the
  /// conversation view is often just the latest message.
  ///
  /// Plain-text `>` quoting rather than HTML, because the engine composes
  /// single-part text/plain. Quoting with markup a text/plain message cannot
  /// carry would put visible tags in the recipient's inbox.
  static func quotedBody(of parent: MessageRow) -> String {
    let attribution = "On \(parent.sentDate.formatted(date: .long, time: .shortened)), "
      + "\(parent.displayName) <\(parent.fromEmail)> wrote:"

    // The body is already plain text — `displayBody` converts HTML on decode,
    // once, rather than on every render.
    let quoted = parent.displayBody
      .split(separator: "\n", omittingEmptySubsequences: false)
      .prefix(MailStore.maxQuotedLines)
      .map { $0.isEmpty ? ">" : "> \($0)" }
      .joined(separator: "\n")

    let truncated = parent.displayBody
      .split(separator: "\n", omittingEmptySubsequences: false).count
      > MailStore.maxQuotedLines
    return attribution + "\n" + quoted + (truncated ? "\n> […]" : "")
  }

  /// Lines of the parent carried into a reply.
  ///
  /// A machine-generated digest can run to thousands of lines, and quoting all
  /// of it would bury the actual reply and inflate every message in the thread.
  static let maxQuotedLines = 120

  /// Mirrors the engine's `compose::reply_subject` — adds `Re:` only when it
  /// is absent, so a few round trips do not produce "Re: Re: Re:".
  static func replySubject(_ original: String) -> String {
    original.lowercased().hasPrefix("re:") ? original : "Re: \(original)"
  }

  /// Opens an empty composer.
  func startNewMessage() {
    // The selected thread's account, else the first — so replying from a work
    // mailbox and then composing does not silently switch identity.
    let account = selectedThread?.accountId ?? accounts.first?.id
    composer.newMessage(from: account)
  }

  /// Queues whatever the composer currently holds.
  ///
  /// Nothing is inserted locally. The sent message arrives from Gmail on the
  /// next poll as a real message — an optimistic copy would duplicate it, or
  /// strand an orphan if the send failed.
  func sendComposed() async {
    guard composer.canSend,
          let accountId = composer.accountId,
          let account = accounts.first(where: { $0.id == accountId })
    else {
      composer.status = .failed("No account to send from.")
      return
    }

    let to = composer.recipients(from: composer.to)
    guard !to.isEmpty else {
      composer.status = .failed("Add at least one valid recipient.")
      return
    }

    composer.status = .sending
    let context = composer.replyContext

    do {
      try await bridge.mutate(
        "compose.send",
        args: [
          "accountId": .string(accountId),
          "fromName": .string(account.displayName),
          "fromEmail": .string(account.emailAddress),
          "to": .array(to.map { .string($0) }),
          "cc": .array(composer.recipients(from: composer.cc).map { .string($0) }),
          "subject": .string(composer.subject),
          "body": .string(composer.composedBody),
          "remoteThreadId": .string(context?.remoteThreadId ?? ""),
          "inReplyTo": .string(context?.inReplyTo ?? ""),
          "references": .array((context?.references ?? []).map { .string($0) }),
          "idempotencyKey": .string(UUID().uuidString.lowercased()),
        ]
      )
      composer.status = .queued
      // Closed on success only, so a failure never loses what was written.
      composer.close()
    } catch {
      composer.status = .failed(error.localizedDescription)
    }
  }

  /// Addresses to suggest while typing a recipient.
  ///
  /// Drawn from threads already synced rather than a dedicated contacts query:
  /// the participants are sitting in memory, so this costs a filter instead of
  /// a round trip. It only knows people in the loaded window, which is the
  /// right trade — the people you have seen recently are the people you are
  /// most likely to be writing to.
  func addressSuggestions(matching prefix: String, limit: Int = 6) -> [Participant] {
    let needle = prefix.trimmingCharacters(in: .whitespaces).lowercased()
    guard needle.count >= 2 else { return [] }

    var seen = Set<String>()
    var matches: [Participant] = []
    for participant in threads.flatMap(\.participants) {
      let email = participant.email.lowercased()
      guard !email.isEmpty, !seen.contains(email) else { continue }
      guard email.contains(needle) || participant.name.lowercased().contains(needle) else {
        continue
      }
      seen.insert(email)
      matches.append(participant)
      if matches.count >= limit { break }
    }
    return matches
  }


  // MARK: Attachments

  /// How an attachment is currently doing.
  enum AttachmentState: Equatable {
    /// Not downloaded, and nothing queued.
    case idle
    /// An outbox row for it is pending or in flight.
    case downloading
    /// The bytes are on disk.
    case ready(URL)
    /// The download failed permanently.
    case failed(String)
    /// Gmail exposes no attachment id, so there is nothing to fetch.
    case unavailable
  }

  /// The outbox id the download mutator derives for an attachment.
  ///
  /// Deterministic rather than random, so clicking a chip five times queues
  /// one download. Must match `attachments.download` in mutators.ts.
  private func downloadOutboxID(_ attachmentID: String) -> String {
    "download|\(attachmentID)"
  }

  func state(of attachment: AttachmentRow) -> AttachmentState {
    // Disk first: the file being present is the only thing that actually
    // matters, and it can be true even if the outbox row lingers.
    if let file = attachment.readyFile { return .ready(file) }
    guard attachment.canDownload else { return .unavailable }

    if let row = unresolvedOutbox.first(where: { $0.id == downloadOutboxID(attachment.id) }) {
      if row.isLive { return .downloading }
      if row.status == "failed" { return .failed(row.lastError ?? "Download failed") }
    }
    return .idle
  }

  /// Queues a download. Harmless to call for something already downloaded —
  /// the engine checks the blob store and skips the transfer.
  func downloadAttachment(_ attachment: AttachmentRow) async {
    guard let accountId = selectedThread?.accountId else { return }
    try? await bridge.mutate(
      "attachments.download",
      args: ["accountId": .string(accountId), "attachmentId": .string(attachment.id)]
    )
  }

  /// Opens an attachment, downloading it first if it is not already here.
  ///
  /// One click, not two. The download is asynchronous and lands via the Zero
  /// subscription rather than by returning here, so the intent is recorded and
  /// `openAnyArrivedAttachments` fires it when the bytes actually appear.
  ///
  /// Nothing is ever opened straight from the network: the file is on disk
  /// before it is handed to Launch Services, which is also what lets "Reveal
  /// in Finder" and "Save a Copy" work against the same path.
  func openAttachment(_ attachment: AttachmentRow) async {
    if case .ready(let file) = state(of: attachment) {
      openFile(file)
      return
    }
    guard attachment.canDownload else { return }
    openWhenDownloaded.insert(attachment.id)
    await downloadAttachment(attachment)
  }

  /// The open conversation's real attachments, in the order they appear.
  ///
  /// Inline parts are excluded: those are the message's own images, already
  /// rendered in the body, and offering to "open" one is offering to open a
  /// piece of the thing you are looking at.
  var openAttachments: [AttachmentRow] {
    (detail?.messages ?? []).flatMap(\.attachments).filter { !$0.isInline }
  }

  /// Content-ID → downloaded file, for the thread on screen.
  ///
  /// Only the open conversation, never an accumulated cache: the map is what
  /// the renderer is allowed to reach, so keeping it to one thread means a
  /// crafted `cid:` cannot address another message's attachments.
  var inlineImages: [String: URL] {
    guard let detail else { return [:] }
    var map: [String: URL] = [:]
    for attachment in detail.messages.flatMap(\.attachments) {
      guard attachment.isInline,
            let contentId = attachment.contentId, !contentId.isEmpty,
            let file = attachment.readyFile
      else { continue }
      map[contentId] = file
    }
    return map
  }

  /// Fetches the inline images the open thread needs to render.
  ///
  /// Automatic, unlike a real attachment. An embedded logo is not something
  /// anyone chooses to download — it is part of the message, and a click-to-see
  /// placeholder in the middle of a signature is worse than the broken box it
  /// replaced.
  ///
  /// Bounded by what is actually read: only the open thread, and only parts
  /// that are missing. The whole mailbox holds 225 MB of inline parts, which
  /// is precisely why this is not done during sync.
  private func downloadInlineImages() {
    guard let detail else { return }

    for attachment in detail.messages.flatMap(\.attachments) {
      guard attachment.isInline,
            attachment.canDownload,
            !(attachment.contentId ?? "").isEmpty,
            attachment.readyFile == nil,
            case .idle = state(of: attachment)
      else { continue }
      Task { await downloadAttachment(attachment) }
    }
  }

  /// Whether a click is still waiting on this attachment's bytes.
  ///
  /// Exists so tests can assert on the arming of a one-click open without
  /// reaching into private state or observing `NSWorkspace`.
  func isAwaitingOpen(_ attachmentID: String) -> Bool {
    openWhenDownloaded.contains(attachmentID)
  }

  /// Applies the debounced detail subscription immediately.
  ///
  /// The debounce exists so that holding an arrow key costs one body load
  /// instead of one per row. Tests must not depend on wall-clock timing to get
  /// past it, so they call this instead of sleeping.
  func flushPendingSubscriptions() {
    detailTask?.cancel()
    searchTask?.cancel()
    subscribeDetailNow()
  }

  /// Opens anything whose bytes have arrived since the last update.
  ///
  /// Driven by the detail subscription rather than by polling: when the engine
  /// records `local_path`, that row replicates back and re-renders the pane,
  /// which is the same signal that turns the chip blue.
  private func openAnyArrivedAttachments() {
    guard !openWhenDownloaded.isEmpty, let detail else { return }

    for attachment in detail.messages.flatMap(\.attachments) {
      guard openWhenDownloaded.contains(attachment.id),
            let file = attachment.readyFile
      else { continue }
      // Remove BEFORE opening: NSWorkspace.open is not synchronous, and a
      // second subscription update arriving first would launch it twice.
      openWhenDownloaded.remove(attachment.id)
      openFile(file)
    }
  }

  /// Disarms pending opens whose download failed for good.
  private func cancelOpensForFailedDownloads() {
    guard !openWhenDownloaded.isEmpty else { return }
    for row in unresolvedOutbox where row.status == "failed" {
      guard row.id.hasPrefix("download|") else { continue }
      openWhenDownloaded.remove(String(row.id.dropFirst("download|".count)))
    }
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
    await archive([thread])
  }

  /// Archives many threads.
  ///
  /// Grouped by account because the INBOX label id differs per mailbox and a
  /// Gmail call belongs to exactly one account. Within an account it is ONE
  /// mutation and one outbox row, so archiving fifty threads is one batchModify
  /// rather than fifty.
  func archive(_ rows: [ThreadRow]) async {
    for (accountId, group) in Dictionary(grouping: rows, by: \.accountId) {
      guard let inbox = labels.first(where: {
        $0.remoteId == "INBOX" && $0.accountId == accountId
      }) else { continue }

      try? await bridge.mutate(
        "threads.archive",
        args: [
          "accountId": .string(accountId),
          "threadIds": .array(group.map { .string($0.id) }),
          "inboxLabelId": .string(inbox.id),
          "idempotencyKey": .string(UUID().uuidString.lowercased()),
        ]
      )
    }
    let archived = Set(rows.map(\.id))
    selection.subtract(archived)
    if let current = selectedThread, archived.contains(current.id) {
      selectedThread = nil
    }

    undoStack.record(rows.count == 1 ? "Archived 1 conversation"
                                     : "Archived \(rows.count) conversations") {
      [weak self] in await self?.restore(rows)
    }
  }

  /// Puts threads back in the inbox — the inverse of archive and of trash.
  func restore(_ rows: [ThreadRow]) async {
    for (accountId, group) in Dictionary(grouping: rows, by: \.accountId) {
      guard let inbox = labels.first(where: {
        $0.remoteId == "INBOX" && $0.accountId == accountId
      }) else { continue }

      try? await bridge.mutate(
        "threads.restore",
        args: [
          "accountId": .string(accountId),
          "threadIds": .array(group.map { .string($0.id) }),
          "inboxLabelId": .string(inbox.id),
          "idempotencyKey": .string(UUID().uuidString.lowercased()),
        ]
      )
    }
  }

  func setRead(_ thread: ThreadRow, isRead: Bool) async {
    await setRead([thread], isRead: isRead)
  }

  /// Marks many threads read or unread, one mutation per account.
  func setRead(_ rows: [ThreadRow], isRead: Bool, recordUndo: Bool = true) async {
    for (accountId, group) in Dictionary(grouping: rows, by: \.accountId) {
      try? await bridge.mutate(
        "threads.setRead",
        args: [
          "accountId": .string(accountId),
          "threadIds": .array(group.map { .string($0.id) }),
          "isRead": .bool(isRead),
          "idempotencyKey": .string(UUID().uuidString.lowercased()),
        ]
      )
    }

    guard recordUndo else { return }
    let verb = isRead ? "read" : "unread"
    undoStack.record("Marked \(rows.count) \(verb)") { [weak self] in
      // recordUndo: false — otherwise undoing would itself become the newest
      // undoable action, and ⌘Z would flip back and forth forever.
      await self?.setRead(rows, isRead: !isRead, recordUndo: false)
    }
  }

  func toggleStar(_ thread: ThreadRow) async {
    await setStarred([thread], isStarred: !thread.isStarred)
  }

  /// Flags or unflags many threads, one mutation per account.
  func setStarred(_ rows: [ThreadRow], isStarred: Bool, recordUndo: Bool = true) async {
    for (accountId, group) in Dictionary(grouping: rows, by: \.accountId) {
      try? await bridge.mutate(
        "threads.setStarred",
        args: [
          "accountId": .string(accountId),
          "threadIds": .array(group.map { .string($0.id) }),
          "isStarred": .bool(isStarred),
          "idempotencyKey": .string(UUID().uuidString.lowercased()),
        ]
      )
    }

    guard recordUndo else { return }
    // Spelled out rather than "Flagged 1", which is what the banner used to
    // read. Flagging one row at a time from the list made that the common
    // case rather than the rare one.
    let verb = isStarred ? "Flagged" : "Unflagged"
    let noun = rows.count == 1 ? "1 conversation" : "\(rows.count) conversations"
    undoStack.record("\(verb) \(noun)") { [weak self] in
      await self?.setStarred(rows, isStarred: !isStarred, recordUndo: false)
    }
  }

  // MARK: - Bulk actions on the selection

  /// Selects every loaded thread.
  ///
  /// Every LOADED thread, not every thread in the mailbox. The list grows as
  /// it is scrolled, so "all" can only honestly mean what has been fetched —
  /// and an action that silently applied to 30,000 rows the user has never
  /// seen would be worse than one that admits its scope.
  func selectAll() {
    selection = Set(threads.map(\.id))
    storeLog.info("selectAll -> \(self.selection.count, privacy: .public) of \(self.threads.count, privacy: .public)")
  }

  /// Adds or removes one thread from the selection.
  ///
  /// Separate from assigning `selectedThreadID`, which MOVES the selection.
  /// This is what a checkbox does: extend or reduce without changing where the
  /// reading pane is pointed, so ticking a second row does not navigate away
  /// from the one being read.
  func toggleSelection(of threadID: String) {
    if selection.contains(threadID) {
      selection.remove(threadID)
    } else {
      selection.insert(threadID)
    }
  }

  /// Selects everything, or clears if anything is already selected.
  ///
  /// One control rather than two. Pressing it twice returns you to where you
  /// started, which is what a person expects from a button that just selected
  /// everything — hunting for a separate Clear to undo it is a detour.
  func toggleSelectAll() {
    if selection.isEmpty {
      selectAll()
    } else {
      clearSelection()
    }
  }

  func clearSelection() {
    selection = []
    selectedThreadID = nil
  }

  /// Marks the selection read or unread.
  func setReadOnSelection(_ isRead: Bool) async {
    await setRead(selectedThreads, isRead: isRead)
  }

  /// Marks the selection read, or unread when all of it is already read.
  ///
  /// One direction for the whole selection, decided by whether any of it is
  /// still unread — the same reasoning as flagging. Toggling each row
  /// independently would turn a mixed selection into a differently-mixed one.
  func markSelectionRead() async {
    let rows = selectedThreads
    guard !rows.isEmpty else { return }
    await setRead(rows, isRead: rows.contains { $0.isUnread })
  }

  /// Flags or unflags the selection.
  ///
  /// One flag state for the whole selection rather than toggling each row
  /// independently: a mixed selection toggled per-row would invert into a
  /// differently-mixed selection, which is not what anyone means by "flag
  /// these". Any unflagged row means the action is "flag".
  func toggleFlagOnSelection() async {
    let rows = selectedThreads
    guard !rows.isEmpty else { return }
    let shouldFlag = rows.contains { !$0.isStarred }
    await setStarred(rows, isStarred: shouldFlag)
  }

  /// Archives the selection, then moves to what follows it.
  func archiveSelection() async {
    let rows = selectedThreads
    guard !rows.isEmpty else { return }

    // The successor is chosen BEFORE the mutation, while the rows still exist.
    let successor = threadAfter(rows)
    await archive(rows)
    selectedThreadID = successor
  }

  /// Trashes the selection.
  func trashSelection() async {
    let rows = selectedThreads
    guard !rows.isEmpty else { return }
    let successor = threadAfter(rows)
    await trash(rows)
    selectedThreadID = successor
  }

  /// The first thread below the removed block, else the one above it.
  private func threadAfter(_ removed: [ThreadRow]) -> String? {
    let going = Set(removed.map(\.id))
    guard let lastIndex = threads.lastIndex(where: { going.contains($0.id) })
    else { return nil }

    if let below = threads[(lastIndex + 1)...].first(where: { !going.contains($0.id) }) {
      return below.id
    }
    return threads[..<lastIndex].last(where: { !going.contains($0.id) })?.id
  }
}
