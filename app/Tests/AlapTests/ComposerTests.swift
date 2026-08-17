import Foundation
import Testing
@testable import Alap

/// The composer: address parsing, presentation, and draft safety.
///
/// Address parsing gets the most attention because it is the part users feed
/// arbitrary text into — pasted from other clients, half-typed, separated by
/// whatever separator they happen to use — and getting it wrong means mail
/// going to the wrong person or not going at all.
@MainActor
struct ComposerTests {
  private func store() -> (MailStore, FakeBridge) {
    let bridge = FakeBridge()
    let store = MailStore(bridge: bridge, openFile: { _ in })
    store.start()
    bridge.push("accounts", json: Fixtures.account())
    bridge.push("labels", json: Fixtures.labels())
    bridge.push("threads", json: Fixtures.threadList(["t1"]))
    return (store, bridge)
  }

  // MARK: - Address parsing

  @Test("Addresses split on commas, semicolons and newlines", arguments: [
    "a@x.com, b@y.com",
    "a@x.com;b@y.com",
    "a@x.com\nb@y.com",
    "  a@x.com ,  b@y.com  ",
  ])
  func splitsOnEverySeparator(field: String) {
    let composer = Composer()
    #expect(composer.recipients(from: field) == ["a@x.com", "b@y.com"])
  }

  @Test("A pasted display-name form yields just the address")
  func extractsFromAngleBrackets() {
    // This is what pasting out of Apple Mail or Gmail actually gives you, and
    // rejecting it would look like the app refusing a valid address.
    let composer = Composer()
    #expect(composer.recipients(from: "Ada Okonkwo <ada@example.com>") == ["ada@example.com"])
    #expect(composer.recipients(from: "\"Okonkwo, Ada\" <ada@example.com>, b@y.com")
            == ["ada@example.com", "b@y.com"])
  }

  @Test("Half-typed and malformed entries are dropped, not sent", arguments: [
    "", "   ", "ada", "ada@", "@example.com", "ada@@example.com",
    "ada example.com", "ada@localhost",
  ])
  func rejectsMalformed(field: String) {
    let composer = Composer()
    #expect(composer.recipients(from: field).isEmpty)
  }

  @Test("A valid address survives alongside an invalid one")
  func keepsTheGoodOnes() {
    let composer = Composer()
    #expect(composer.recipients(from: "broken@, real@example.com") == ["real@example.com"])
  }

  // MARK: - Send gating

  @Test("Sending needs both a recipient and a body")
  func requiresRecipientAndBody() {
    let composer = Composer()
    composer.newMessage(from: "acct_1")
    #expect(!composer.canSend)

    composer.to = "ada@example.com"
    #expect(!composer.canSend, "a recipient alone is not a message")

    composer.body = "   "
    #expect(!composer.canSend, "whitespace is not a body")

    composer.body = "Hello."
    #expect(composer.canSend)
  }

  @Test("Sending is blocked while a send is in flight")
  func blocksDuringSend() {
    // Otherwise ⌘↩ held down queues the same message repeatedly.
    let composer = Composer()
    composer.newMessage(from: "acct_1")
    composer.to = "ada@example.com"
    composer.body = "Hello."
    composer.status = .sending
    #expect(!composer.canSend)
  }

  @Test("A message with no valid recipient reports rather than sending")
  func refusesWithoutValidRecipients() async {
    let (store, bridge) = store()
    store.startNewMessage()
    store.composer.to = "not-an-address"
    store.composer.body = "Hello."
    bridge.reset()

    await store.sendComposed()

    #expect(bridge.mutations(named: "compose.send").isEmpty)
  }

  // MARK: - Presentation

  @Test("A new message opens empty and open")
  func newMessageStartsClean() {
    let composer = Composer()
    composer.to = "stale@example.com"
    composer.body = "old draft"

    composer.newMessage(from: "acct_1")

    #expect(composer.to.isEmpty)
    #expect(composer.body.isEmpty)
    #expect(composer.isOpen)
    #expect(composer.replyContext == nil)
  }

  @Test("Minimising keeps the draft")
  func minimizePreservesDraft() {
    // The entire reason to minimise rather than close: looking something up
    // mid-message must not cost what you have written.
    let composer = Composer()
    composer.newMessage(from: "acct_1")
    composer.body = "half a thought"

    composer.minimize()

    #expect(composer.isVisible)
    #expect(!composer.isOpen)
    #expect(composer.body == "half a thought")

    composer.expand()
    #expect(composer.isOpen)
    #expect(composer.body == "half a thought")
  }

  @Test("Closing discards")
  func closeDiscards() {
    let composer = Composer()
    composer.newMessage(from: "acct_1")
    composer.body = "abandoned"

    composer.close()

    #expect(!composer.isVisible)
    #expect(composer.body.isEmpty)
  }

  @Test("hasContent reports whether anything would be lost", arguments: [
    ("", "", "", false), ("a@b.com", "", "", true),
    ("", "Subject", "", true), ("", "", "Body", true),
    ("   ", "  ", " ", false),
  ])
  func reportsUnsavedContent(to: String, subject: String, body: String, expected: Bool) {
    let composer = Composer()
    composer.newMessage(from: "acct_1")
    composer.to = to
    composer.subject = subject
    composer.body = body
    #expect(composer.hasContent == expected)
  }

  @Test("A reply arrives pre-filled and carries its threading")
  func replyIsPrefilled() {
    let composer = Composer()
    let context = Composer.ReplyContext(
      accountId: "acct_1", remoteThreadId: "t1",
      inReplyTo: "parent@example.com", references: ["parent@example.com"])

    composer.reply(to: ["ada@example.com"], subject: "Re: Design", context: context)

    #expect(composer.to == "ada@example.com")
    #expect(composer.subject == "Re: Design")
    #expect(composer.replyContext == context)
    #expect(composer.accountId == "acct_1", "a reply sends from the thread's account")
  }

  @Test("The title falls back before a subject is typed")
  func titleFallsBack() {
    let composer = Composer()
    composer.newMessage(from: "acct_1")
    #expect(composer.title == "New Message")

    composer.subject = "Quarterly numbers"
    #expect(composer.title == "Quarterly numbers")
  }

  // MARK: - Suggestions

  @Test("Suggestions come from people already in the loaded threads")
  func suggestsKnownParticipants() {
    let (store, _) = store()
    let matches = store.addressSuggestions(matching: "ada")
    #expect(matches.contains { $0.email == "ada@example.com" })
  }

  @Test("A one-character fragment suggests nothing")
  func needsEnoughToMatch() {
    // Otherwise the first keystroke drops a list over the field covering it.
    let (store, _) = store()
    #expect(store.addressSuggestions(matching: "a").isEmpty)
  }

  @Test("Unknown fragments suggest nothing")
  func noFalseSuggestions() {
    let (store, _) = store()
    #expect(store.addressSuggestions(matching: "zzzznotreal").isEmpty)
  }
}

