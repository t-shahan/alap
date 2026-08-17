import Foundation
import Observation
import OSLog
import WebKit

let bridgeLog = Logger(subsystem: AppIdentity.bundleID, category: "bridge")

/// Hosts the Zero client in a headless `WKWebView` and relays reactive query
/// results into Swift.
///
/// ## Why a web view
///
/// Zero's client is TypeScript-only. WebKit supplies IndexedDB, WebSocket and
/// fetch, so the client runs completely unmodified — no polyfills, and nothing
/// extra to sign or notarise, because WebKit is a system framework. The view
/// is never added to a window; it exists purely as a JavaScript host.
///
/// ## Threading
///
/// `WKWebView` is main-actor-only, and every `@Observable` property here feeds
/// SwiftUI, so the whole type is `@MainActor`. Message delivery from WebKit
/// already arrives on the main thread.
@MainActor
@Observable
final class ZeroBridge {

  /// Live connection state, mirrored from Zero.
  private(set) var connection: ConnectionState = .connecting

  /// True once the JS side has signalled `ready`. Commands issued before this
  /// are queued rather than dropped.
  private(set) var isReady = false

  /// Most recent error surfaced from the bridge, for display.
  private(set) var lastError: String?

  /// The JS host.
  ///
  /// Exposed so SwiftUI can attach it to the window hierarchy. A WKWebView
  /// that is never added to a window is not reliably scheduled by WebKit —
  /// it can sit forever without loading or executing. `BridgeHost` mounts it
  /// at zero size, so it is hosted but invisible.
  @ObservationIgnored private(set) var webView: WKWebView?
  @ObservationIgnored private var reconnectTask: Task<Void, Never>?
  @ObservationIgnored private var reconnectAttempt = 0
  @ObservationIgnored private var handler: ScriptMessageRelay?

  /// Decoders for active subscriptions, keyed by subscription id. Each closure
  /// captures the concrete row type registered by the caller.
  @ObservationIgnored private var sinks: [String: (Data, Bool) -> Void] = [:]

  /// When each subscription was requested, for latency measurement.
  @ObservationIgnored private var subscribeStartedAt: [String: CFAbsoluteTime] = [:]

  /// Milliseconds from subscribe to first update, per subscription id.
  ///
  /// Exposed so latency can be measured without a profiler — the app's
  /// os.Logger output does not persist under ad-hoc signing.
  public private(set) var lastLatencyMs: [String: Double] = [:]

  /// Commands issued before `ready`, replayed in order once the client is up.
  @ObservationIgnored private var pending: [String] = []

  /// Continuations awaiting a `mutateResult`, keyed by command id.
  @ObservationIgnored private var mutations: [String: CheckedContinuation<Void, any Error>] = [:]

  @ObservationIgnored private var hasLoaded = false

  /// Creates the web view immediately.
  ///
  /// Construction happens here rather than in `start()` because SwiftUI mounts
  /// `BridgeHost` during layout, which is before `.task` runs. If the view did
  /// not exist yet, the host would attach nothing and the client would never
  /// be scheduled.
  init() {
    let relay = ScriptMessageRelay { [weak self] body in
      MainActor.assumeIsolated { self?.receive(body) }
    }
    self.handler = relay

    let config = WKWebViewConfiguration()
    config.userContentController.add(relay, name: "zeroBridge")

    // The bundle is loaded from a file:// URL, whose origin is opaque. Without
    // this, the Zero client cannot reach http://localhost:4848 at all. The
    // exposure is contained: this web view is headless, loads only our own
    // bundle, and index.html carries a CSP restricting connect-src to the
    // local zero-cache. Set via KVC because WebKit does not surface it on
    // WKWebViewConfiguration directly.
    config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
    config.setValue(true, forKey: "allowUniversalAccessFromFileURLs")
    // No persistent website data store is configured explicitly; the default
    // is persistent, which is what we want — Zero's IndexedDB cache should
    // survive relaunches so the UI paints from local data immediately.

    self.webView = WKWebView(frame: .zero, configuration: config)
  }

  // MARK: - Lifecycle

