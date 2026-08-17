import Foundation
import Testing
@testable import Alap

/// Reversing triage actions.
///
/// Archive and Trash were one-way from inside the app — repairing a mis-keyed
/// `E` meant leaving for Gmail. Bulk sharpened that: the same slip now moves
/// fifty conversations.
@MainActor
struct UndoTests {
  private func store(_ ids: [String]) -> (MailStore, FakeBridge) {
    let bridge = FakeBridge()
    let store = MailStore(bridge: bridge, openFile: { _ in })
    store.start()
    bridge.push("accounts", json: Fixtures.account())
    bridge.push("labels", json: Fixtures.labels())
    bridge.push("threads", json: Fixtures.threadList(ids))
    return (store, bridge)
  }

  // MARK: - Reversal

  @Test("Archiving can be undone, and undoing restores")
  func archiveIsReversible() async {
    let (store, bridge) = store(["a", "b", "c"])
    store.selection = ["a", "b"]
    await store.archiveSelection()
    #expect(store.undoStack.top != nil)
    bridge.reset()

    await store.undoStack.undo()

    let calls = bridge.mutations(named: "threads.restore")
    #expect(calls.count == 1)
    guard case .array(let ids)? = calls.first?.args["threadIds"] else {
      Issue.record("no threadIds"); return
    }
    #expect(ids.count == 2)
  }

  @Test("Trashing can be undone by the same restore")
  func trashIsReversible() async {
    // Archive removes INBOX; trash removes INBOX and adds TRASH. Restoring is
    // "add INBOX, remove TRASH" for both, because adding a label already
    // present or removing one already gone is a no-op in Gmail.
    let (store, bridge) = store(["a", "b"])
    store.selection = ["a"]
    await store.trashSelection()
    bridge.reset()

    await store.undoStack.undo()

    #expect(bridge.mutations(named: "threads.restore").count == 1)
  }

  @Test("Marking read is undone by marking unread")
  func readIsReversible() async {
    let (store, bridge) = store(["a", "b"])
    store.selectAll()
    await store.setRead(store.selectedThreads, isRead: true)
    bridge.reset()

    await store.undoStack.undo()

    #expect(bridge.mutations(named: "threads.setRead").first?.args["isRead"] == .bool(false))
  }

  @Test("Flagging is undone by unflagging")
  func flagIsReversible() async {
    let (store, bridge) = store(["a"])
    store.selectAll()
    await store.setStarred(store.selectedThreads, isStarred: true)
    bridge.reset()

    await store.undoStack.undo()

    #expect(bridge.mutations(named: "threads.setStarred").first?.args["isStarred"]
            == .bool(false))
  }

  // MARK: - The traps

  @Test("Undoing does not itself become undoable")
  func undoDoesNotRecurse() async {
    // Otherwise ⌘Z flips the same action back and forth forever, and the user
    // can never actually get back to where they were.
    let (store, _) = store(["a"])
    store.selectAll()
    await store.setRead(store.selectedThreads, isRead: true)

    await store.undoStack.undo()

    #expect(store.undoStack.top == nil)
  }

  @Test("Undoing twice reverses once")
  func undoIsNotRepeatable() async {
    // Reversing takes time, and a second ⌘Z arriving during it would otherwise
    // reverse the same action twice — harmless for archive, not for trash.
    let (store, bridge) = store(["a", "b"])
    store.selection = ["a"]
    await store.trashSelection()
    bridge.reset()

    await store.undoStack.undo()
    await store.undoStack.undo()

    #expect(bridge.mutations(named: "threads.restore").count == 1)
  }

  @Test("Undo with nothing to undo does nothing")
  func emptyUndoIsSafe() async {
    let (store, bridge) = store(["a"])
    bridge.reset()

    await store.undoStack.undo()

    #expect(bridge.sent.filter { $0.kind == "mutate" }.isEmpty)
  }

  @Test("A newer action replaces the older one")
  func stackDepthIsOne() async {
    // Deliberately one deep. Undoing several mail operations in sequence means
    // reversing them against a mailbox that has since changed, and each step is
    // a fresh round trip that can fail on its own.
    let (store, bridge) = store(["a", "b", "c"])
    store.selection = ["a"]
    await store.archiveSelection()
    store.selection = ["b"]
    await store.trashSelection()
    bridge.reset()

    await store.undoStack.undo()
    await store.undoStack.undo()

    #expect(bridge.mutations(named: "threads.restore").count == 1,
            "only the most recent action is reversible")
  }

  // MARK: - The banner

  @Test("Every reversible action announces itself")
  func actionsRaiseABanner() async {
    // Undo nobody knows about is undo nobody uses.
    let (store, _) = store(["a", "b"])
    store.selectAll()

    await store.archiveSelection()

    #expect(store.undoStack.banner != nil)
    #expect(store.undoStack.banner?.description.contains("2") == true)
  }

  @Test("Dismissing the banner keeps the offer")
  func dismissingBannerKeepsUndo() async {
    // Letting the notice go is not the same as declining it — ⌘Z still works.
    let (store, _) = store(["a"])
    store.selectAll()
    await store.archiveSelection()

    store.undoStack.dismissBanner()

    #expect(store.undoStack.banner == nil)
    #expect(store.undoStack.top != nil)
  }

  @Test("The wording says what happened and to how many", arguments: [1, 5])
  func bannerWordingIsSpecific(count: Int) async {
    let (store, _) = store((0..<count).map { "t\($0)" })
    store.selectAll()

    await store.archiveSelection()

    let text = store.undoStack.banner?.description ?? ""
    #expect(text.contains("Archived"))
    #expect(text.contains("\(count)"))
    #expect(text.contains(count == 1 ? "conversation" : "conversations"))
  }
}
