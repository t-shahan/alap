import Foundation
import Testing
@testable import Alap

/// The attachment state machine and one-click open.
///
/// This is the logic that decides whether clicking a chip downloads, opens, or
/// does nothing — and it reads from two independent sources that can disagree:
/// the outbox row in Postgres, and the file on disk. The disagreement is not
/// hypothetical. The blob cache lives under `~/Library/Caches`, so macOS can
/// delete the file while the row still claims it was downloaded.
@MainActor
struct AttachmentStateTests {
  /// Records files the store asked the system to open.
  final class Opened: @unchecked Sendable {
    private(set) var urls: [URL] = []
    func record(_ url: URL) { urls.append(url) }
  }

  /// A store with one thread selected and one attachment in the reading pane.
  private func storeWithAttachment(
    _ attachmentJSON: String, opened: Opened = Opened()
  ) -> (MailStore, FakeBridge) {
    let bridge = FakeBridge()
    let store = MailStore(bridge: bridge, openFile: { opened.record($0) })
    store.start()

    bridge.push("threads", json: Fixtures.threadList(["th1"]))
    store.selectedThreadID = "th1"
    // The detail subscription is debounced; apply it now rather than sleeping.
    store.flushPendingSubscriptions()
    bridge.push(
      "detail",
      json: Fixtures.detail(messages: [Fixtures.message(id: "m1", attachments: [attachmentJSON])])
    )
    return (store, bridge)
  }

  private func attachment(in store: MailStore) -> AttachmentRow {
    store.detail!.messages.flatMap(\.attachments).first!
  }

  // MARK: - State

  @Test("Not downloaded and nothing queued reads as idle")
  func idleWhenNothingHasHappened() {
    let (store, _) = storeWithAttachment(Fixtures.attachment(id: "a1"))
    #expect(store.state(of: attachment(in: store)) == .idle)
  }

  @Test("A pending or in-flight outbox row reads as downloading")
  func downloadingWhileOutboxRowIsLive() {
    let (store, bridge) = storeWithAttachment(Fixtures.attachment(id: "a1"))

    for status in ["pending", "in_flight"] {
      bridge.push("outbox", json: "[\(Fixtures.outbox(id: "download|a1", status: status))]")
      #expect(store.state(of: attachment(in: store)) == .downloading, "status \(status)")
    }
  }

  @Test("A file on disk reads as ready")
  func readyWhenTheFileExists() {
    let file = Fixtures.temporaryFile()
    defer { try? FileManager.default.removeItem(at: file) }

    let (store, _) = storeWithAttachment(
      Fixtures.attachment(id: "a1", localPath: file.path, contentHash: String(repeating: "a", count: 64))
    )
    #expect(store.state(of: attachment(in: store)) == .ready(file))
  }

  @Test("A recorded path whose file is gone reads as idle, not ready")
  func doesNotTrustTheRowOverTheDisk() {
    // The exact case macOS creates by reclaiming ~/Library/Caches. Trusting
    // the row here would mean handing Launch Services a path to nothing.
    let (store, _) = storeWithAttachment(
      Fixtures.attachment(id: "a1", localPath: "/tmp/definitely-not-here-\(UUID()).pdf")
    )
    #expect(store.state(of: attachment(in: store)) == .idle)
  }

  @Test("A failed outbox row surfaces its error")
  func failedCarriesTheReason() {
    let (store, bridge) = storeWithAttachment(Fixtures.attachment(id: "a1"))
    bridge.push(
      "outbox",
      json: "[\(Fixtures.outbox(id: "download|a1", status: "failed", lastError: "404 not found"))]"
    )
    #expect(store.state(of: attachment(in: store)) == .failed("404 not found"))
  }

  @Test("An attachment Gmail cannot serve reads as unavailable")
  func unavailableWithoutARemoteId() {
    // Gmail inlines very small parts into the message body rather than
    // exposing an attachment id. There is genuinely nothing to fetch, and
    // offering a download that can only fail would be a lie.
    let (store, _) = storeWithAttachment(
      Fixtures.attachment(id: "a1", remoteAttachmentId: nil)
    )
    #expect(store.state(of: attachment(in: store)) == .unavailable)
  }

  @Test("Disk wins over a stale outbox row")
  func readyEvenWhileAnOutboxRowLingers() {
    let file = Fixtures.temporaryFile()
    defer { try? FileManager.default.removeItem(at: file) }

    let (store, bridge) = storeWithAttachment(
      Fixtures.attachment(id: "a1", localPath: file.path)
    )
    // The engine finished, but the row has not been cleaned up yet. The file
    // being present is the only thing that actually matters.
    bridge.push("outbox", json: "[\(Fixtures.outbox(id: "download|a1", status: "pending"))]")
    #expect(store.state(of: attachment(in: store)) == .ready(file))
  }

  // MARK: - Requesting a download