  /// Loads the Zero client bundle. Safe to call more than once.
  func start() {
    guard let view = webView, !hasLoaded else { return }
    hasLoaded = true

    guard
      let root = Bundle.module.url(forResource: "Web", withExtension: nil),
      FileManager.default.fileExists(atPath: root.appendingPathComponent("index.html").path)
    else {
      let message = "Zero client bundle missing from app resources. Run scripts/build-app.sh."
      bridgeLog.error("\(message, privacy: .public)")
      lastError = message
      return
    }

    let index = root.appendingPathComponent("index.html")
    bridgeLog.info("loading zero client from \(index.path, privacy: .public)")
    view.loadFileURL(index, allowingReadAccessTo: root)
  }

  // MARK: - Subscriptions

  /// Subscribes to a named query, decoding each update into `Row`.
  ///
  /// Re-subscribing with the same `id` replaces the previous subscription,
  /// which is what SwiftUI does when a query's arguments change.
  ///
  /// - Parameters:
  ///   - id: Caller-assigned handle, also used to unsubscribe.
  ///   - query: Dotted path into the query registry.
  ///   - args: Query arguments; must match the query's Zod validator.
  ///   - onUpdate: Receives decoded rows and whether the server has confirmed
  ///     completeness. Fires immediately with locally-cached data, then again
  ///     when the server responds.
  func subscribe<Row: Decodable>(
    id: String,
    query: String,
    args: [String: JSONValue] = [:],
    as rowType: Row.Type = Row.self,
    onUpdate: @escaping ([Row], Bool) -> Void
  ) {
    sinks[id] = { [weak self] data, isComplete in
      do {
        let rows = try JSONDecoder().decode([Row].self, from: data)
        onUpdate(rows, isComplete)
      } catch {
        self?.lastError = "decode \(id): \(error)"
      }
    }
    send(Command(kind: .subscribe, id: id, path: query, args: args))
  }

  /// Subscribes to a query returning a single row (one built with `.one()`).
  func subscribeOne<Row: Decodable>(
    id: String,
    query: String,
    args: [String: JSONValue] = [:],
    as rowType: Row.Type = Row.self,
    onUpdate: @escaping (Row?, Bool) -> Void
  ) {
    subscribeStartedAt[id] = CFAbsoluteTimeGetCurrent()
    sinks[id] = { [weak self] data, isComplete in
      if let began = self?.subscribeStartedAt.removeValue(forKey: id) {
        let ms = (CFAbsoluteTimeGetCurrent() - began) * 1000
        self?.lastLatencyMs[id] = ms
        bridgeLog.info("subscription \(id, privacy: .public) first update in \(ms, format: .fixed(precision: 1))ms")
        // Also to stderr. os.Logger output does not persist for ad-hoc-signed
        // apps outside a proper bundle identity, which makes it useless for
        // measurement; stderr is readable by running the binary directly.
        if ProcessInfo.processInfo.environment["MAIL_TRACE"] != nil {
          FileHandle.standardError.write(
            Data("[trace] \(id) first-update \(String(format: "%.1f", ms))ms\n".utf8))
        }
      }
      // A `.one()` query yields `null` when nothing matches, so a decode
      // failure here is an expected "no row" rather than an error.
      onUpdate(try? JSONDecoder().decode(Row.self, from: data), isComplete)
    }
    send(Command(kind: .subscribe, id: id, path: query, args: args))
  }

  /// Syncs rows to the client without materialising them.
  ///
  /// Nothing is delivered back; the point is that a LATER query over the same
  /// rows can be answered from the local cache instead of round-tripping to
  /// zero-cache. That round trip is what made opening a thread slow.
  func preload(
    id: String,
    query: String,
    args: [String: JSONValue] = [:]
  ) {
    send(Command(kind: .preload, id: id, path: query, args: args))
  }

  /// Resumes a connection Zero has stopped retrying.
  ///
  /// `error` and `needs-auth` are terminal until the host asks again — Zero
  /// makes no further attempts on its own. Without this the client stays dead
  /// while the rest of the app looks healthy: the list still renders from the
  /// local replica, so nothing appears wrong except that mail stops arriving.
  func reconnect() {
    send(Command(kind: .reconnect, id: UUID().uuidString, path: nil, args: nil))
  }

  func unsubscribe(id: String) {
    sinks.removeValue(forKey: id)
    send(Command(kind: .unsubscribe, id: id, path: nil, args: nil))
  }

  // MARK: - Mutations

