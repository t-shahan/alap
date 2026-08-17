import Foundation
import WebKit
@testable import Alap

/// A `MailBridge` that records what it was asked to do and lets a test push
/// rows back synchronously.
///
/// Synchronous delivery is the point. The real bridge answers over a WebKit
/// message handler, so a test driving it would have to wait on arbitrary
/// timings and would be flaky by construction. Here, `push` invokes the
/// subscription's handler on the spot, which makes every assertion
/// deterministic.
@MainActor
final class FakeBridge: MailBridge {
  /// One command the store sent.
  struct Sent: Equatable {
    let kind: String
    let name: String
    let args: [String: JSONValue]
  }

  private(set) var sent: [Sent] = []
  private(set) var activeSubscriptions: Set<String> = []
  var connection: ConnectionState = .connected
  var webView: WKWebView? { nil }
  /// When set, `mutate` throws it instead of recording the call.
  var mutationError: (any Error)?

  /// Handlers keyed by subscription id, type-erased over the row type.
  private var sinks: [String: (Data) -> Void] = [:]

  func start() { sent.append(Sent(kind: "start", name: "", args: [:])) }

  func reconnect() { sent.append(Sent(kind: "reconnect", name: "", args: [:])) }

  func subscribe<Row: Decodable>(
    id: String, query: String, args: [String: JSONValue],
    as rowType: Row.Type, onUpdate: @escaping ([Row], Bool) -> Void
  ) {
    activeSubscriptions.insert(id)
    sent.append(Sent(kind: "subscribe", name: query, args: args))
    sinks[id] = { data in
      guard let rows = try? JSONDecoder().decode([Row].self, from: data) else { return }
      onUpdate(rows, true)
    }
  }

  func subscribeOne<Row: Decodable>(
    id: String, query: String, args: [String: JSONValue],
    as rowType: Row.Type, onUpdate: @escaping (Row?, Bool) -> Void
  ) {
    activeSubscriptions.insert(id)
    sent.append(Sent(kind: "subscribe", name: query, args: args))
    sinks[id] = { data in
      onUpdate(try? JSONDecoder().decode(Row.self, from: data), true)
    }
  }

  func preload(id: String, query: String, args: [String: JSONValue]) {
    sent.append(Sent(kind: "preload", name: query, args: args))
  }

  func unsubscribe(id: String) {
    activeSubscriptions.remove(id)
    sinks.removeValue(forKey: id)
    sent.append(Sent(kind: "unsubscribe", name: id, args: [:]))
  }

  func mutate(_ mutator: String, args: [String: JSONValue]) async throws {
    if let mutationError { throw mutationError }
    sent.append(Sent(kind: "mutate", name: mutator, args: args))
  }

  // MARK: Test driving

  /// Delivers a JSON payload to a subscription, as Zero would.
  func push(_ id: String, json: String) {
    sinks[id]?(Data(json.utf8))
  }

  func mutations(named name: String) -> [Sent] {
    sent.filter { $0.kind == "mutate" && $0.name == name }
  }

  func subscribedQueries() -> [String] {
    sent.filter { $0.kind == "subscribe" }.map(\.name)
  }

  func reset() { sent.removeAll() }
}