  @Test("Requesting a download calls the mutator with the attachment id")
  func downloadIssuesTheMutation() async {
    let (store, bridge) = storeWithAttachment(Fixtures.attachment(id: "a1"))
    bridge.reset()

    await store.downloadAttachment(attachment(in: store))

    let calls = bridge.mutations(named: "attachments.download")
    #expect(calls.count == 1)
    #expect(calls.first?.args["attachmentId"] == .string("a1"))
    #expect(calls.first?.args["accountId"] == .string("acct_1"))
  }

  @Test("Opening something not yet downloaded requests it")
  func openDownloadsFirst() async {
    let (store, bridge) = storeWithAttachment(Fixtures.attachment(id: "a1"))
    bridge.reset()

    await store.openAttachment(attachment(in: store))

    #expect(bridge.mutations(named: "attachments.download").count == 1)
  }

  @Test("Opening something Gmail cannot serve requests nothing")
  func openDoesNotQueueTheUnservable() async {
    let (store, bridge) = storeWithAttachment(
      Fixtures.attachment(id: "a1", remoteAttachmentId: nil)
    )
    bridge.reset()

    await store.openAttachment(attachment(in: store))

    #expect(bridge.mutations(named: "attachments.download").isEmpty)
  }

  // MARK: - One-click open
  //
  // The download lands asynchronously through the subscription rather than by
  // returning from the call, so the store arms an intent and fires it when the
  // bytes appear. These cover the arming, not NSWorkspace itself.

  @Test("One click: the file opens by itself once the bytes arrive")
  func pendingOpenFiresWhenTheFileArrives() async {
    let opened = Opened()
    let (store, bridge) = storeWithAttachment(Fixtures.attachment(id: "a1"), opened: opened)

    await store.openAttachment(attachment(in: store))
    #expect(store.isAwaitingOpen("a1"), "click should have armed a pending open")
    #expect(opened.urls.isEmpty, "nothing should open before the bytes exist")

    // The engine records local_path, and that row replicates back.
    let file = Fixtures.temporaryFile()
    defer { try? FileManager.default.removeItem(at: file) }
    bridge.push(
      "detail",
      json: Fixtures.detail(messages: [
        Fixtures.message(
          id: "m1",
          attachments: [Fixtures.attachment(id: "a1", localPath: file.path)]
        )
      ])
    )

    #expect(opened.urls == [file], "the downloaded file should have opened itself")
    // Cleared before opening, so a further update cannot launch it twice.
    #expect(!store.isAwaitingOpen("a1"))
  }

  @Test("A repeated update does not open the same file twice")
  func doesNotOpenTwice() async {
    let opened = Opened()
    let (store, bridge) = storeWithAttachment(Fixtures.attachment(id: "a1"), opened: opened)
    await store.openAttachment(attachment(in: store))

    let file = Fixtures.temporaryFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let arrived = Fixtures.detail(messages: [
      Fixtures.message(id: "m1",
                       attachments: [Fixtures.attachment(id: "a1", localPath: file.path)])
    ])

    // Zero pushes an update per change, and several can describe the same row.
    bridge.push("detail", json: arrived)
    bridge.push("detail", json: arrived)

    #expect(opened.urls.count == 1)
  }

  @Test("An update without the file leaves the pending open armed")
  func staysArmedUntilTheFileIsActuallyThere() async {
    let (store, bridge) = storeWithAttachment(Fixtures.attachment(id: "a1"))
    await store.openAttachment(attachment(in: store))

    // A path recorded but no file — the download is not done.
    bridge.push(
      "detail",
      json: Fixtures.detail(messages: [
        Fixtures.message(
          id: "m1",
          attachments: [Fixtures.attachment(id: "a1", localPath: "/tmp/nope-\(UUID()).pdf")]
        )
      ])
    )

    #expect(store.isAwaitingOpen("a1"))
  }

  @Test("A permanently failed download disarms the pending open")
  func failureDisarms() async {
    // Otherwise the request sits armed and fires later against a click the
    // user made minutes ago.
    let (store, bridge) = storeWithAttachment(Fixtures.attachment(id: "a1"))
    await store.openAttachment(attachment(in: store))
    #expect(store.isAwaitingOpen("a1"))

    bridge.push(
      "outbox",
      json: "[\(Fixtures.outbox(id: "download|a1", status: "failed", lastError: "gone"))]"
    )

    #expect(!store.isAwaitingOpen("a1"))
  }

  @Test("Opening something already on disk arms nothing")
  func alreadyDownloadedOpensImmediately() async {
    let file = Fixtures.temporaryFile()
    defer { try? FileManager.default.removeItem(at: file) }

    let opened = Opened()
    let (store, bridge) = storeWithAttachment(
      Fixtures.attachment(id: "a1", localPath: file.path), opened: opened
    )
    bridge.reset()

    await store.openAttachment(attachment(in: store))

    #expect(opened.urls == [file], "it should open straight away")
    #expect(!store.isAwaitingOpen("a1"))
    #expect(bridge.mutations(named: "attachments.download").isEmpty,
            "a file already on disk must not be re-fetched")
  }
}
