import Foundation
import WebKit

/// The store's view of the bridge.
///
/// `MailStore` previously constructed a `ZeroBridge` itself, which meant every
/// piece of logic in the store — successor selection on archive, reply
/// recipient resolution, the attachment state machine — could only be
/// exercised by launching the app and clicking. That logic decides which
/// message you land on after archiving and who a reply is addressed to, so
/// "verified by clicking" is not good enough.
///
/// This protocol is the seam. Production passes a real `ZeroBridge`; tests
/// pass a fake that records commands and pushes rows back synchronously, with
/// no WebKit, no Zero, and no network.
///
/// The generic `Row` parameters are methods rather than associated types
/// precisely so this stays usable as `any MailBridge`.
@MainActor
protocol MailBridge: AnyObject {
  /// Live connection state, for the status indicator.
  var connection: ConnectionState { get }

  /// The web view to mount, or nil when there is nothing to host.
  ///
  /// WebKit does not reliably schedule a web view that has never been added to
  /// a window, so the real bridge's view must be placed in the hierarchy. A
  /// fake has none, which is why this is optional rather than a separate
  /// protocol.
  var webView: WKWebView? { get }

  /// Loads the client bundle. Safe to call more than once.
  func start()

  /// Resumes a connection Zero has stopped retrying.
  func reconnect()

  func subscribe<Row: Decodable>(
    id: String,
    query: String,
    args: [String: JSONValue],
    as rowType: Row.Type,
    onUpdate: @escaping ([Row], Bool) -> Void
  )

  func subscribeOne<Row: Decodable>(
    id: String,
    query: String,
    args: [String: JSONValue],
    as rowType: Row.Type,
    onUpdate: @escaping (Row?, Bool) -> Void
  )

  func preload(id: String, query: String, args: [String: JSONValue])

  func unsubscribe(id: String)

  func mutate(_ mutator: String, args: [String: JSONValue]) async throws
}

/// Default arguments, which a protocol requirement cannot declare.
///
/// Keeping these here means call sites read exactly as they did before the
/// seam was introduced.
extension MailBridge {
  func subscribe<Row: Decodable>(
    id: String,
    query: String,
    args: [String: JSONValue] = [:],
    as rowType: Row.Type = Row.self,
    onUpdate: @escaping ([Row], Bool) -> Void
  ) {
    subscribe(id: id, query: query, args: args, as: rowType, onUpdate: onUpdate)
  }

  func subscribeOne<Row: Decodable>(
    id: String,
    query: String,
    args: [String: JSONValue] = [:],
    as rowType: Row.Type = Row.self,
    onUpdate: @escaping (Row?, Bool) -> Void
  ) {
    subscribeOne(id: id, query: query, args: args, as: rowType, onUpdate: onUpdate)
  }

  func preload(id: String, query: String, args: [String: JSONValue] = [:]) {
    preload(id: id, query: query, args: args)
  }
}

extension ZeroBridge: MailBridge {}
