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

/// Selection as the UI presents it.
///
/// These pin the states the interface has to draw. The bug they exist to catch
/// was not a wrong action — it was selection that worked and rendered nothing,
/// because the row background only ever consulted the single focused id.
@MainActor
struct SelectionVisibilityTests {
  private func store(threadCount: Int) -> (MailStore, FakeBridge) {
    let bridge = FakeBridge()
    let store = MailStore(bridge: bridge, openFile: { _ in })
    store.start()
    bridge.push("accounts", json: Fixtures.account())
    bridge.push("labels", json: Fixtures.labels())
    bridge.push("threads", json: Fixtures.threadList((0..<threadCount).map { "t\($0)" }))
    return (store, bridge)
  }

  @Test("A selected row is in the selection even when it is not the focused one")
  func selectedRowsAreQueryable() {
    // The row background asks `selection.contains`. If membership were only
    // knowable through `selectedThreadID`, every row but one would draw as
    // unselected — which is exactly what happened.
    let (store, _) = store(threadCount: 5)
    store.selection = ["t1", "t3"]

    #expect(store.selection.contains("t1"))
    #expect(store.selection.contains("t3"))
    #expect(!store.selection.contains("t2"))
    #expect(store.selectedThreadID == nil, "no single row is focused")
  }

  @Test("Toggling extends the selection without moving the reading pane")
  func toggleDoesNotNavigate() {
    // A checkbox adds to a selection; it does not navigate. Ticking a second
    // row while reading the first must not change what is being read.
    let (store, _) = store(threadCount: 5)
    store.selectedThreadID = "t0"

    store.toggleSelection(of: "t2")

    #expect(store.selection == ["t0", "t2"])
  }

  @Test("Toggling a selected thread removes it")
  func toggleRemoves() {
    let (store, _) = store(threadCount: 5)
    store.selection = ["t1", "t2"]

    store.toggleSelection(of: "t1")

    #expect(store.selection == ["t2"])
  }

  @Test("The bulk bar appears only once there is more than one")
  func barAppearsForRealBulk() {
    // One selected row is ordinary reading, not a bulk operation, and a bar
    // over it would be chrome announcing nothing.
    let (store, _) = store(threadCount: 5)

    #expect(!store.hasMultipleSelected)
    store.selection = ["t1"]
    #expect(!store.hasMultipleSelected)
    store.selection = ["t1", "t2"]
    #expect(store.hasMultipleSelected)
  }

  @Test("Clearing the selection also releases the reading pane")
  func clearingResetsEverything() {
    let (store, _) = store(threadCount: 5)
    store.selectAll()

    store.clearSelection()

    #expect(store.selection.isEmpty)
    #expect(store.selectedThreadID == nil)
  }

  @Test("Selecting all then acting leaves nothing selected")
  func selectionEmptiesAfterABulkAction() async {
    // A stale selection after the rows are gone would leave the bar claiming a
    // count for threads that are no longer in the list.
    let (store, _) = store(threadCount: 6)
    store.selectAll()

    await store.archiveSelection()

    #expect(store.selection.isEmpty)
  }
}

/// What the bulk panel tells you before you act.
///
/// The panel exists because a bulk action is the one place a mistake is
/// multiplied. "2 selected" is a count; knowing WHICH two, and what the action
/// would actually change, is a confirmation.
@MainActor
struct BulkPanelTests {
  private func store(_ specs: [(id: String, unread: Bool, flagged: Bool)])
    -> (MailStore, FakeBridge)
  {
    let bridge = FakeBridge()
    let store = MailStore(bridge: bridge, openFile: { _ in })
    store.start()
    bridge.push("accounts", json: Fixtures.account())
    bridge.push("labels", json: Fixtures.labels())
    let rows = specs.map {
      Fixtures.thread(id: $0.id, unreadCount: $0.unread ? 1 : 0, isStarred: $0.flagged)
    }
    bridge.push("threads", json: "[\(rows.joined(separator: ","))]")
    return (store, bridge)
  }

  @Test("Selected threads are exposed in list order, not set order")
  func selectedThreadsAreOrdered() {
    // The panel lists them. A Set has no order, so reading it directly would
    // shuffle the preview between renders.
    let (store, _) = store([("a", true, false), ("b", false, false), ("c", true, false)])
    store.selection = ["c", "a"]

    #expect(store.selectedThreads.map(\.id) == ["a", "c"])
  }

  @Test("Mark read resolves to one direction for a mixed selection")
  func markReadDirection() async {
    // Any unread row means the action is "mark read". The panel's label has to
    // agree with what the action does, or it misreports its own effect.
    let (store, bridge) = store([("a", true, false), ("b", false, false)])
    store.selectAll()
    bridge.reset()

    await store.markSelectionRead()

    #expect(bridge.mutations(named: "threads.setRead").first?.args["isRead"] == .bool(true))
  }

  @Test("An all-read selection marks unread instead")
  func allReadFlips() async {
    let (store, bridge) = store([("a", false, false), ("b", false, false)])
    store.selectAll()
    bridge.reset()

    await store.markSelectionRead()

    #expect(bridge.mutations(named: "threads.setRead").first?.args["isRead"] == .bool(false))
  }

