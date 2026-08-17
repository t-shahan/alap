import Foundation
import Observation
import os

private let daemonLog = Logger(subsystem: AppIdentity.bundleID, category: "daemon")

/// Runs the sync engine for as long as the app is open.
///
/// ## Why the app owns this
///
/// Until now the daemon had to be started by hand in a terminal. That is not a
/// rough edge, it is a silent failure: with nothing running, the app looks
/// completely healthy — the list renders from the local replica, search works,
/// everything is fast — and mail simply stops arriving. There is no symptom to
/// notice until you wonder why nobody has emailed you.
///
/// ## Why polling, and why 10 seconds
///
/// Gmail's push mechanism (`users.watch`) delivers to Cloud Pub/Sub, which
/// needs a public HTTPS endpoint. This app is deliberately local-only, so there
/// is nothing for Google to call. Polling `history.list` is the honest option.
///
/// It costs 2 quota units against a budget of 250 per second, so 10 seconds is
/// nowhere near any limit — and it is incremental, asking only what changed
/// since a watermark rather than re-listing the mailbox. The work per poll is
/// roughly one HTTPS round trip.
///
/// ## Why it starts with the app rather than at login
///
/// A LaunchAgent would keep mail arriving while the app is closed, which sounds
/// better until you notice it means a background process holding OAuth
/// credentials and burning battery for a window nobody has open. Starting with
/// the app means the first poll happens as the window appears — which is what
/// makes opening it show current mail — and quitting means quitting.
@MainActor
@Observable
final class SyncDaemon {
  enum State: Equatable {
    case stopped
    case running
    /// Another daemon already holds the lock — someone is running one in a
    /// terminal. Not a failure; syncing is happening, just not by us.
    case deferredToAnother
    case failed(String)
  }

  private(set) var state: State = .stopped

  /// Seconds between incremental polls.
  static let pollInterval = 10

  @ObservationIgnored private var process: Process?
  @ObservationIgnored private var restartTask: Task<Void, Never>?
  @ObservationIgnored private var restartAttempt = 0

  func start() {
    guard process == nil else { return }
    guard let engine = AccountConnector.engineURL() else {
      state = .failed("Engine not found. Run scripts/build-app.sh.")
      daemonLog.error("engine binary missing")
      return
    }

    let task = Process()
    task.executableURL = engine
    task.arguments = ["daemon", String(SyncDaemon.pollInterval)]
    task.environment = ProcessInfo.processInfo.environment.merging(
      AccountConnector.loadDotEnv()
    ) { current, _ in current }

    // Output is read rather than inherited: an inherited pipe with nobody
    // draining it fills its buffer and blocks the child, which would stall
    // syncing in a way that looks like a hang rather than a full pipe.
    let output = Pipe()
    task.standardOutput = output
    task.standardError = output
    output.fileHandleForReading.readabilityHandler = { handle in
      let chunk = handle.availableData
      guard !chunk.isEmpty, let text = String(data: chunk, encoding: .utf8) else { return }
      for line in text.split(separator: "\n") where !line.isEmpty {
        daemonLog.info("\(String(line), privacy: .public)")
      }
    }

    task.terminationHandler = { [weak self] finished in
      Task { @MainActor in
        output.fileHandleForReading.readabilityHandler = nil
        self?.handleExit(status: finished.terminationStatus)
      }
    }

    do {
      try task.run()
      process = task
      state = .running
      restartAttempt = 0
      daemonLog.info("sync daemon started, polling every \(SyncDaemon.pollInterval, privacy: .public)s")
    } catch {
      state = .failed(error.localizedDescription)
      daemonLog.error("could not start: \(error.localizedDescription, privacy: .public)")
    }
  }

  /// Stops the daemon. Called when the app terminates.
  func stop() {
    restartTask?.cancel()
    restartTask = nil
    process?.terminate()
    process = nil
    state = .stopped
  }

  private func handleExit(status: Int32) {
    process = nil
    guard state != .stopped else { return }  // deliberate shutdown

    // Exit 0 with the lock held elsewhere means someone is running a daemon in
    // a terminal. Nothing is wrong and nothing needs restarting.
    if status == 0 {
      state = .deferredToAnother
      daemonLog.info("another daemon holds the lock; not restarting")
      return
    }

    // Anything else is a crash or a misconfiguration. Restart with backoff —
    // the usual causes are Postgres not yet up or credentials missing, and both
    // resolve on their own or not at all.
    let delay = min(pow(2, Double(restartAttempt)), 60)
    restartAttempt += 1
    state = .failed("Sync stopped (exit \(status)); retrying in \(Int(delay))s")
    daemonLog.error("exited \(status, privacy: .public); retry in \(Int(delay), privacy: .public)s")

    restartTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(delay))
      guard !Task.isCancelled else { return }
      self?.restartTask = nil
      self?.start()
    }
  }
}
