import Foundation
import Testing
@testable import Alap

/// Keyboard triage: selection movement and where you land after archiving.
///
/// The successor is chosen BEFORE the archive mutation, because the optimistic
/// write removes the row from the list immediately. Computing it afterwards
/// reads an index into a list that has already shifted — which lands you on the
/// wrong message, or on nothing. Triage is the app's core loop, so landing in
/// the wrong place is not a cosmetic bug.
@MainActor
struct TriageTests {
  private func store(threads ids: [String]) -> (MailStore, FakeBridge) {
    let bridge = FakeBridge()
    let store = MailStore(bridge: bridge, openFile: { _ in })
    store.start()
    bridge.push("accounts", json: Fixtures.account())
    // Archiving IS the removal of INBOX, so without the label there is no
    // mutation to build and every archive assertion would pass vacuously.
    bridge.push("labels", json: Fixtures.labels())
    bridge.push("threads", json: Fixtures.threadList(ids))
    return (store, bridge)
  }

  // MARK: - Selection

  @Test("Moving down and up walks the list")
  func movesThroughTheList() {
    let (store, _) = store(threads: ["a", "b", "c"])
    store.selectedThreadID = "a"

    store.moveSelection(by: 1)
    #expect(store.selectedThreadID == "b")
    store.moveSelection(by: 1)
    #expect(store.selectedThreadID == "c")
    store.moveSelection(by: -1)
    #expect(store.selectedThreadID == "b")
  }

  @Test("Selection stops at the ends rather than wrapping")
  func clampsAtTheEnds() {
    // Wrapping during fast triage silently sends you back to the top, and you
    // re-read mail you already dealt with.
    let (store, _) = store(threads: ["a", "b", "c"])

    store.selectedThreadID = "c"
    store.moveSelection(by: 1)
    #expect(store.selectedThreadID == "c")

    store.selectedThreadID = "a"
    store.moveSelection(by: -1)
    #expect(store.selectedThreadID == "a")
  }

  @Test("Moving with nothing selected selects the first thread")
  func selectsFirstFromEmpty() {
    let (store, _) = store(threads: ["a", "b"])
    store.selectedThreadID = nil

    store.moveSelection(by: 1)

    #expect(store.selectedThreadID == "a")
  }

  @Test("Moving in an empty list selects nothing and does not crash")
  func handlesAnEmptyList() {
    let (store, _) = store(threads: [])
    store.moveSelection(by: 1)
    #expect(store.selectedThreadID == nil)
  }

  @Test("Selecting a thread exposes the row, not just the id")
  func selectionResolvesTheRow() {
    let (store, _) = store(threads: ["a", "b"])
    store.selectedThreadID = "b"
    #expect(store.selectedThread?.id == "b")
  }

  // MARK: - Archive and advance

  @Test("Archiving advances to the row below")
  func advancesDownward() async {
    let (store, _) = store(threads: ["a", "b", "c"])
    store.selectedThreadID = "b"

    await store.archiveSelectedAndAdvance()

    #expect(store.selectedThreadID == "c")
  }

  @Test("Archiving the last row falls back to the one above")
  func fallsBackUpward() async {
    // There is nothing below, and leaving the selection on an archived thread
    // would show a message that is no longer in this mailbox.
    let (store, _) = store(threads: ["a", "b", "c"])
    store.selectedThreadID = "c"

    await store.archiveSelectedAndAdvance()

    #expect(store.selectedThreadID == "b")
  }

  @Test("Archiving the only row selects nothing")
  func clearsSelectionWhenTheListEmpties() async {
    let (store, _) = store(threads: ["a"])
    store.selectedThreadID = "a"

    await store.archiveSelectedAndAdvance()

    #expect(store.selectedThreadID == nil)
  }

  @Test("Archiving nothing does nothing")
  func requiresASelection() async {
    let (store, bridge) = store(threads: ["a", "b"])
    store.selectedThreadID = nil
    bridge.reset()

    await store.archiveSelectedAndAdvance()

    #expect(bridge.mutations(named: "threads.archive").isEmpty)
  }

  @Test("Archive removes INBOX from the selected thread")
  func archiveIssuesTheMutation() async {
    let (store, bridge) = store(threads: ["a", "b"])
    store.selectedThreadID = "a"
    bridge.reset()

    await store.archiveSelectedAndAdvance()

    let calls = bridge.mutations(named: "threads.archive")
    #expect(calls.count == 1)
    #expect(calls.first?.args["threadIds"] == .array([.string("a")]))
  }

  // MARK: - Mailboxes

  @Test("Changing mailbox clears the selection")
  func mailboxChangeResetsSelection() {
    // The selected thread is unlikely to exist in the new mailbox, and keeping
    // it would leave the reading pane showing something the list does not.
    let (store, _) = store(threads: ["a", "b"])
    store.selectedThreadID = "a"

    store.selectedMailbox = .unread

    #expect(store.selectedThreadID == nil)
  }

  @Test("Changing mailbox re-subscribes the thread list")
  func mailboxChangeResubscribes() {
    let (store, bridge) = store(threads: ["a"])
    bridge.reset()

    store.selectedMailbox = .archived

    #expect(bridge.subscribedQueries().contains { $0.hasPrefix("threads.") })
  }

  @Test("Searching is off until there is non-whitespace text",
        arguments: [("", false), ("   ", false), ("invoice", true)])
  func searchingReflectsRealInput(text: String, expected: Bool) {
    let (store, _) = store(threads: [])
    store.searchText = text
    #expect(store.isSearching == expected)
  }
}

