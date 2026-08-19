import Foundation
import Testing
@testable import Alap

/// When a thread-list change counts as *events* rather than as navigation.
///
/// Motion timing is not unit-testable and this file does not pretend to test
/// it. The RULES are testable, and they are the part that goes wrong: a
/// mailbox switch that plays five hundred insert animations and a pagination
/// page that flashes two hundred rows as "new mail" are the same bug wearing
/// two hats.
struct ThreadListDeltaTests {
  @Test("First delivery after a mailbox switch never animates")
  func firstDeliveryIsSilent() {
    // `resubscribeThreads()` clears `threadsLoaded` before every mailbox
    // switch and every search, so this is the state every navigation lands in
    // — with an entirely new set of ids, which is exactly what would look like
    // five hundred arrivals to a naive diff.
    let delta = ThreadListDelta(
      previous: ["a", "b", "c"], current: ["x", "y", "z"],
      listWasLive: false, isGrowing: false
    )

    #expect(delta.animates == false)
    #expect(delta.arrivals.isEmpty)
  }

  @Test("Pagination growth never animates and never flashes")
  func paginationIsSilent() {
    // Two hundred appended rows of history are not arriving mail.
    let delta = ThreadListDelta(
      previous: ["a", "b"], current: ["a", "b", "c", "d"],
      listWasLive: true, isGrowing: true
    )

    #expect(delta.animates == false)
    #expect(delta.arrivals.isEmpty)
  }

  @Test("A live update animates, and only genuinely new ids flash")
  func liveArrivalFlashes() {
    let delta = ThreadListDelta(
      previous: ["a", "b", "c"], current: ["x", "a", "b", "c"],
      listWasLive: true, isGrowing: false
    )

    #expect(delta.animates)
    #expect(delta.arrivals == ["x"])
    #expect(delta.changedMembership)
  }

  @Test("A live removal animates and flashes nothing")
  func removalAnimatesWithoutFlashing() {
    // Archive and trash arrive through the same callback as a Zero-confirmed
    // list change, which is what makes the row physically collapse — but
    // nothing has ARRIVED, so nothing may flash.
    let delta = ThreadListDelta(
      previous: ["a", "b", "c"], current: ["a", "c"],
      listWasLive: true, isGrowing: false
    )

    #expect(delta.animates)
    #expect(delta.arrivals.isEmpty)
    #expect(delta.changedMembership == false)
  }

  @Test("Reordering an unchanged set flashes nothing")
  func reorderIsNotArrival() {
    // A thread bumped to the top by a reply is not a new conversation, and
    // flashing it would teach the flash to mean nothing.
    let delta = ThreadListDelta(
      previous: ["a", "b", "c"], current: ["c", "a", "b"],
      listWasLive: true, isGrowing: false
    )

    #expect(delta.animates)
    #expect(delta.arrivals.isEmpty)
  }

  @Test("An unchanged list is not a delivery")
  func identicalUpdateIsNotADelivery() {
    // The subscription re-delivers on unrelated column changes. "Synced just
    // now" must mean mail moved, not that a row was re-decoded.
    let delta = ThreadListDelta(
      previous: ["a", "b"], current: ["a", "b"],
      listWasLive: true, isGrowing: false
    )

    #expect(delta.changedMembership == false)
  }
}

/// The same rules, driven through the store that owns them.
@MainActor
struct ArrivalFlashTests {
  private func store() -> (MailStore, FakeBridge) {
    let bridge = FakeBridge()
    return (MailStore(bridge: bridge), bridge)
  }

  @Test("The first delivery marks nothing as newly arrived")
  func firstPaintDoesNotFlash() {
    let (store, bridge) = store()
    store.start()
    bridge.push("threads", json: Fixtures.threadList(["a", "b", "c"]))

    #expect(store.threads.count == 3)
    #expect(store.recentlyArrived.isEmpty)
    // Nothing has been DELIVERED yet in the sense the rail reports; the list
    // was populated, which is a different event.
    #expect(store.lastDelivery == nil)
  }

  @Test("A second delivery flashes exactly the new conversation")
  func liveDeliveryFlashesTheNewRow() {
    let (store, bridge) = store()
    store.start()
    bridge.push("threads", json: Fixtures.threadList(["a", "b"]))
    bridge.push("threads", json: Fixtures.threadList(["new", "a", "b"]))

    #expect(store.recentlyArrived == ["new"])
    #expect(store.lastDelivery != nil)
  }

  @Test("The flash clears")
  func flashDecays() {
    let (store, bridge) = store()
    store.start()
    bridge.push("threads", json: Fixtures.threadList(["a"]))
    bridge.push("threads", json: Fixtures.threadList(["new", "a"]))
    #expect(store.recentlyArrived.isEmpty == false)

    store.clearArrivalsForTesting()
    #expect(store.recentlyArrived.isEmpty)
  }

  @Test("Pagination does not flash the page it loaded")
  func growthDoesNotFlash() {
    // A full page is what makes growth possible at all — a short list is the
    // whole result, so `growThreads` correctly declines it.
    let (store, bridge) = store()
    store.start()
    let firstPage = (0..<MailStore.threadPageSize).map { "t\($0)" }
    bridge.push("threads", json: Fixtures.threadList(firstPage))

    store.growThreads()
    bridge.push("threads", json: Fixtures.threadList(firstPage + ["older1", "older2"]))

    #expect(store.threads.count == MailStore.threadPageSize + 2)
    #expect(store.recentlyArrived.isEmpty)
    #expect(store.lastDelivery == nil, "appended history is not a delivery")
  }
}
