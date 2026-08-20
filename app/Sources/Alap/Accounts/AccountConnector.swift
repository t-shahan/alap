import Foundation
import Observation

/// Accumulates bytes from a pipe and yields complete lines.
///
/// `readabilityHandler` is invoked on an arbitrary queue, so the partial-line
/// buffer is genuinely shared mutable state across threads — Swift 6 rejects
/// capturing a plain `var` here, and it is right to. A lock is enough: the
/// critical section is a substring search.
private final class LineBuffer: @unchecked Sendable {
  private let lock = NSLock()
  private var pending = Data()

  /// Appends a chunk and returns whatever complete lines it completed.
  ///
  /// A JSON object can be split across two reads, so anything after the last
  /// newline is retained rather than parsed.
  func take(_ chunk: Data) -> [Data] {
    lock.lock()
    defer { lock.unlock() }

    pending.append(chunk)
    var lines: [Data] = []
    while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
      lines.append(Data(pending[..<newline]))
      pending = Data(pending[pending.index(after: newline)...])
    }
    return lines
  }
}

/// Connects a new mailbox by running the engine.
///
/// ## Why this spawns a process instead of doing the work
///
/// OAuth, the Keychain, and every network call belong to the engine. Putting an
/// authorisation flow in the app would duplicate all three, and would mean
/// shipping Google credentials inside a bundle that anyone can open with
/// `unzip`. The engine already holds them, already knows how to run the
/// loopback redirect, and already writes the account row.
///
/// So the app spawns `mailengined connect` and reads its stdout. The engine
/// emits one JSON object per line — deliberately structured rather than prose,
/// because a half-parsed human sentence is exactly how a connect flow ends up
/// reporting success for a mailbox that never synced.
@MainActor
@Observable
final class AccountConnector {
  /// Where the flow has got to.
  enum Phase: Equatable {
    case idle
    /// Waiting for the user in their browser.
    case authorizing
    /// Authorised; the first backfill is running.
    case syncing(email: String, done: Int, total: Int)
    case finished(email: String, messages: Int)
    case failed(String)
  }

  private(set) var phase: Phase = .idle

  var isRunning: Bool {
    switch phase {
    case .authorizing, .syncing: true
    default: false
    }
  }

  @ObservationIgnored private var process: Process?

  /// The engine binary.
  ///
  /// Prefers the copy inside the bundle, which is what a shipped app uses.
  /// Falls back to a development build so the app runs from a checkout without
  /// being packaged first, and finally to `MAILENGINE_BIN` for anyone running
  /// an engine from somewhere else entirely.
  static func engineURL() -> URL? {
    if let override = ProcessInfo.processInfo.environment["MAILENGINE_BIN"] {
      return URL(fileURLWithPath: override)
    }

    let bundled = Bundle.main.bundleURL
      .appendingPathComponent("Contents/Helpers/mailengined")
    if FileManager.default.isExecutableFile(atPath: bundled.path) {
      return bundled
    }

    // Development: build/Mail.app → repository root → engine/build.
    let development = Bundle.main.bundleURL
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("engine/build/mailengined")
    return FileManager.default.isExecutableFile(atPath: development.path)
      ? development : nil
  }

