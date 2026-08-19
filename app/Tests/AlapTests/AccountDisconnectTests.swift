import Foundation
import Testing
@testable import Alap

/// Signing an account out, from the app's side.
///
/// The engine owns the destructive sequence and asserts its own ordering (see
/// `test_disconnect.cpp`). What is the app's to get right is the state machine
/// around it: that a second disconnect cannot start while one is in flight,
/// that a failure is surfaced rather than swallowed, and that the completion —
/// which resets the selection — fires only when the account actually went.
@MainActor
struct AccountDisconnectTests {
  /// Drives the outcome by hand instead of spawning an engine.
  private func disconnector(
    status: Int32, detail: String = "",
    onRun: @escaping @MainActor (String) -> Void = { _ in }
  ) -> AccountDisconnector {
    AccountDisconnector { accountId, completion in
      onRun(accountId)
      completion(status, detail)
    }
  }

  @Test("A successful disconnect clears the phase and reports back")
  func successNotifies() {
    var finished = 0
    let subject = disconnector(status: 0)

    subject.disconnect(accountId: "acct_dev") { finished += 1 }

    #expect(finished == 1)
    #expect(subject.phase == .idle)
    #expect(subject.isRunning == false)
  }

  @Test("A failure surfaces the engine's own message and does NOT report back")
  func failureIsSurfaced() {
    // The completion resets the selected mailbox. Firing it on failure would
    // navigate away from an account that is still connected, which reads as
    // the disconnect having worked.
    var finished = 0
    let subject = disconnector(
      status: 1,
      detail: "the credential is gone but the mailbox could not be deleted"
    )

    subject.disconnect(accountId: "acct_dev") { finished += 1 }

    #expect(finished == 0)
    #expect(subject.phase == .failed(
      "the credential is gone but the mailbox could not be deleted"))
  }

  @Test("A silent failure still says something")
  func failureAlwaysHasAMessage() {
    // An empty stderr with a non-zero status is the case that would otherwise
    // produce an alert with no body — a dialog that reports nothing is worse
    // than no dialog.
    let subject = disconnector(status: 9)

    subject.disconnect(accountId: "acct_dev") {}

    guard case .failed(let message) = subject.phase else {
      Issue.record("expected a failure phase")
      return
    }
    #expect(message.contains("9"))
    #expect(!message.isEmpty)
  }

  @Test("A second disconnect cannot start while one is in flight")
  func refusesConcurrentRuns() {
    // Two engine processes racing the same rows would have the loser's error
    // surface as though the first had failed. The guard is on `isRunning`,
    // so this drives a runner that never completes.
    var runs: [String] = []
    let subject = AccountDisconnector { accountId, _ in runs.append(accountId) }

    subject.disconnect(accountId: "acct_one") {}
    subject.disconnect(accountId: "acct_two") {}

    #expect(runs == ["acct_one"])
    #expect(subject.isRunning)
    #expect(subject.phase == .running(accountId: "acct_one"))
  }

  @Test("A missing engine fails loudly rather than doing nothing")
  func missingEngineIsReported() {
    // The button would otherwise appear to work and silently leave the account
    // connected — which is the failure mode the whole control was added to fix.
    var finished = 0
    let subject = AccountDisconnector(runner: nil)

    subject.disconnect(accountId: "acct_dev") { finished += 1 }

    #expect(finished == 0)
    guard case .failed(let message) = subject.phase else {
      Issue.record("expected a failure phase")
      return
    }
    #expect(message.contains("Engine not found"))
  }

  @Test("Dismissing an error returns it to idle so it can be retried")
  func errorsAreDismissible() {
    let subject = disconnector(status: 1, detail: "connection refused")
    subject.disconnect(accountId: "acct_dev") {}
    #expect(subject.isRunning == false)

    subject.dismissError()

    #expect(subject.phase == .idle)
  }

  @Test("Retrying after a failure runs again")
  func retryAfterFailure() {
    // The engine's sequence is safe to re-run — `Keychain.remove` succeeds when
    // nothing is stored — so a failed disconnect must not leave the app in a
    // state that refuses to try again.
    var runs = 0
    var status: Int32 = 1
    let subject = AccountDisconnector { _, completion in
      runs += 1
      completion(status, "connection refused")
    }

    subject.disconnect(accountId: "acct_dev") {}
    status = 0
    subject.disconnect(accountId: "acct_dev") {}

    #expect(runs == 2)
    #expect(subject.phase == .idle)
  }
}