  @Test("The panel replaces the reading pane only past one selection")
  func panelOnlyForRealBulk() {
    // One selected row is ordinary reading and must still open the message.
    let (store, _) = store([("a", true, false), ("b", true, false)])

    store.selection = ["a"]
    #expect(!store.hasMultipleSelected)
    #expect(store.selectedThreadID == "a")

    store.selection = ["a", "b"]
    #expect(store.hasMultipleSelected)
  }

  @Test("Acting from the panel returns to reading the next conversation")
  func actingReturnsToReading() async {
    // Not an empty selection — the successor is focused, exactly as a single
    // archive advances. That leaves ONE row selected, so the panel closes and
    // the reading pane shows the next message rather than an empty state. The
    // point of triage is that the next thing is already in front of you.
    let (store, _) = store([("a", true, false), ("b", true, false), ("c", true, false)])
    store.selection = ["a", "b"]

    await store.archiveSelection()

    #expect(!store.hasMultipleSelected, "the panel should no longer be showing")
    #expect(store.selectedThreadID == "c", "focus should advance past the archived block")
  }
}

/// Nothing is selected until the user selects something.
@MainActor
struct InitialSelectionTests {
  @Test("A loaded mailbox selects nothing")
  func doesNotAutoSelect() {
    // The app used to open with the newest conversation already displayed. It
    // was justified as giving the keyboard "an anchor to move from", which was
    // simply wrong — moveSelection already selects the first row when nothing
    // is selected. So it opened someone's mail for them for no reason.
    let bridge = FakeBridge()
    let store = MailStore(bridge: bridge, openFile: { _ in })
    store.start()
    bridge.push("accounts", json: Fixtures.account())
    bridge.push("labels", json: Fixtures.labels())
    bridge.push("threads", json: Fixtures.threadList(["a", "b", "c"]))

    #expect(store.selectedThreadID == nil)
    #expect(store.selection.isEmpty)
  }

  @Test("The keyboard still works from nothing selected")
  func arrowKeysStillHaveAnAnchor() {
    let bridge = FakeBridge()
    let store = MailStore(bridge: bridge, openFile: { _ in })
    store.start()
    bridge.push("accounts", json: Fixtures.account())
    bridge.push("labels", json: Fixtures.labels())
    bridge.push("threads", json: Fixtures.threadList(["a", "b", "c"]))

    store.moveSelection(by: 1)

    #expect(store.selectedThreadID == "a")
  }

  @Test("Switching mailbox does not open a message either")
  func mailboxChangeDoesNotAutoSelect() {
    let bridge = FakeBridge()
    let store = MailStore(bridge: bridge, openFile: { _ in })
    store.start()
    bridge.push("accounts", json: Fixtures.account())
    bridge.push("labels", json: Fixtures.labels())
    bridge.push("threads", json: Fixtures.threadList(["a", "b"]))
    store.selectedThreadID = "a"

    store.selectedMailbox = .archived
    bridge.push("threads", json: Fixtures.threadList(["x", "y"]))

    #expect(store.selectedThreadID == nil)
  }
}

/// When toolbar actions are available.
///
/// These pin the predicates the buttons are enabled by. The bug they exist to
/// catch was one shared rule — `selectedThread == nil` — used for every button,
/// which disabled Select All exactly when nothing was selected and disabled
/// every bulk action once several were. Both stayed invisible while the app
/// auto-selected a thread on launch, so the rule was never wrong in practice
/// until that stopped.
@MainActor
struct ToolbarAvailabilityTests {
  private func store(_ ids: [String]) -> (MailStore, FakeBridge) {
    let bridge = FakeBridge()
    let store = MailStore(bridge: bridge, openFile: { _ in })
    store.start()
    bridge.push("accounts", json: Fixtures.account())
    bridge.push("labels", json: Fixtures.labels())
    bridge.push("threads", json: Fixtures.threadList(ids))
    return (store, bridge)
  }

  @Test("Select All works when nothing is selected — which is the whole point")
  func selectAllAvailableFromEmpty() {
    let (store, _) = store(["a", "b", "c"])
    #expect(store.selection.isEmpty)
    #expect(store.canSelectAll)
  }

  @Test("Select All is unavailable once everything already is")
  func selectAllUnavailableWhenComplete() {
    let (store, _) = store(["a", "b"])
    store.selectAll()
    #expect(!store.canSelectAll)
  }

  @Test("Select All is unavailable in an empty mailbox")
  func selectAllUnavailableWhenEmpty() {
    let (store, _) = store([])
    #expect(!store.canSelectAll)
  }

  @Test("Bulk actions stay available with several selected")
  func bulkActionsAvailableDuringMultiSelect() {
    // The regression: `selectedThread` is deliberately nil past one selection,
    // so a rule keyed on it switched the actions off during precisely the
    // operation they exist for.
    let (store, _) = store(["a", "b", "c"])
    store.selectAll()

    #expect(store.selectedThread == nil, "no single thread when several are selected")
    #expect(store.hasSelection, "but the actions must still be available")
  }

  @Test("Bulk actions are available for a single selection too")
  func bulkActionsAvailableForOne() {
    let (store, _) = store(["a", "b"])
    store.selectedThreadID = "a"
    #expect(store.hasSelection)
  }

  @Test("Bulk actions are unavailable with nothing selected")
  func bulkActionsUnavailableWhenEmpty() {
    let (store, _) = store(["a", "b"])
    #expect(!store.hasSelection)
  }
}