  /// Runs the connect flow. The browser opens as part of it.
  func connect() {
    guard !isRunning else { return }
    guard let engine = AccountConnector.engineURL() else {
      phase = .failed("Engine not found. Run scripts/build-app.sh.")
      return
    }

    phase = .authorizing

    let task = Process()
    task.executableURL = engine
    task.arguments = ["connect"]
    // The engine reads its Google credentials and database URL from the
    // environment, exactly as it does from a terminal.
    task.environment = ProcessInfo.processInfo.environment.merging(
      AccountConnector.loadDotEnv()
    ) { current, _ in current }

    let output = Pipe()
    let errors = Pipe()
    task.standardOutput = output
    task.standardError = errors

    // Line-buffered reads, because progress must appear as it happens: a first
    // backfill of a real mailbox takes minutes, and a flow that shows nothing
    // for that long is indistinguishable from one that has hung.
    let buffer = LineBuffer()
    output.fileHandleForReading.readabilityHandler = { handle in
      let chunk = handle.availableData
      guard !chunk.isEmpty else { return }
      for line in buffer.take(chunk) {
        Task { @MainActor [weak self] in self?.handle(line: line) }
      }
    }

    task.terminationHandler = { [weak self] finished in
      Task { @MainActor in
        output.fileHandleForReading.readabilityHandler = nil
        self?.process = nil
        guard let self else { return }
        // A non-zero exit that produced no error event still has to surface,
        // or the sheet sits on "Authorising…" forever.
        if finished.terminationStatus != 0, self.isRunning {
          let message = String(
            data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8
          ) ?? ""
          self.phase = .failed(
            message.isEmpty ? "Engine exited with code \(finished.terminationStatus)"
                            : message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
      }
    }

    do {
      try task.run()
      process = task
    } catch {
      phase = .failed(error.localizedDescription)
    }
  }

  /// Abandons an in-flight connect.
  func cancel() {
    process?.terminate()
    process = nil
    phase = .idle
  }

  func dismiss() {
    if !isRunning { phase = .idle }
  }

  // MARK: - Events

  private func handle(line: Data) {
    guard
      let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
      let event = object["event"] as? String
    else { return }

    switch event {
    case "authorizing":
      phase = .authorizing

    case "authorized", "syncing":
      let email = (object["email"] as? String) ?? currentEmail ?? ""
      phase = .syncing(email: email, done: 0, total: 0)

    case "progress":
      // Keep the email from the authorised event; progress does not repeat it.
      phase = .syncing(
        email: currentEmail ?? "",
        done: (object["done"] as? Int) ?? 0,
        total: (object["total"] as? Int) ?? 0
      )

    case "done":
      phase = .finished(
        email: (object["email"] as? String) ?? currentEmail ?? "",
        messages: (object["messages"] as? Int) ?? 0
      )

    case "error":
      phase = .failed((object["message"] as? String) ?? "Unknown error")

    default:
      break
    }
  }

  private var currentEmail: String? {
    switch phase {
    case .syncing(let email, _, _): email
    case .finished(let email, _): email
    default: nil
    }
  }

  /// Reads the engine's credentials from the first `.env` that exists.
  ///
  /// The app is launched by Finder or `open`, so it inherits none of the shell
  /// environment the engine needs — and the engine reads GOOGLE_CLIENT_ID and
  /// ZERO_UPSTREAM_DB from its environment rather than parsing `.env` itself.
  ///
  /// Two locations, in order:
  ///
  ///   1. Two levels above the bundle. That is `<repo>/.env` for the
  ///      `build/Alap.app` a development checkout produces.
  ///   2. `~/Library/Application Support/Alap/env`, written by `make install`.
  ///
  /// The second exists because an installed copy has no repository above it:
  /// `/Applications/Alap.app` resolves to `/.env`, which never exists. Without
  /// it the interface still renders — the Zero client talks to zero-cache
  /// directly — while every engine spawn fails for want of a client id, which
  /// looks like broken sync rather than missing configuration.
  static func loadDotEnv() -> [String: String] {
    let candidates = [
      Bundle.main.bundleURL
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent(".env"),
      FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Alap/env"),
    ]

    guard let contents = candidates.lazy
      .compactMap({ try? String(contentsOf: $0, encoding: .utf8) })
      .first
    else {
      return [:]
    }

    var values: [String: String] = [:]
    for line in contents.split(separator: "\n") {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard !trimmed.hasPrefix("#"), let equals = trimmed.firstIndex(of: "=") else {
        continue
      }
      let key = String(trimmed[..<equals])
      var value = String(trimmed[trimmed.index(after: equals)...])
      if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
        value = String(value.dropFirst().dropLast())
      }
      values[key] = value
    }
    return values
  }
}
