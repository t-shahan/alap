import Foundation
import Testing
@testable import Alap

/// Reply composition.
///
/// This decides who receives your mail. Getting the recipient wrong sends a
/// private reply to the wrong person, and getting the threading headers wrong
/// looks perfect locally while breaking the conversation for everyone else —
/// both failures are invisible from inside the app, which is exactly why they
/// are tested here rather than by clicking.
@MainActor
struct ReplyTests {
  private func store(
    parent: String,
    accountEmail: String = "me@example.com"
  ) -> (MailStore, FakeBridge) {
    let bridge = FakeBridge()
    let store = MailStore(bridge: bridge, openFile: { _ in })
    store.start()

    bridge.push("accounts", json: Fixtures.account(email: accountEmail))
    bridge.push("threads", json: Fixtures.threadList(["th1"]))
    store.selectedThreadID = "th1"
    store.flushPendingSubscriptions()
    bridge.push("detail", json: Fixtures.detail(messages: [parent]))
    return (store, bridge)
  }

  private func reply(_ bridge: FakeBridge) -> [String: JSONValue]? {
    bridge.mutations(named: "compose.send").first?.args
  }

  /// Opens the composer as a reply, types a body, and sends.
  ///
  /// Goes through the real path rather than calling a send method directly:
  /// `startReply` is where recipients and threading are resolved, so bypassing
  /// it would test the transport and skip the decisions.
  private func sendReply(_ store: MailStore, body: String) async {
    store.startReply()
    store.composer.body = body
    await store.sendComposed()
  }

  // MARK: - Recipients

  @Test("Replies go to the sender")
  func addressedToTheSender() async {
    let (store, bridge) = store(
      parent: Fixtures.message(id: "m1", fromEmail: "ada@example.com")
    )

    await sendReply(store, body: "Sounds good.")

    #expect(reply(bridge)?["to"] == .array([.string("ada@example.com")]))
  }