/// Which address a message is sent FROM.
///
/// Only meaningful once several accounts are connected, and getting it wrong
/// is invisible to the sender: the mistake shows up in the recipient's inbox,
/// after the message has gone.
@MainActor
struct SendingIdentityTests {
  private let two = [
    (id: "acct_personal", email: "me@personal.com"),
    (id: "acct_work", email: "me@work.com"),
  ]

  private func store() -> (MailStore, FakeBridge) {
    let bridge = FakeBridge()
    let store = MailStore(bridge: bridge, openFile: { _ in })
    store.start()

    let accountJSON = two.map {
      """
      {"id":"\($0.id)","emailAddress":"\($0.email)","displayName":"\($0.email)",
       "provider":"gmail","color":"#4aa3a2","sortOrder":0,"createdAt":0}
      """
    }.joined(separator: ",")
    bridge.push("accounts", json: "[\(accountJSON)]")
    bridge.push("labels", json: Fixtures.labels(accountId: "acct_personal"))
    return (store, bridge)
  }

  /// A thread owned by `owner`, whose newest message was addressed to
  /// `addressedTo`.
  private func selectThread(_ store: MailStore, _ bridge: FakeBridge,
                            owner: String, addressedTo: String) {
    bridge.push("threads", json: """
      [{"id":"th1","accountId":"\(owner)","remoteThreadId":"t1","subject":"S",
        "snippet":"s","participants":[{"name":"Ada","email":"ada@example.com"}],
        "lastMessageAt":1700000000000,"messageCount":1,"unreadCount":0,
        "hasAttachments":false,"isStarred":false}]
      """)
    store.selectedThreadID = "th1"
    store.flushPendingSubscriptions()
    bridge.push("detail", json: Fixtures.detail(messages: [
      Fixtures.message(id: "m1", fromEmail: "ada@example.com",
                       to: [("Me", addressedTo)])
    ]))
  }

  @Test("A reply comes from the address it was sent to")
  func repliesFromTheAddressedAccount() {
    // The thread is OWNED by the personal account, but the message was
    // addressed to the work address. Answering from the personal address would
    // be wrong, and only the recipient would ever see it.
    let (store, bridge) = store()
    selectThread(store, bridge, owner: "acct_personal", addressedTo: "me@work.com")

    store.startReply()

    #expect(store.composer.accountId == "acct_work")
  }

  @Test("Casing does not change which identity is chosen")
  func matchIgnoresCase() {
    let (store, bridge) = store()
    selectThread(store, bridge, owner: "acct_personal", addressedTo: "Me@Work.COM")

    store.startReply()

    #expect(store.composer.accountId == "acct_work")
  }

  @Test("Mail that names none of your addresses falls back to the thread's account")
  func fallsBackToTheOwningAccount() {
    // Mailing lists, Bcc, and forwarding aliases all arrive without your
    // address in To or Cc. The mailbox it landed in is the best answer left.
    let (store, bridge) = store()
    selectThread(store, bridge, owner: "acct_work", addressedTo: "list@example.com")

    store.startReply()

    #expect(store.composer.accountId == "acct_work")
  }

  @Test("The identity can be changed after the composer opens")
  func identityIsOverridable() {
    let (store, bridge) = store()
    selectThread(store, bridge, owner: "acct_personal", addressedTo: "me@work.com")
    store.startReply()

    store.composer.accountId = "acct_personal"

    #expect(store.composer.accountId == "acct_personal")
  }

  @Test("The chosen identity is what actually gets sent")
  func chosenIdentityIsSent() async {
    // The picker is worthless if the send ignores it.
    let (store, bridge) = store()
    selectThread(store, bridge, owner: "acct_personal", addressedTo: "me@work.com")
    store.startReply()
    store.composer.accountId = "acct_personal"
    store.composer.body = "Ack."
    bridge.reset()

    await store.sendComposed()

    let call = bridge.mutations(named: "compose.send").first
    #expect(call?.args["accountId"] == .string("acct_personal"))
    #expect(call?.args["fromEmail"] == .string("me@personal.com"))
  }

  @Test("A new message defaults to an account rather than none")
  func newMessageHasAnIdentity() {
    let (store, _) = store()
    store.startNewMessage()
    #expect(store.composer.accountId != nil)
  }
}
