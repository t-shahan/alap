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
    bridge.mutations(named: "compose.reply").first?.args
  }

  // MARK: - Recipients

  @Test("Replies go to the sender")
  func addressedToTheSender() async throws {
    let (store, bridge) = store(
      parent: Fixtures.message(id: "m1", fromEmail: "ada@example.com")
    )

    try await store.sendReply(body: "Sounds good.")

    #expect(reply(bridge)?["to"] == .array([.string("ada@example.com")]))
  }

  @Test("Replying to your own sent mail goes to its recipients, not yourself")
  func doesNotReplyToYourself() async throws {
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

    try await store.sendReply(body: "Following up.")

    #expect(reply(bridge)?["to"] == .array([.string("ada@example.com"),
                                            .string("ben@example.com")]))
  }

  @Test("Sender matching ignores case")
  func senderComparisonIsCaseInsensitive() async throws {
    // Mail addresses are not case sensitive in the local part in practice, and
    // Gmail echoes back whatever casing the sender used.
    let (store, bridge) = store(
      parent: Fixtures.message(id: "m1", fromEmail: "Me@Example.com",
                               to: [("Ada", "ada@example.com")]),
      accountEmail: "me@example.com"
    )

    try await store.sendReply(body: "Hello.")

    #expect(reply(bridge)?["to"] == .array([.string("ada@example.com")]))
  }

  // MARK: - Threading

  @Test("A reply carries In-Reply-To and References")
  func threadingHeadersArePresent() async throws {
    let (store, bridge) = store(
      parent: Fixtures.message(id: "m1", rfc822MessageId: "parent@example.com")
    )

    try await store.sendReply(body: "Ack.")

    #expect(reply(bridge)?["inReplyTo"] == .string("parent@example.com"))
    #expect(reply(bridge)?["references"] == .array([.string("parent@example.com")]))
  }

  @Test("A parent with no Message-ID still sends, without threading headers")
  func missingMessageIdDoesNotBlockTheReply() async throws {
    // Better an unthreaded reply than no reply at all.
    let (store, bridge) = store(
      parent: Fixtures.message(id: "m1", rfc822MessageId: nil)
    )

    try await store.sendReply(body: "Ack.")

    #expect(reply(bridge)?["inReplyTo"] == .string(""))
    #expect(reply(bridge)?["references"] == .array([]))
  }

  @Test("The reply targets Gmail's thread id, not our row id")
  func usesTheRemoteThreadId() async throws {
    // Gmail files the reply into the conversation by threadId; our own row id
    // means nothing to it.
    let (store, bridge) = store(parent: Fixtures.message(id: "m1"))

    try await store.sendReply(body: "Ack.")

    #expect(reply(bridge)?["remoteThreadId"] == .string("t1"))
    #expect(reply(bridge)?["threadId"] == .string("th1"))
  }

  // MARK: - Subject

  @Test("Re: is added when absent")
  func addsRePrefix() async throws {
    let (store, bridge) = store(
      parent: Fixtures.message(id: "m1", subject: "Design review")
    )

    try await store.sendReply(body: "Ack.")

    #expect(reply(bridge)?["subject"] == .string("Re: Design review"))
  }

  @Test("Re: does not stack, whatever its casing", arguments: [
    "Re: Design review", "RE: Design review", "re: Design review",
  ])
  func doesNotStackRePrefixes(subject: String) async throws {
    // A few round trips would otherwise produce "Re: Re: Re: Re:".
    let (store, bridge) = store(parent: Fixtures.message(id: "m1", subject: subject))

    try await store.sendReply(body: "Ack.")

    #expect(reply(bridge)?["subject"] == .string(subject))
  }

  // MARK: - Refusals

  @Test("An empty or whitespace-only body sends nothing", arguments: ["", "   ", "\n\t "])
  func refusesEmptyBodies(body: String) async throws {
    let (store, bridge) = store(parent: Fixtures.message(id: "m1"))

    try await store.sendReply(body: body)

    #expect(bridge.mutations(named: "compose.reply").isEmpty)
  }

  @Test("The body is trimmed before sending")
  func trimsTheBody() async throws {
    let (store, bridge) = store(parent: Fixtures.message(id: "m1"))

    try await store.sendReply(body: "\n  Sounds good.  \n")

    #expect(reply(bridge)?["body"] == .string("Sounds good."))
  }

  @Test("Nothing is sent when no thread is selected")
  func requiresAThread() async throws {
    let bridge = FakeBridge()
    let store = MailStore(bridge: bridge, openFile: { _ in })
    store.start()

    try await store.sendReply(body: "Hello?")

    #expect(bridge.mutations(named: "compose.reply").isEmpty)
  }

  @Test("Each reply carries a fresh idempotency key")
  func idempotencyKeysAreUnique() async throws {
    // Two deliberate replies are two distinct intents. Reusing the key would
    // collapse the second onto the first outbox row and silently drop it.
    let (store, bridge) = store(parent: Fixtures.message(id: "m1"))

    try await store.sendReply(body: "First.")
    try await store.sendReply(body: "Second.")

    let keys = bridge.mutations(named: "compose.reply").compactMap { $0.args["idempotencyKey"] }
    #expect(keys.count == 2)
    #expect(keys[0] != keys[1])
  }

  @Test("A bridge failure propagates instead of being swallowed")
  func surfacesFailures() async {
    // The pane shows "Queued" on success; if this were swallowed it would lie.
    struct Boom: Error {}
    let (store, bridge) = store(parent: Fixtures.message(id: "m1"))
    bridge.mutationError = Boom()

    await #expect(throws: Boom.self) {
      try await store.sendReply(body: "Ack.")
    }
  }
}
