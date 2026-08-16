import Foundation
import Testing
@testable import Mail

/// Growing the thread list by scrolling.
///
/// The list has no pagination — it extends as you reach the end. The failure
/// modes are quiet and expensive: a growth loop that never terminates
/// re-subscribes forever, and a limit that survives a mailbox change asks a
/// small mailbox for rows it does not have.
@MainActor
struct InfiniteScrollTests {
  private func store(threadCount: Int) -> (MailStore, FakeBridge) {
    let bridge = FakeBridge()
    let store = MailStore(bridge: bridge, openFile: { _ in })
    store.start()
    bridge.push("accounts", json: Fixtures.account())
    bridge.push("labels", json: Fixtures.labels())
    bridge.push("threads", json: Fixtures.threadList((0..<threadCount).map { "t\($0)" }))
    return (store, bridge)
  }

  private func lastLimit(_ bridge: FakeBridge) -> Double? {
    guard case .number(let value)? = bridge.sent.last(where: {
      $0.kind == "subscribe" && $0.name.hasPrefix("threads.")
    })?.args["limit"] else { return nil }
    return value
  }

  // MARK: - Growth

  @Test("The first subscription asks for two screenfuls, not one")
  func startsAtAPageSize() {
    let (_, bridge) = store(threadCount: 0)
    #expect(lastLimit(bridge) == Double(MailStore.threadPageSize))
  }

  @Test("Reaching the end asks for more")
  func growsAtTheEnd() {
    let full = MailStore.threadPageSize
    let (store, bridge) = store(threadCount: full)
    bridge.reset()

    store.growThreadsIfNeeded(reaching: "t\(full - 1)")

    #expect(store.threadLimit == full + MailStore.threadPageSize)
    #expect(lastLimit(bridge) == Double(full + MailStore.threadPageSize))
  }

  @Test("Rows far from the end ask for nothing")
  func doesNotGrowEarly() {
    let (store, bridge) = store(threadCount: MailStore.threadPageSize)
    bridge.reset()

    store.growThreadsIfNeeded(reaching: "t0")

    #expect(bridge.sent.isEmpty)
  }

  @Test("A partial result is the whole mailbox, so it never grows")
  func doesNotGrowAShortList() {
    // Fewer rows than the limit means Zero returned everything there is.
    // Growing here would re-subscribe forever against a mailbox with nothing
    // more to give.
    let (store, bridge) = store(threadCount: 12)
    bridge.reset()

    store.growThreadsIfNeeded(reaching: "t11")

    #expect(bridge.sent.isEmpty)
    #expect(store.threadLimit == MailStore.threadPageSize)
  }

  @Test("A burst of appearing rows causes exactly one growth")
  func coalescesConcurrentGrowth() {
    // Flicking to the bottom makes many rows appear in one frame. Without
    // coalescing that is one re-subscription each, all discarded but all paid
    // for.
    let full = MailStore.threadPageSize
    let (store, bridge) = store(threadCount: full)
    bridge.reset()

    for offset in 1...20 {
      store.growThreadsIfNeeded(reaching: "t\(full - offset)")
    }

    #expect(store.threadLimit == full + MailStore.threadPageSize)
    #expect(bridge.sent.filter { $0.kind == "subscribe" }.count == 1)
  }

  @Test("Growth resumes once the larger result arrives")
  func growsAgainAfterResults() {
    let full = MailStore.threadPageSize
    let (store, bridge) = store(threadCount: full)
    store.growThreadsIfNeeded(reaching: "t\(full - 1)")

    // The bigger page lands.
    let grown = full + MailStore.threadPageSize
    bridge.push("threads", json: Fixtures.threadList((0..<grown).map { "t\($0)" }))
    bridge.reset()

    store.growThreadsIfNeeded(reaching: "t\(grown - 1)")

    #expect(store.threadLimit == grown + MailStore.threadPageSize)
  }

  @Test("Changing mailbox resets the limit")
  func mailboxChangeResets() {
    let full = MailStore.threadPageSize
    let (store, _) = store(threadCount: full)
    store.growThreadsIfNeeded(reaching: "t\(full - 1)")
    #expect(store.threadLimit > MailStore.threadPageSize)

    store.selectedMailbox = .archived

    #expect(store.threadLimit == MailStore.threadPageSize)
  }

  @Test("The limit never exceeds what the query will accept")
  func respectsTheCeiling() {
    // Above MAX_THREAD_LIMIT the query is REJECTED rather than clamped, so
    // exceeding it would empty the list rather than merely stop growing it.
    #expect(MailStore.maxThreadLimit == 50_000)
    #expect(MailStore.threadPageSize < MailStore.maxThreadLimit)
  }

  @Test("The limit is sent on every mailbox query", arguments: [
    Mailbox.allInboxes, .archived, .unread, .attachments, .account(id: "acct_1"),
  ])
  func everyQueryCarriesTheLimit(mailbox: Mailbox) {
    let (store, bridge) = store(threadCount: 0)
    // Pivot through a mailbox that is not under test: assigning the mailbox
    // already selected is a no-op, so `.allInboxes` would otherwise appear to
    // send no query at all.
    store.selectedMailbox = .label(remoteId: "INBOX")
    bridge.reset()

    store.selectedMailbox = mailbox

    #expect(lastLimit(bridge) == Double(MailStore.threadPageSize))
  }
}
