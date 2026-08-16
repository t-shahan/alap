import Foundation
import SwiftUI
import Testing
@testable import Mail

/// Behaviour that only appears once a second mailbox exists.
///
/// Almost everything here was correct-looking with one account and wrong with
/// two, which is why it needs tests rather than a look: a query argument that
/// silently matches one account's rows produces a plausible, populated,
/// incomplete list — the worst kind of bug to notice by eye.
@MainActor
struct MultiAccountTests {
  private func store(accounts: [(id: String, email: String, color: String)])
    -> (MailStore, FakeBridge)
  {
    let bridge = FakeBridge()
    let store = MailStore(bridge: bridge, openFile: { _ in })
    store.start()

    let accountJSON = accounts.map {
      """
      {"id":"\($0.id)","emailAddress":"\($0.email)","displayName":"\($0.email)",
       "provider":"gmail","color":"\($0.color)","sortOrder":0,"createdAt":0}
      """
    }.joined(separator: ",")
    bridge.push("accounts", json: "[\(accountJSON)]")

    // Every account has its OWN row for the same provider-side label.
    let labelJSON = accounts.enumerated().map { index, account in
      """
      {"id":"\(account.id)|INBOX","accountId":"\(account.id)","remoteId":"INBOX",
       "name":"Inbox","kind":"system","sortOrder":0,
       "unreadCount":\((index + 1) * 2),"totalCount":10}
      """
    }.joined(separator: ",")
    bridge.push("labels", json: "[\(labelJSON)]")

    return (store, bridge)
  }

  private let two = [
    (id: "acct_a", email: "me@personal.com", color: "#0a84ff"),
    (id: "acct_b", email: "me@work.com", color: "#30d158"),
  ]

  // MARK: - Query arguments

  @Test("A label mailbox is queried by provider id, not a row id")
  func labelQueryUsesRemoteId() {
    // The bug this guards: each account has its own INBOX row, so passing a
    // single composite row id would show one mailbox under a sidebar entry
    // that claims to cover all of them.
    let (store, bridge) = store(accounts: two)
    bridge.reset()

    store.selectedMailbox = .label(remoteId: "INBOX")

    let call = bridge.sent.first { $0.kind == "subscribe" && $0.name == "threads.inLabel" }
    #expect(call?.args["remoteId"] == .string("INBOX"))
    #expect(call?.args["labelId"] == nil, "the row id must no longer be sent")
  }

  @Test("A label that has not synced yet shows nothing rather than everything")
  func unknownLabelShowsNothing() {
    let (store, bridge) = store(accounts: two)
    bridge.reset()

    store.selectedMailbox = .label(remoteId: "NOT_SYNCED_YET")

    #expect(store.threads.isEmpty)
    #expect(!bridge.subscribedQueries().contains("threads.inLabel"))
  }

  @Test("An account mailbox passes its account id")
  func accountQueryPassesAccountId() {
    let (store, bridge) = store(accounts: two)
    bridge.reset()

    store.selectedMailbox = .account(id: "acct_b")

    let call = bridge.sent.first { $0.kind == "subscribe" && $0.name == "threads.forAccount" }
    #expect(call?.args["accountId"] == .string("acct_b"))
  }

  @Test("The unified inbox takes no account argument")
  func unifiedTakesNoAccount() {
    let (store, bridge) = store(accounts: two)
    store.selectedMailbox = .account(id: "acct_a")
    bridge.reset()

    store.selectedMailbox = .allInboxes

    let call = bridge.sent.first { $0.kind == "subscribe" && $0.name == "threads.unifiedInbox" }
    #expect(call?.args["accountId"] == nil)
  }

  // MARK: - Counts

  @Test("Unread is per account, from the trigger-maintained counter")
  func perAccountUnread() {
    let (store, _) = store(accounts: two)
    #expect(store.unreadCount(forAccount: "acct_a") == 2)
    #expect(store.unreadCount(forAccount: "acct_b") == 4)
  }

  @Test("The unified badge sums every account's inbox")
  func unifiedBadgeSums() {
    // Showing one account's count on a unified entry would understate the
    // mailbox and undermine the point of unifying it.
    let (store, _) = store(accounts: two)
    #expect(store.badge(for: .allInboxes) == 6)
  }

  @Test("An unknown account has no unread rather than crashing")
  func unknownAccountCounts() {
    let (store, _) = store(accounts: two)
    #expect(store.unreadCount(forAccount: "acct_nope") == 0)
  }

  // MARK: - Colour

  @Test("Account colours appear only once there is more than one account")
  func tintAppearsWithTwoAccounts() {
    // With one mailbox the stripe answers a question nobody is asking, so it
    // is decoration; with two it is the only cheap way to read a unified list.
    let (single, _) = store(accounts: [two[0]])
    #expect(single.tint(forAccount: "acct_a") == nil)

    let (multiple, _) = store(accounts: two)
    #expect(multiple.tint(forAccount: "acct_a") != nil)
    #expect(multiple.tint(forAccount: "acct_b") != nil)
  }

  @Test("Different accounts get different colours")
  func tintsDiffer() {
    let (store, _) = store(accounts: two)
    #expect(store.tint(forAccount: "acct_a") != store.tint(forAccount: "acct_b"))
  }

  @Test("An unknown account has no colour")
  func unknownAccountHasNoTint() {
    let (store, _) = store(accounts: two)
    #expect(store.tint(forAccount: "acct_nope") == nil)
  }

  @Test("A malformed colour degrades instead of rendering wrongly",
        arguments: ["", "not-a-colour", "#12", "#gggggg", "0a84ff!"])
  func malformedColoursAreRejected(hex: String) {
    // Account colours come from Postgres. A bad value must fall back to the
    // muted default, not silently paint black on near-black.
    #expect(Color(hex: hex) == nil)
  }

  @Test("Well-formed colours parse, with or without the hash")
  func wellFormedColoursParse() {
    #expect(Color(hex: "#0a84ff") != nil)
    #expect(Color(hex: "0a84ff") != nil)
  }

  // MARK: - Display

  @Test("The sidebar shows the local part when there is no real display name")
  func shortNameFallsBackToLocalPart() throws {
    // display_name defaults to the address on first sync, so preferring it
    // blindly fills a 220pt column with truncated addresses.
    let json = """
      [{"id":"acct_a","emailAddress":"taylor@example.com",
        "displayName":"taylor@example.com","provider":"gmail",
        "color":"#0a84ff","sortOrder":0,"createdAt":0}]
      """
    let rows = try JSONDecoder().decode([AccountRow].self, from: Data(json.utf8))
    #expect(rows[0].shortName == "taylor")
  }

  @Test("A real display name is preferred over the address")
  func shortNamePrefersDisplayName() throws {
    let json = """
      [{"id":"acct_a","emailAddress":"taylor@example.com","displayName":"Taylor S",
        "provider":"gmail","color":"#0a84ff","sortOrder":0,"createdAt":0}]
      """
    let rows = try JSONDecoder().decode([AccountRow].self, from: Data(json.utf8))
    #expect(rows[0].shortName == "Taylor S")
  }

  @Test("Mailbox identities stay distinct across accounts")
  func accountMailboxesAreDistinct() {
    // These become SwiftUI selection values; collapsing them would make two
    // sidebar rows highlight as one.
    #expect(Mailbox.account(id: "acct_a") != Mailbox.account(id: "acct_b"))
    #expect(Mailbox.account(id: "acct_a").id == "account:acct_a")
  }
}
