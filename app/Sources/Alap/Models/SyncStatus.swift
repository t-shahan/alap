import Foundation

/// One health reading from two processes.
///
/// ## The lie this exists to stop telling
///
/// The sidebar footer said "Connected" and meant the Zero WebSocket to the
/// local replica. The process that actually fetches mail from Gmail is
/// `SyncDaemon`, and its own doc comment names the failure this creates: with
/// nothing running, *"the app looks completely healthy — the list renders from
/// the local replica, search works, everything is fast — and mail simply stops
/// arriving. There is no symptom to notice."*
///
/// `SyncDaemon.state` was read by no view at all. So the exact silent failure
/// the daemon was built to eliminate was still silent; only the terminal window
/// it used to require had gone. The green dot was reporting the health of the
/// wrong process.
///
/// The worse of the two processes wins. An instrument that only shows good news
/// is a decoration.
///
/// SwiftUI-free so the precedence rules can be asserted over the full
/// `(connection × daemon)` matrix — the `PaneLayout` / `ThreadRowAffordances`
/// pattern.
struct SyncStatus: Equatable {
  enum Level: Equatable {
    /// Everything that fetches mail is running.
    case ok
    /// Working, and expected to settle on its own.
    case working
    /// Not fetching, but not broken either — nothing to act on.
    case degraded
    /// Mail is not arriving. `message` is the detail, for a tooltip.
    case failed(String)
  }

  let level: Level
  /// The rail's one line. Legible to someone who has never heard of Zero —
  /// no process names, no subscription ids, no SQL.
  let label: String
  /// Whether clicking should try to recover. True only where there is an
  /// impatient path worth offering: the daemon self-restarts with backoff and
  /// Zero backs off to a minute, and past that a person watching it should not
  /// have to wait for a timer.
  let isRecoverable: Bool

  init(
    connection: ConnectionState,
    daemon: SyncDaemon.State,
    lastDelivery: Date?,
    now: Date = .now
  ) {
    // Precedence is by severity, and the daemon comes first: a dead fetcher is
    // the failure with no other symptom, which is the whole reason this type
    // exists. A dead socket at least stops the list updating.
    switch (daemon, connection) {
    case (.failed(let message), _):
      self.init(level: .failed(message),
                label: "Sync stopped — click to restart",
                isRecoverable: true)

    case (_, .error), (_, .needsAuth):
      self.init(level: .failed(connection.label),
                label: connection.label,
                isRecoverable: true)

    case (_, .disconnected), (_, .closed):
      self.init(level: .degraded, label: "Offline", isRecoverable: true)

    case (.stopped, _), (_, .connecting), (_, .unknown):
      // Starting up. Terminal states are solid; this is the only one that
      // pulses, because a light that moves only while something is genuinely
      // working is instrument grammar.
      self.init(level: .working, label: "Starting sync…", isRecoverable: false)

    case (.deferredToAnother, _):
      // Someone is running a daemon in a terminal. Syncing IS happening, just
      // not by us — this must not read as a failure.
      self.init(level: .ok, label: "Sync: external", isRecoverable: false)

    case (.running, .connected):
      self.init(level: .ok,
                label: Self.recencyLabel(lastDelivery: lastDelivery, now: now),
                isRecoverable: false)
    }
  }

  private init(level: Level, label: String, isRecoverable: Bool) {
    self.level = level
    self.label = label
    self.isRecoverable = isRecoverable
  }

  /// "Synced 12s ago", ticking.
  ///
  /// Nothing is persisted across launches on purpose: "synced 3 days ago" at
  /// launch, before the first poll has completed, is stale information
  /// presented as current. Until the first delivery this says what is true,
  /// which is that it is watching.
  private static func recencyLabel(lastDelivery: Date?, now: Date) -> String {
    guard let lastDelivery else { return "Watching for mail" }
    let seconds = max(0, Int(now.timeIntervalSince(lastDelivery)))
    switch seconds {
    case ..<5: return "Synced just now"
    case ..<60: return "Synced \(seconds)s ago"
    case ..<3600: return "Synced \(seconds / 60)m ago"
    default: return "Synced \(seconds / 3600)h ago"
    }
  }
}

/// What the last search cost.
///
/// The direction's pitch — *"none of them are fast enough for the number to be
/// flattering"* — rested on numbers the app never measured. This is the
/// measurement, and it doubles as the engineering side's first in-product
/// regression sentinel: if this ever reads 40 ms, someone has broken the
/// early-termination design `SearchIndex` documents.
struct SearchStats: Equatable {
  let matched: Int
  let milliseconds: Double

  /// One decimal under 10ms, whole numbers above.
  ///
  /// Two decimals is faux precision; zero decimals hides the very number that
  /// flatters, because the honest answer is frequently under 1ms.
  var displayDuration: String {
    milliseconds < 10
      ? String(format: "%.1f ms", milliseconds)
      : "\(Int(milliseconds.rounded())) ms"
  }
}