  @Test("Replying to your own sent mail goes to its recipients, not yourself")
  func doesNotReplyToYourself() async {
    // Otherwise replying to something in Sent mails you a copy and the person
    // you were actually talking to never hears from you.
    let (store, bridge) = store(
      parent: Fixtures.message(
        id: "m1",
        fromEmail: "me@example.com",
        to: [("Ada", "ada@example.com"), ("Ben", "ben@example.com")]
      ),
      accountEmail: "me@example.com"
    )

    await sendReply(store, body: "Following up.")

    #expect(reply(bridge)?["to"] == .array([.string("ada@example.com"),
                                            .string("ben@example.com")]))
  }

  @Test("Sender matching ignores case")
  func senderComparisonIsCaseInsensitive() async {
    // Mail addresses are not case sensitive in the local part in practice, and
    // Gmail echoes back whatever casing the sender used.
    let (store, bridge) = store(
      parent: Fixtures.message(id: "m1", fromEmail: "Me@Example.com",
                               to: [("Ada", "ada@example.com")]),
      accountEmail: "me@example.com"
    )

    await sendReply(store, body: "Hello.")

    #expect(reply(bridge)?["to"] == .array([.string("ada@example.com")]))
  }

  // MARK: - Threading

  @Test("A reply carries In-Reply-To and References")
  func threadingHeadersArePresent() async {
    let (store, bridge) = store(
      parent: Fixtures.message(id: "m1", rfc822MessageId: "parent@example.com")
    )

    await sendReply(store, body: "Ack.")

    #expect(reply(bridge)?["inReplyTo"] == .string("parent@example.com"))
    #expect(reply(bridge)?["references"] == .array([.string("parent@example.com")]))
  }

  @Test("A parent with no Message-ID still sends, without threading headers")
  func missingMessageIdDoesNotBlockTheReply() async {
    // Better an unthreaded reply than no reply at all.
    let (store, bridge) = store(
      parent: Fixtures.message(id: "m1", rfc822MessageId: nil)
    )

    await sendReply(store, body: "Ack.")

    #expect(reply(bridge)?["inReplyTo"] == .string(""))
    #expect(reply(bridge)?["references"] == .array([]))
  }

  @Test("The reply targets Gmail's thread id, not our row id")
  func usesTheRemoteThreadId() async {
    // Gmail files the reply into the conversation by threadId; our own row id
    // means nothing to it.
    let (store, bridge) = store(parent: Fixtures.message(id: "m1"))

    await sendReply(store, body: "Ack.")

    #expect(reply(bridge)?["remoteThreadId"] == .string("t1"))
    // Our own row id is deliberately NOT sent. The engine addresses Gmail by
    // Gmail's thread id; the local id meant nothing to it and was only ever
    // carried along because the mutator happened to accept it.
    #expect(reply(bridge)?["threadId"] == nil)
  }

  // MARK: - Subject

  @Test("Re: is added when absent")
  func addsRePrefix() async {
    let (store, bridge) = store(
      parent: Fixtures.message(id: "m1", subject: "Design review")
    )

    await sendReply(store, body: "Ack.")

    #expect(reply(bridge)?["subject"] == .string("Re: Design review"))
  }

  @Test("Re: does not stack, whatever its casing", arguments: [
    "Re: Design review", "RE: Design review", "re: Design review",
  ])
  func doesNotStackRePrefixes(subject: String) async {
    // A few round trips would otherwise produce "Re: Re: Re: Re:".
    let (store, bridge) = store(parent: Fixtures.message(id: "m1", subject: subject))

    await sendReply(store, body: "Ack.")

    #expect(reply(bridge)?["subject"] == .string(subject))
  }

  // MARK: - Refusals

  @Test("An empty or whitespace-only body sends nothing", arguments: ["", "   ", "\n\t "])
  func refusesEmptyBodies(body: String) async {
    let (store, bridge) = store(parent: Fixtures.message(id: "m1"))

    await sendReply(store, body: body)

    #expect(bridge.mutations(named: "compose.send").isEmpty)
  }

  @Test("The body is trimmed before sending")
  func trimsTheBody() async {
    let (store, bridge) = store(parent: Fixtures.message(id: "m1"))

    await sendReply(store, body: "\n  Sounds good.  \n")

    #expect(reply(bridge)?["body"] == .string("Sounds good."))
  }

  @Test("Nothing is sent when no thread is selected")
  func requiresAThread() async {
    let bridge = FakeBridge()
    let store = MailStore(bridge: bridge, openFile: { _ in })
    store.start()

    await sendReply(store, body: "Hello?")

    #expect(bridge.mutations(named: "compose.send").isEmpty)
  }

  @Test("Each reply carries a fresh idempotency key")
  func idempotencyKeysAreUnique() async {
    // Two deliberate replies are two distinct intents. Reusing the key would
    // collapse the second onto the first outbox row and silently drop it.
    let (store, bridge) = store(parent: Fixtures.message(id: "m1"))

    await sendReply(store, body: "First.")
    await sendReply(store, body: "Second.")

    let keys = bridge.mutations(named: "compose.send").compactMap { $0.args["idempotencyKey"] }
    #expect(keys.count == 2)
    #expect(keys[0] != keys[1])
  }

  @Test("A bridge failure surfaces in the composer rather than vanishing")
  func surfacesFailures() async {
    // The composer reports its own outcome, so this no longer throws — it
    // moves to .failed and, crucially, KEEPS the draft. Throwing here would
    // have no catcher and would lose what the user wrote.
    struct Boom: Error {}
    let (store, _) = store(parent: Fixtures.message(id: "m1"))
    store.composer.status = .editing

    store.startReply()
    store.composer.body = "Ack."
    (store.bridge as! FakeBridge).mutationError = Boom()
    await store.sendComposed()

    guard case .failed = store.composer.status else {
      Issue.record("expected .failed, got \(store.composer.status)")
      return
    }
    #expect(store.composer.body == "Ack.", "a failed send must not lose the draft")
    #expect(store.composer.isVisible, "the composer must stay open to retry")
  }
}
