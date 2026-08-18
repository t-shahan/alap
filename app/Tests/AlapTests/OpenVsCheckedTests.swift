import Foundation
import Testing
@testable import Alap

/// Opening a conversation and ticking it are different acts.
///
/// They were the same value. `selection` was the single source of truth for
/// both, so `selectedThreadID` wrote back into it — which meant clicking a row
/// to READ it ticked its checkbox and put the window into bulk-selection mode.
@MainActor
struct OpenVsCheckedTests {
  private func store(_ ids: [String]) -> (MailStore, FakeBridge) {
    let bridge = FakeBridge()
    let store = MailStore(bridge: bridge, openFile: { _ in })
    store.start()
    bridge.push("accounts", json: Fixtures.account())
    bridge.push("labels", json: Fixtures.labels())
    bridge.push("threads", json: Fixtures.threadList(ids))
    bridge.reset()
    return (store, bridge)
  }

  @Test("Opening a conversation does not tick it")
  func openingDoesNotCheck() {
    let (store, _) = store(["t1", "t2"])

    store.selectedThreadID = "t1"

    #expect(store.selectedThreadID == "t1", "it should be open")
    #expect(store.selection.isEmpty, "opening is not selecting")
    #expect(!store.hasSelection)
  }

  @Test("Arrow-key navigation does not tick anything")
  func movingDoesNotCheck() {
    let (store, _) = store(["t1", "t2", "t3"])

    store.moveSelection(by: 1)
    store.moveSelection(by: 1)

    #expect(store.selectedThreadID == "t2")
    #expect(store.selection.isEmpty)
  }

  @Test("Ticking a checkbox does not change what is open")
  func checkingDoesNotOpen() {
    let (store, _) = store(["t1", "t2"])
    store.selectedThreadID = "t1"

    store.toggleSelection(of: "t2")

    #expect(store.selectedThreadID == "t1", "reading should not have moved")
    #expect(store.selection == ["t2"])
  }

  @Test("Ticking several keeps the open conversation open")
  func checkingSeveralKeepsTheOpenOne() {
    let (store, _) = store(["t1", "t2", "t3"])
    store.selectedThreadID = "t1"

    store.toggleSelection(of: "t2")
    store.toggleSelection(of: "t3")

    #expect(store.selectedThreadID == "t1")
    #expect(store.selection == ["t2", "t3"])
    #expect(store.hasMultipleSelected)
  }

  @Test("Select all ticks every row without opening anything")
  func selectAllOnlyTicks() {
    let (store, _) = store(["t1", "t2", "t3"])

    store.toggleSelectAll()

    #expect(store.selection.count == 3)
    #expect(store.selectedThreadID == nil, "nothing was opened")
  }

  @Test("Unticking the last row leaves the conversation open")
  func uncheckingKeepsItOpen() {
    let (store, _) = store(["t1", "t2"])
    store.selectedThreadID = "t1"
    store.toggleSelection(of: "t1")

    store.toggleSelection(of: "t1")

    #expect(store.selection.isEmpty)
    #expect(store.selectedThreadID == "t1", "reading should survive unticking")
  }

  @Test("An open conversation is still marked read while others are ticked")
  func markReadFollowsTheOpenOne() async {
    // Marking read is about what is being READ, which is the open message —
    // not about how many checkboxes happen to be ticked.
    let bridge = FakeBridge()
    let store = MailStore(bridge: bridge, openFile: { _ in })
    store.markReadDwell = .milliseconds(60)
    store.start()
    bridge.push("accounts", json: Fixtures.account())
    bridge.push("labels", json: Fixtures.labels())
    bridge.push("threads", json: "[" + ["t1", "t2"].map {
      Fixtures.thread(id: $0, unreadCount: 1)
    }.joined(separator: ",") + "]")
    bridge.reset()

    store.selectedThreadID = "t1"
    store.toggleSelection(of: "t2")
    for _ in 0..<200 {
      if bridge.sent.contains(where: { $0.name == "threads.setRead" }) { break }
      try? await Task.sleep(for: .milliseconds(10))
    }

    let marked = bridge.sent.filter { $0.kind == "mutate" && $0.name == "threads.setRead" }
    #expect(marked.count == 1)
  }
}
