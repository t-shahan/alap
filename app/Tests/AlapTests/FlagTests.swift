import Foundation
import Testing
@testable import Alap

/// Flagging one conversation from the list.
///
/// The flag used to be reachable only through a bulk action — tick the row,
/// press Flag, untick it — or by opening the conversation and crossing to the
/// reading pane's toolbar. Both routes make a one-row change cost a detour
/// through a mode, and the bulk route leaves the window in selection mode
/// afterwards.
///
/// So the property these tests defend is not "the mutation is sent". It is
/// that flagging one row changes NOTHING ELSE: not what is ticked, not what is
/// open, and not any other row.
@MainActor
struct FlagTests {
  private func store(_ ids: [String], starred: Set<String> = [])
    -> (MailStore, FakeBridge)
  {
    let bridge = FakeBridge()
    let store = MailStore(bridge: bridge, openFile: { _ in })
    store.start()
    bridge.push("accounts", json: Fixtures.account())
    bridge.push("labels", json: Fixtures.labels())
    bridge.push("threads", json: "[" + ids.map {
      Fixtures.thread(id: $0, isStarred: starred.contains($0))
    }.joined(separator: ",") + "]")
    bridge.reset()
    return (store, bridge)
  }

  private func row(_ store: MailStore, _ id: String) -> ThreadRow {
    store.threads.first { $0.id == id }!
  }

  // MARK: - The mutation

  @Test("Flagging an untouched row flags exactly that row")
  func flagsOneRow() async {
    let (store, bridge) = store(["a", "b", "c"])

    await store.toggleStar(row(store, "b"))

    let call = bridge.mutations(named: "threads.setStarred").first
    #expect(call?.args["isStarred"] == .bool(true))
    #expect(call?.args["threadIds"] == .array([.string("b")]),
            "only the row that was pointed at")
  }

  @Test("Flagging a flagged row unflags it")
  func unflagsAFlaggedRow() async {
    let (store, bridge) = store(["a"], starred: ["a"])

    await store.toggleStar(row(store, "a"))

    #expect(bridge.mutations(named: "threads.setStarred").first?.args["isStarred"]
            == .bool(false))
  }

  // MARK: - What it must not disturb

  @Test("Flagging a row does not tick it")
  func flaggingDoesNotSelect() async {
    // The whole reason this control exists: reaching the flag through the bulk
    // panel meant ticking the row first, which put the window into selection
    // mode and left it there.
    let (store, _) = store(["a", "b"])

    await store.toggleStar(row(store, "b"))

    #expect(store.selection.isEmpty, "flagging is not selecting")
    #expect(!store.hasSelection)
  }

  @Test("Flagging a row does not change what is open")
  func flaggingDoesNotNavigate() async {
    let (store, _) = store(["a", "b"])
    store.selectedThreadID = "a"

    await store.toggleStar(row(store, "b"))

    #expect(store.selectedThreadID == "a", "reading should not have moved")
  }

  @Test("Flagging an unticked row ignores the ticked ones")
  func flaggingIgnoresTheSelection() async {
    // The dangerous confusion. Three rows are ticked for a bulk action and the
    // pointer is on a fourth: the row-level flag must act on the fourth alone,
    // not silently become the bulk action.
    let (store, bridge) = store(["a", "b", "c", "d"])
    store.selection = ["a", "b", "c"]

    await store.toggleStar(row(store, "d"))

    let call = bridge.mutations(named: "threads.setStarred").first
    #expect(call?.args["threadIds"] == .array([.string("d")]))
    #expect(store.selection == ["a", "b", "c"], "the selection is untouched")
  }

  // MARK: - Undo

  @Test("Flagging one row is undone by unflagging it")
  func isReversible() async {
    let (store, bridge) = store(["a", "b"])
    await store.toggleStar(row(store, "b"))
    bridge.reset()

    await store.undoStack.undo()

    let call = bridge.mutations(named: "threads.setStarred").first
    #expect(call?.args["isStarred"] == .bool(false))
    #expect(call?.args["threadIds"] == .array([.string("b")]))
  }

  @Test("The undo banner counts conversations")
  func undoDescriptionReadsAsProse() async {
    let (store, _) = store(["a", "b"])

    await store.toggleStar(row(store, "a"))
    #expect(store.undoStack.top?.description == "Flagged 1 conversation")

    store.selectAll()
    await store.setStarred(store.selectedThreads, isStarred: false)
    #expect(store.undoStack.top?.description == "Unflagged 2 conversations")
  }
}

/// Which gutter controls show, and when.
///
/// These rules are the feature. A flag that appears only under the pointer is
/// invisible to someone scanning the list for what they flagged, and one that
/// is always drawn is noise on every unflagged row — so each state below is a
/// deliberate answer rather than a default.
@MainActor
struct ThreadRowAffordanceTests {
  private func affordances(
    hovering: Bool = false, open: Bool = false, checked: Bool = false,
    selecting: Bool = false, flagged: Bool = false
  ) -> ThreadRowAffordances {
    ThreadRowAffordances(
      isHovering: hovering, isOpen: open, isChecked: checked,
      isSelecting: selecting, isFlagged: flagged
    )
  }

  @Test("A flagged row shows its flag with no pointer anywhere near it")
  func flaggedIsAlwaysVisible() {
    // Otherwise the flag stops being a state you can see and becomes one you
    // have to go looking for, row by row.
    #expect(affordances(flagged: true).showsFlag)
    #expect(affordances(flagged: true).flagSymbol == "flag.fill")
  }

  @Test("An untouched unflagged row shows nothing")
  func restingRowIsClean() {
    let resting = affordances()
    #expect(!resting.showsFlag)
    #expect(!resting.showsCheckbox)
  }

  @Test("Hovering offers the flag")
  func hoverOffersTheFlag() {
    #expect(affordances(hovering: true).showsFlag)
    #expect(affordances(hovering: true).flagSymbol == "flag")
  }

  @Test("The open row offers its flag without being pointed at")
  func openRowOffersTheFlag() {
    #expect(affordances(open: true).showsFlag)
  }

  @Test("A selection shows both controls on every row")
  func selectionRevealsEverything() {
    // Extending a selection must not mean hunting for a control that appears
    // one row at a time under the pointer.
    let selecting = affordances(selecting: true)
    #expect(selecting.showsCheckbox)
    #expect(selecting.showsFlag)
  }

  @Test("The checkbox ignores the open row")
  func openRowDoesNotShowACheckbox() {
    // Opening a conversation is not selecting it, so the open row must not
    // sprout a checkbox that implies it is ticked.
    #expect(!affordances(open: true).showsCheckbox)
  }

  @Test("The flag button names the action, not the state")
  func labelNamesTheAction() {
    #expect(affordances(flagged: false).flagLabel == "Flag")
    #expect(affordances(flagged: true).flagLabel == "Remove flag")
  }

  @Test("A ticked row draws a ticked box")
  func checkedSymbol() {
    #expect(affordances(checked: true).checkboxSymbol == "checkmark.square.fill")
    #expect(affordances().checkboxSymbol == "square")
  }
}
