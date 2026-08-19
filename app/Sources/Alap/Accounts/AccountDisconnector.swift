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

  /// - Parameter onFinished: Called on success, so the caller can clear any
  ///   selection pointing at a mailbox that no longer exists.
  func disconnect(accountId: String,
                  onFinished: @escaping @MainActor @Sendable () -> Void) {
    guard !isRunning else { return }
    guard let engine = AccountConnector.engineURL() else {
      phase = .failed("Engine not found. Run scripts/build-app.sh.")
      return
    }

    phase = .running(accountId: accountId)

    let task = Process()
    task.executableURL = engine
    task.arguments = ["disconnect", accountId]
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

      Task { @MainActor [weak self] in
        guard let self else { return }
        if finished.terminationStatus == 0 {
          disconnectLog.info("disconnected \(accountId, privacy: .public)")
          self.phase = .idle
          onFinished()
        } else {
          // Surfaced rather than logged. A sign-out that reports success and
          // leaves the credential behind is the worst outcome here, so a
          // failure has to be visible and has to say what state it left.
          disconnectLog.error("disconnect failed: \(detail, privacy: .public)")
          self.phase = .failed(detail.isEmpty
            ? "The engine exited with status \(finished.terminationStatus)."
            : detail)
        }
      }
    }

    do {
      try task.run()
    } catch {
      phase = .failed(error.localizedDescription)
    }
  }
}