/// Selecting several conversations and acting on all of them.
///
/// The expensive mistake here is not a wrong result, it is a wrong SHAPE:
/// looping a single-thread mutation over fifty rows produces fifty outbox rows
/// and fifty Gmail calls, when batchModify takes a thousand ids at once.
@MainActor
struct BulkActionTests {
  private func store(threadCount: Int, accounts: [String] = ["acct_1"])
    -> (MailStore, FakeBridge)
  {
    let bridge = FakeBridge()
    let store = MailStore(bridge: bridge, openFile: { _ in })
    store.start()
    bridge.push("accounts", json: Fixtures.account())

    let labelJSON = accounts.map { Fixtures.labels(accountId: $0) }
      .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "[]\n ")) }
      .joined(separator: ",")
    bridge.push("labels", json: "[\(labelJSON)]")

    let rows = (0..<threadCount).map { index -> String in
      Fixtures.thread(id: "t\(index)", accountId: accounts[index % accounts.count])
    }
    bridge.push("threads", json: "[\(rows.joined(separator: ","))]")
    return (store, bridge)
  }

  @Test("Selecting all takes every loaded thread")
  func selectAllTakesEverything() {
    // Every LOADED thread. The list grows as it scrolls, so "all" cannot
    // honestly mean rows that were never fetched.
    let (store, _) = store(threadCount: 12)
    store.selectAll()
    #expect(store.selectionCount == 12)
  }

  @Test("A bulk archive is ONE mutation, not one per thread")
  func archiveIsBatched() async {
    let (store, bridge) = store(threadCount: 40)
    store.selectAll()
    bridge.reset()

    await store.archiveSelection()

    let calls = bridge.mutations(named: "threads.archive")
    #expect(calls.count == 1, "40 threads produced \(calls.count) mutations")
    guard case .array(let ids)? = calls.first?.args["threadIds"] else {
      Issue.record("no threadIds sent"); return
    }
    #expect(ids.count == 40)
  }

  @Test("Threads are grouped by account, since a Gmail call belongs to one")
  func groupsByAccount() async {
    // The INBOX label id differs per mailbox and batchModify addresses a single
    // account, so one mutation per account is the floor — not one overall.
    let (store, bridge) = store(threadCount: 6, accounts: ["acct_1", "acct_2"])
    store.selectAll()
    bridge.reset()

    await store.archiveSelection()

    #expect(bridge.mutations(named: "threads.archive").count == 2)
  }

  @Test("Trash actually trashes rather than archiving")
  func trashIsNotArchive() async {
    // It used to call threads.archive, which only removes INBOX — so Trash
    // filed mail into All Mail and deleted nothing.
    let (store, bridge) = store(threadCount: 3)
    store.selectAll()
    bridge.reset()

    await store.trashSelection()

    #expect(bridge.mutations(named: "threads.trash").count == 1)
    #expect(bridge.mutations(named: "threads.archive").isEmpty)
  }

  @Test("A mixed selection flags rather than inverting row by row")
  func flaggingPicksOneDirection() async {
    // Toggling each row independently turns a mixed selection into a
    // differently-mixed one, which is not what "flag these" means.
    let bridge = FakeBridge()
    let store = MailStore(bridge: bridge, openFile: { _ in })
    store.start()
    bridge.push("accounts", json: Fixtures.account())
    bridge.push("labels", json: Fixtures.labels())
    bridge.push("threads", json: """
      [\(Fixtures.thread(id: "a", isStarred: true)),\(Fixtures.thread(id: "b"))]
      """)
    store.selectAll()
    bridge.reset()

    await store.toggleFlagOnSelection()

    let call = bridge.mutations(named: "threads.setStarred").first
    #expect(call?.args["isStarred"] == .bool(true), "any unflagged row means flag")
  }

  @Test("An all-flagged selection unflags")
  func allFlaggedUnflags() async {
    let bridge = FakeBridge()
    let store = MailStore(bridge: bridge, openFile: { _ in })
    store.start()
    bridge.push("accounts", json: Fixtures.account())
    bridge.push("labels", json: Fixtures.labels())
    bridge.push("threads", json: """
      [\(Fixtures.thread(id: "a", isStarred: true)),\(Fixtures.thread(id: "b", isStarred: true))]
      """)
    store.selectAll()
    bridge.reset()

    await store.toggleFlagOnSelection()

    #expect(bridge.mutations(named: "threads.setStarred").first?.args["isStarred"]
            == .bool(false))
  }

  @Test("Acting on an empty selection does nothing")
  func emptySelectionIsANoOp() async {
    let (store, bridge) = store(threadCount: 5)
    store.clearSelection()
    bridge.reset()

    await store.archiveSelection()
    await store.trashSelection()
    await store.toggleFlagOnSelection()

    #expect(bridge.sent.filter { $0.kind == "mutate" }.isEmpty)
  }

  @Test("Selecting one thread still drives the reading pane")
  func singleSelectionStillOpensAThread() {
    // Multi-select must not cost the ordinary case: one selected row is still
    // one message in the reading pane.
    let (store, _) = store(threadCount: 5)
    store.selection = ["t2"]
    #expect(store.selectedThreadID == "t2")
    #expect(!store.hasMultipleSelected)
  }

  @Test("Several selected means no single message to show")
  func multiSelectionClearsTheReadingPane() {
    let (store, _) = store(threadCount: 5)
    store.selection = ["t1", "t2"]
    #expect(store.selectedThreadID == nil)
    #expect(store.hasMultipleSelected)
  }

  @Test("Keyboard navigation collapses the selection rather than adding to it")
  func keyboardNavigationCollapses() {
    let (store, _) = store(threadCount: 5)
    store.selectAll()

    store.selectedThreadID = "t3"

    #expect(store.selection == ["t3"], "J/K should move, not accumulate")
  }
}
