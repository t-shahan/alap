import Foundation
import Testing
@testable import Mail

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
    #expect(calls.first?.args["threadId"] == .string("a"))
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
