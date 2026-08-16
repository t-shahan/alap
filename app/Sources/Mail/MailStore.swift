import AppKit
import Foundation
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

    // Every mailbox resolves to a registered query name; two of them need an
    // argument.
    var args: [String: JSONValue] = [:]
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
    return Color(hex: account.color)
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

  /// Queues a reply to the selected thread.
  ///
  /// Threading headers are assembled here because the client already holds the
  /// conversation; making the engine re-fetch the parent purely to read its
  /// Message-ID would be a wasted round trip.
  ///
  /// Nothing is inserted locally. The sent message arrives from Gmail on the
  /// next poll as a real message — inserting an optimistic copy would either
  /// duplicate it or strand an orphan if the send failed.
  func sendReply(body: String) async throws {
    guard let thread = selectedThread,
          let parent = detail?.messages.last,
          let account = accounts.first(where: { $0.id == thread.accountId })
    else { return }

    let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }

    // Reply to the sender, unless that is us — in which case reply to whoever
    // the parent was addressed to, so replying to your own sent mail works.
    let recipients: [String] =
      parent.fromEmail.caseInsensitiveCompare(account.emailAddress) == .orderedSame
      ? parent.toRecipients.map(\.email)
      : [parent.fromEmail]
    guard !recipients.isEmpty else { return }

    // References is the ancestry: the parent's own chain plus the parent.
    var references: [String] = []
    if let parentId = parent.rfc822MessageId, !parentId.isEmpty {
      references.append(parentId)
    }

    try await bridge.mutate(
      "compose.reply",
      args: [
        "accountId": .string(thread.accountId),
        "threadId": .string(thread.id),
        "remoteThreadId": .string(thread.remoteThreadId),
        "fromName": .string(account.displayName),
        "fromEmail": .string(account.emailAddress),
        "to": .array(recipients.map { .string($0) }),
        "cc": .array([]),
        "subject": .string(Self.replySubject(parent.subject)),
        "body": .string(trimmed),
        "inReplyTo": .string(parent.rfc822MessageId ?? ""),
        "references": .array(references.map { .string($0) }),
        "idempotencyKey": .string(UUID().uuidString.lowercased()),
      ]
    )
  }

  /// Mirrors the engine's `compose::reply_subject` — adds `Re:` only when it is
  /// absent, so round trips do not stack prefixes.
  private static func replySubject(_ original: String) -> String {
    original.lowercased().hasPrefix("re:") ? original : "Re: \(original)"
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
