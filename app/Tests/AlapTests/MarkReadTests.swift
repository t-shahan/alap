import Foundation
import Testing
@testable import Alap

/// Marking a conversation read by opening it.
///
/// This did not exist at all: `setRead` was reachable only from the toolbar and
/// the bulk panel, so reading a message left it bold forever and the unread
/// count only ever went up. The interesting part is not the mutation, it is
/// when NOT to send it.
@MainActor
struct MarkReadTests {
  /// Short enough to keep the suite fast, long enough to outlast the gap
  /// between simulated keypresses below.
  private static let dwell = Duration.milliseconds(60)

  private func store(unread: [String], read: [String] = []) -> (MailStore, FakeBridge) {
    let bridge = FakeBridge()
    let store = MailStore(bridge: bridge, openFile: { _ in })
    store.markReadDwell = Self.dwell
    store.start()
    bridge.push("accounts", json: Fixtures.account())
    bridge.push("labels", json: Fixtures.labels())
    let rows = unread.map { Fixtures.thread(id: $0, unreadCount: 1) }
      + read.map { Fixtures.thread(id: $0, unreadCount: 0) }
    bridge.push("threads", json: "[" + rows.joined(separator: ",") + "]")
    bridge.reset()
    return (store, bridge)
  }

  private func readMutations(_ bridge: FakeBridge) -> [FakeBridge.Sent] {
    bridge.sent.filter { $0.kind == "mutate" && $0.name == "threads.setRead" }
  }

  private func markedIDs(_ bridge: FakeBridge) -> [String] {
    readMutations(bridge).flatMap { sent -> [String] in
      guard case .array(let ids)? = sent.args["threadIds"] else { return [] }
      return ids.compactMap { if case .string(let id) = $0 { id } else { nil } }
    }
  }

  /// Polls for an expected result rather than sleeping a fixed span.
  ///
  /// The suite runs in parallel, so a contended MainActor can resume a sleep
  /// arbitrarily late. Waiting for the condition tolerates that; a fixed
  /// tolerance just moves the flake.
  private func waitFor(_ condition: () -> Bool) async {
    for _ in 0..<200 {
      if condition() { return }
      try? await Task.sleep(for: .milliseconds(10))
    }
  }

  /// Waits long enough that a mutation would have arrived if one were coming.
  private func settle() async {
    try? await Task.sleep(for: Self.dwell * 6)
  }

  @Test("Opening an unread conversation marks it read")
  func opensAndMarksRead() async {
    let (store, bridge) = store(unread: ["t1"])

    store.selectedThreadID = "t1"
    await waitFor { !markedIDs(bridge).isEmpty }

    #expect(markedIDs(bridge) == ["t1"])
  }

  @Test("Arrow-key navigation marks each conversation it settles on")
  func arrowKeysMarkRead() async {
    let (store, bridge) = store(unread: ["t1", "t2"])

    store.moveSelection(by: 1)
    await waitFor { !markedIDs(bridge).isEmpty }

    #expect(markedIDs(bridge) == ["t1"])
  }

  @Test("Passing through a conversation does not mark it read")
  func flyingPastDoesNotMarkRead() async throws {
    // Holding ↓ moves through the list faster than the dwell. Without this,
    // scrolling from the top of the inbox to a message near the bottom would
    // mark every conversation in between as read on the way past — which is
    // both wrong and, at 500 rows, unrecoverable.
    let (store, bridge) = store(unread: ["t1", "t2", "t3", "t4"])

    // Spaced in TIME, at roughly the macOS key-repeat rate. Assigning them
    // back to back instead would prove nothing: consecutive synchronous
    // assignments cancel each other whatever the dwell is, so the test would
    // pass with no dwell at all. It is the gap the dwell has to outlast.
    for id in ["t1", "t2", "t3", "t4"] {
      store.selectedThreadID = id
      try await Task.sleep(for: Self.dwell / 4)
    }
    await waitFor { !markedIDs(bridge).isEmpty }
    await settle()

    // Only where it came to rest.
    #expect(markedIDs(bridge) == ["t4"])
  }

  @Test("An already-read conversation sends nothing")
  func readConversationSendsNothing() async {
    let (store, bridge) = store(unread: [], read: ["t1"])

    store.selectedThreadID = "t1"
    await settle()

    #expect(readMutations(bridge).isEmpty)
  }

  @Test("Selecting several for a bulk action marks none of them read")
  func multiSelectDoesNotMarkRead() async {
    // Ticking checkboxes to archive a batch is not reading them.
    let (store, bridge) = store(unread: ["t1", "t2", "t3"])

    store.toggleSelection(of: "t1")
    store.toggleSelection(of: "t2")
    await settle()

    #expect(readMutations(bridge).isEmpty)
  }

  @Test("Automatic marking does not land on the undo stack")
  func doesNotRecordUndo() async {
    // ⌘Z after reading a message must still undo the archive that came before
    // it, not silently un-read the message. Auto-marking is a side effect of
    // looking at something, and undo is for actions the user took.
    let (store, bridge) = store(unread: ["t1"])

    store.selectedThreadID = "t1"
    await waitFor { !markedIDs(bridge).isEmpty }

    #expect(store.undoStack.top == nil)
  }
}