  /// Runs a named mutator, returning once the write lands in the LOCAL store.
  ///
  /// It deliberately does not wait for the server. The local write completes
  /// within a frame, and blocking the UI on the round trip would defeat the
  /// point of optimistic mutation. A later server rejection arrives as an
  /// `error` event and surfaces through `lastError`.
  func mutate(
    _ mutator: String,
    args: [String: JSONValue]
  ) async throws {
    let id = UUID().uuidString
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
      mutations[id] = continuation
      send(Command(kind: .mutate, id: id, path: mutator, args: args))
    }
  }

  // MARK: - Transport

  /// Retries a stalled connection, backing off.
  ///
  /// Zero halts on `error` and `needs-auth`, so recovery has to be driven from
  /// here. Backed off rather than immediate: the usual cause is a service that
  /// is down, and hammering it every frame helps nobody.
  ///
  /// Capped rather than unbounded — past a minute the problem is not going to
  /// resolve itself, and the indicator is clickable so a person can force it.
  private func scheduleReconnectIfStalled(_ state: ConnectionState) {
    guard state == .error || state == .needsAuth else {
      // Any other state means Zero is managing itself again.
      reconnectAttempt = 0
      reconnectTask?.cancel()
      reconnectTask = nil
      return
    }
    guard reconnectTask == nil else { return }

    let delay = min(pow(2, Double(reconnectAttempt)), 60)
    reconnectAttempt += 1
    reconnectTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(delay))
      guard !Task.isCancelled else { return }
      self?.reconnectTask = nil
      self?.reconnect()
    }
  }

  private func send(_ command: Command) {
    guard let json = try? command.jsonString() else {
      lastError = "failed to encode command \(command.kind.rawValue)"
      return
    }
    // `JSON.stringify` produces a string that still needs escaping to be
    // embedded in a JS expression. Encoding it a second time gives a safe
    // quoted literal.
    guard
      let literalData = try? JSONEncoder().encode(json),
      let literal = String(data: literalData, encoding: .utf8)
    else {
      lastError = "failed to escape command"
      return
    }
    let script = "window.__zeroBridge.receive(\(literal))"

    guard isReady, let webView else {
      pending.append(script)
      return
    }
    webView.evaluateJavaScript(script) { [weak self] _, error in
      if let error {
        Task { @MainActor in self?.lastError = "js: \(error.localizedDescription)" }
      }
    }
  }

  private func flushPending() {
    guard let webView else { return }
    let queued = pending
    pending.removeAll()
    for script in queued {
      webView.evaluateJavaScript(script, completionHandler: nil)
    }
  }

  private func receive(_ body: Any) {
    guard
      let string = body as? String,
      let data = string.data(using: .utf8),
      let event = try? BridgeEvent(json: data)
    else {
      lastError = "malformed event from bridge"
      return
    }

    switch event {
    case .ready:
      bridgeLog.info("bridge ready; flushing \(self.pending.count) queued command(s)")
      isReady = true
      flushPending()

    case .update(let id, let rows, let isComplete):
      sinks[id]?(rows, isComplete)

    case .mutateResult(let id, let ok, let error):
      guard let continuation = mutations.removeValue(forKey: id) else { return }
      if ok {
        continuation.resume(returning: ())
      } else {
        lastError = error
        continuation.resume(throwing: BridgeError.malformedEvent)
      }

    case .connection(let state, let reason):
      bridgeLog.info("connection: \(state.rawValue, privacy: .public) \(reason ?? "", privacy: .public)")
      connection = state
      scheduleReconnectIfStalled(state)

    case .failure(_, let message):
      bridgeLog.error("bridge error: \(message, privacy: .public)")
      lastError = message
    }
  }
}

/// Bridges `WKScriptMessageHandler`'s `NSObject` requirement to a closure, so
/// `ZeroBridge` can stay a plain `@Observable` class rather than an `NSObject`
/// subclass.
private final class ScriptMessageRelay: NSObject, WKScriptMessageHandler {
  private let onMessage: (Any) -> Void

  init(onMessage: @escaping (Any) -> Void) {
    self.onMessage = onMessage
  }

  func userContentController(
    _ controller: WKUserContentController,
    didReceive message: WKScriptMessage
  ) {
    onMessage(message.body)
  }
}
