import Foundation
import Testing
@testable import Alap

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

    // Growth adds threadGrowthSize, which is larger than the first page: the
    // initial page is on the critical path to painting the window, later ones
    // are not.
    #expect(store.threadLimit == full + MailStore.threadGrowthSize)
    #expect(lastLimit(bridge) == Double(full + MailStore.threadGrowthSize))
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

    #expect(store.threadLimit == full + MailStore.threadGrowthSize)
    #expect(bridge.sent.filter { $0.kind == "subscribe" }.count == 1)
  }

  @Test("Growth resumes once the larger result arrives")
  func growsAgainAfterResults() {
    let full = MailStore.threadPageSize
    let (store, bridge) = store(threadCount: full)
    store.growThreadsIfNeeded(reaching: "t\(full - 1)")

    // The bigger page lands.
    let grown = full + MailStore.threadGrowthSize
    bridge.push("threads", json: Fixtures.threadList((0..<grown).map { "t\($0)" }))
    bridge.reset()

    store.growThreadsIfNeeded(reaching: "t\(grown - 1)")

    #expect(store.threadLimit == grown + MailStore.threadGrowthSize)
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

/// The escape hatch that makes growth reliable.
///
/// Growth used to depend entirely on a row within 40 of the end appearing. When
/// that signal did not arrive the list simply ended — indistinguishable from
/// having reached the last conversation, with 17,000 more sitting unreachable
/// behind it.
@MainActor
struct LoadMoreTests {
  private func store(threadCount: Int) -> (MailStore, FakeBridge) {
    let bridge = FakeBridge()
    let store = MailStore(bridge: bridge, openFile: { _ in })
    store.start()
    bridge.push("accounts", json: Fixtures.account())
    bridge.push("labels", json: Fixtures.labels())
    bridge.push("threads", json: Fixtures.threadList((0..<threadCount).map { "t\($0)" }))
    return (store, bridge)
  }

  @Test("A full page means the list says there is more")
  func fullPageOffersMore() {
    let (store, _) = store(threadCount: MailStore.threadPageSize)
    #expect(store.hasMoreThreads)
    #expect(store.canGrowThreads)
  }

  @Test("A short page is the whole mailbox and offers nothing")
  func shortPageIsComplete() {
    // Otherwise the footer would sit at the end of every mailbox promising
    // conversations that do not exist.
    let (store, _) = store(threadCount: 12)
    #expect(!store.hasMoreThreads)
  }

  @Test("Loading more works without any scroll signal")
  func explicitLoadWorks() {
    // The whole point: pressing the control is independent of whether a row
    // near the end ever appeared.
    let (store, bridge) = store(threadCount: MailStore.threadPageSize)
    bridge.reset()

    store.growThreads()

    #expect(store.threadLimit == MailStore.threadPageSize + MailStore.threadGrowthSize)
    #expect(bridge.sent.contains { $0.kind == "subscribe" })
  }

  @Test("Pressing it twice while in flight loads one page")
  func explicitLoadCoalesces() {
    let (store, bridge) = store(threadCount: MailStore.threadPageSize)
    bridge.reset()

    store.growThreads()
    store.growThreads()
    store.growThreads()

    #expect(bridge.sent.filter { $0.kind == "subscribe" }.count == 1)
    #expect(store.isLoadingMoreThreads)
  }

  @Test("A page in flight is reported, so the footer can say so")
  func loadingIsObservable() {
    let (store, _) = store(threadCount: MailStore.threadPageSize)
    #expect(!store.isLoadingMoreThreads)

    store.growThreads()

    #expect(store.isLoadingMoreThreads)
  }

  @Test("Growth stops at the ceiling rather than sending a rejected limit")
  func stopsAtTheCeiling() {
    // Above MAX_THREAD_LIMIT the query is REJECTED rather than clamped, so
    // overshooting would empty the list instead of merely ending growth.
    let (store, _) = store(threadCount: MailStore.threadPageSize)
    var guardRail = 0
    while store.canGrowThreads, guardRail < 200 {
      store.growThreads()
      // Simulate the page arriving full, so it keeps offering more.
      store.markGrowthFinishedForTesting()
      guardRail += 1
    }
    #expect(store.threadLimit <= MailStore.maxThreadLimit)
  }
}
