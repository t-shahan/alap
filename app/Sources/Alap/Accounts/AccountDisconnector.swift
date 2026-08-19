import Foundation
import Observation
import os

private let disconnectLog = Logger(subsystem: AppIdentity.bundleID, category: "disconnect")

/// Signs an account out: forgets its credential, then deletes its mail.
///
/// ## Why this spawns the engine rather than mutating through Zero
///
/// The credential lives in the Keychain, which only the engine touches — the
/// app has never held a Google token and should not start now. A Zero mutator
/// could delete the account row and Postgres would cascade the mail away, but
/// it would leave the refresh token on disk, which is the one part of
/// "sign out" that actually matters. So the whole operation belongs where the
/// credential does.
///
/// The engine removes the credential FIRST for a reason worth knowing here
/// too: if this fails halfway, an account with no token simply cannot sync,
/// whereas rows deleted while the token lives would be backfilled again by the
/// next poll — a disconnect that silently undoes itself.
@MainActor
@Observable
final class AccountDisconnector {
  enum Phase: Equatable {
    case idle
    case running(accountId: String)
    case failed(String)
  }

  private(set) var phase: Phase = .idle

  var isRunning: Bool { if case .running = phase { return true }; return false }

  func dismissError() { phase = .idle }

  /// How the engine command is located and run.
  ///
  /// Injected for the same reason `MailStore.openFile` is: the production path
  /// spawns a process and the thing worth asserting is the state machine
  /// around it — that a second disconnect cannot start while one is in flight,
  /// that a failure is surfaced rather than swallowed, and that the completion
  /// only fires on success. A test suite that spawns processes is one nobody
  /// runs.
  typealias Runner = @MainActor (
    _ accountId: String,
    _ completion: @escaping @MainActor (_ status: Int32, _ detail: String) -> Void
  ) -> Void

  /// Nil when the engine binary cannot be found.
  @ObservationIgnored private let runner: Runner?

  /// Production: locate the engine and spawn it.
  init() {
    guard let engine = AccountConnector.engineURL() else {
      self.runner = nil
      return
    }
    self.runner = { accountId, completion in
      AccountDisconnector.spawn(engine: engine, accountId: accountId,
                                completion: completion)
    }
  }

  /// Tests: drive the outcome directly, or pass nil for "no engine here".
  ///
  /// A separate initialiser rather than a defaulted parameter, so that passing
  /// nil MEANS nil. Overloading one initialiser would have made the missing-
  /// engine test depend on auto-detection happening to fail, which is a
  /// property of whatever machine runs it rather than of the code.
  init(runner: Runner?) {
    self.runner = runner
  }

  /// - Parameter onFinished: Called on success, so the caller can clear any
  ///   selection pointing at a mailbox that no longer exists.
  func disconnect(accountId: String,
                  onFinished: @escaping @MainActor @Sendable () -> Void) {
    // A second disconnect while one is in flight would race two engine
    // processes against the same rows, and the loser's error would surface as
    // if the first had failed.
    guard !isRunning else { return }
    guard let runner else {
      phase = .failed("Engine not found. Run scripts/build-app.sh.")
      return
    }

    phase = .running(accountId: accountId)

    runner(accountId) { [weak self] status, detail in
      guard let self else { return }
      guard status == 0 else {
        // Surfaced rather than logged. A sign-out that reports success and
        // leaves the credential behind is the worst outcome here, so a failure
        // has to be visible and has to say what state it left.
        disconnectLog.error("disconnect failed: \(detail, privacy: .public)")
        self.phase = .failed(detail.isEmpty
          ? "The engine exited with status \(status)."
          : detail)
        return
      }
      disconnectLog.info("disconnected \(accountId, privacy: .public)")
      self.phase = .idle
      onFinished()
    }
  }

  /// The production path: spawn `mailengined disconnect <id>`.
  private static func spawn(
    engine: URL, accountId: String,
    completion: @escaping @MainActor (Int32, String) -> Void
  ) {
    let task = Process()
    task.executableURL = engine
    task.arguments = ["disconnect", accountId]
    // The engine reads its database URL from the environment, exactly as it
    // does from a terminal.
    task.environment = ProcessInfo.processInfo.environment.merging(
      AccountConnector.loadDotEnv()
    ) { current, _ in current }

    let errors = Pipe()
    task.standardOutput = Pipe()
    task.standardError = errors

    task.terminationHandler = { finished in
      let detail = String(
        data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8
      )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      Task { @MainActor in completion(finished.terminationStatus, detail) }
    }

    do {
      try task.run()
    } catch {
      Task { @MainActor in completion(-1, error.localizedDescription) }
    }
  }
}
