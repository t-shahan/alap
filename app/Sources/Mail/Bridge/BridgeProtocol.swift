import Foundation

/// Swift mirrors of `packages/client/src/protocol.ts`.
///
/// This file and that one are a matched pair. Changing the shape of a command
/// or event in one without the other produces a silent decode failure at
/// runtime rather than a compile error, so keep them in lockstep.

// MARK: - Commands (Swift → JS)

/// A command sent into the web view.
///
/// Encoded manually rather than via synthesised `Codable` because `args` is
/// heterogeneous per query and has to pass through as arbitrary JSON.
struct Command {
  enum Kind: String {
    case subscribe, unsubscribe, mutate
  }

  let kind: Kind
  let id: String
  /// Dotted registry path — `threads.unifiedInbox`, `threads.archive`.
  let path: String?
  let args: [String: JSONValue]?

  func jsonString() throws -> String {
    var object: [String: JSONValue] = [
      "type": .string(kind.rawValue),
      "id": .string(id),
    ]
    if let path {
      object[kind == .mutate ? "mutator" : "query"] = .string(path)
    }
    if let args {
      object["args"] = .object(args)
    }
    let data = try JSONEncoder().encode(JSONValue.object(object))
    guard let string = String(data: data, encoding: .utf8) else {
      throw BridgeError.encodingFailed
    }
    return string
  }
}

// MARK: - Events (JS → Swift)

/// An event pushed up from the web view.
///
/// Decoded by hand off the `type` discriminator. `update.rows` is deliberately
/// left as raw `Data`: the bridge does not know what row type a given
/// subscription carries, so decoding is deferred to whoever registered it.
enum BridgeEvent {
  case ready
  case update(id: String, rows: Data, isComplete: Bool)
  case mutateResult(id: String, ok: Bool, error: String?)
  case connection(state: ConnectionState, reason: String?)
  case failure(id: String?, message: String)

  init(json data: Data) throws {
    guard
      let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let type = root["type"] as? String
    else {
      throw BridgeError.malformedEvent
    }

    switch type {
    case "ready":
      self = .ready

    case "update":
      guard let id = root["id"] as? String else { throw BridgeError.malformedEvent }
      // Re-serialise just the rows so the caller can decode them into a
      // concrete type. `.fragmentsAllowed` because a `.one()` query yields a
      // bare object, and an empty result can be null.
      let rowsValue = root["rows"] ?? NSNull()
      let rows = try JSONSerialization.data(withJSONObject: rowsValue, options: [.fragmentsAllowed])
      self = .update(id: id, rows: rows, isComplete: (root["resultType"] as? String) == "complete")

    case "mutateResult":
      guard let id = root["id"] as? String, let ok = root["ok"] as? Bool else {
        throw BridgeError.malformedEvent
      }
      self = .mutateResult(id: id, ok: ok, error: root["error"] as? String)

    case "connection":
      let raw = root["state"] as? String ?? ""
      self = .connection(
        state: ConnectionState(rawValue: raw) ?? .unknown,
        reason: root["reason"] as? String
      )

    case "error":
      self = .failure(id: root["id"] as? String, message: root["message"] as? String ?? "unknown")

    default:
      throw BridgeError.unknownEventType(type)
    }
  }
}

/// Mirrors Zero's connection lifecycle.
///
/// In the local-sidecar topology this should sit at `.connected` essentially
/// always, since the socket never leaves the loopback interface. Anything else
/// means the sidecar or zero-cache is down and is worth surfacing.
enum ConnectionState: String {
  case connecting
  case connected
  case disconnected
  case error
  case needsAuth = "needs-auth"
  case closed
  case unknown

  /// Zero rejects writes unless connected. The UI disables actions on this.
  var acceptsWrites: Bool {
    self == .connected || self == .connecting
  }

  var label: String {
    switch self {
    case .connecting: "Connecting…"
    case .connected: "Connected"
    case .disconnected: "Offline"
    case .error: "Sync error"
    case .needsAuth: "Session expired"
    case .closed: "Closed"
    case .unknown: "Unknown"
    }
  }
}

enum BridgeError: Error {
  case encodingFailed
  case malformedEvent
  case unknownEventType(String)
  case notReady
}

// MARK: - Minimal JSON value

/// Just enough JSON to encode mutator and query arguments.
///
/// Swift has no built-in `Any`-shaped `Encodable`, and pulling in a full JSON
/// library for four cases would be overkill.
enum JSONValue: Encodable {
  case string(String)
  case number(Double)
  case bool(Bool)
  case object([String: JSONValue])
  case array([JSONValue])
  case null

  func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .string(let v): try container.encode(v)
    case .number(let v): try container.encode(v)
    case .bool(let v): try container.encode(v)
    case .object(let v): try container.encode(v)
    case .array(let v): try container.encode(v)
    case .null: try container.encodeNil()
    }
  }
}
