import Foundation
import Testing
@testable import Alap

/// The footer's reading, over the full `(connection × daemon)` matrix.
///
/// This is the test that matters most in the file, and it is not a styling
/// test. The footer used to render the Zero WebSocket's health and call it
/// "Connected" — while `SyncDaemon`, the process that actually fetches mail
/// from Gmail, was read by no view in the app. So the exact silent failure the
/// daemon was built to eliminate was still silent.
@MainActor
struct SyncStatusTests {
  private func status(
    _ connection: ConnectionState,
    _ daemon: SyncDaemon.State,
    lastDelivery: Date? = nil,
    now: Date = Date(timeIntervalSince1970: 1_700_000_000)
  ) -> SyncStatus {
    SyncStatus(connection: connection, daemon: daemon,
               lastDelivery: lastDelivery, now: now)
  }

  @Test("A dead sync daemon fails LOUDLY even while the socket is perfect")
  func deadDaemonBeatsHealthySocket() {
    // The R7 case. Everything the reader can see is working — the list renders
    // from the local replica, search is instant — and mail has stopped
    // arriving with no other symptom anywhere in the interface.
    let reading = status(.connected, .failed("exit 1; retrying in 8s"))

    #expect(reading.level == .failed("exit 1; retrying in 8s"))
    #expect(reading.isRecoverable)
    #expect(reading.label.contains("Sync stopped"))
  }

  @Test("A daemon deferring to another is not a failure")
  func deferredIsHealthy() {
    // Someone is running a daemon in a terminal. Syncing IS happening, just
    // not by us — reporting that as an error would train the reader to ignore
    // the one indicator that matters.
    let reading = status(.connected, .deferredToAnother)

    #expect(reading.level == .ok)
    #expect(reading.label == "Sync: external")
    #expect(reading.isRecoverable == false)
  }

  @Test("Socket failures still surface", arguments: [ConnectionState.error, .needsAuth])
  func socketFailuresSurface(state: ConnectionState) {
    let reading = status(state, .running)

    #expect(reading.level == .failed(state.label))
    #expect(reading.isRecoverable, "these are the two states Zero refuses to retry from")
  }

  @Test("Offline is degraded rather than failed",
        arguments: [ConnectionState.disconnected, .closed])
  func offlineIsDegraded(state: ConnectionState) {
    #expect(status(state, .running).level == .degraded)
  }

  @Test("Starting up pulses rather than claiming health")
  func startingIsWorking() {
    #expect(status(.connecting, .running).level == .working)
    #expect(status(.connected, .stopped).level == .working)
  }

  @Test("A healthy pair reports recency")
  func healthyReportsRecency() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let reading = status(.connected, .running,
                         lastDelivery: now.addingTimeInterval(-12), now: now)

    #expect(reading.level == .ok)
    #expect(reading.label == "Synced 12s ago")
  }

  @Test("Before the first delivery it says what is true")
  func noDeliveryYet() {
    // Not "synced just now", which would be a claim, and not a persisted
    // "synced 3 days ago", which would be stale information presented as
    // current. It is watching, and that is what it says.
    #expect(status(.connected, .running).label == "Watching for mail")
  }

  @Test("Recency reads in the unit a person would use")
  func recencyScales() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    func label(_ ago: TimeInterval) -> String {
      status(.connected, .running, lastDelivery: now.addingTimeInterval(-ago), now: now).label
    }

    #expect(label(2) == "Synced just now")
    #expect(label(45) == "Synced 45s ago")
    #expect(label(600) == "Synced 10m ago")
    #expect(label(7200) == "Synced 2h ago")
  }

  @Test("The daemon outranks the socket in every combination")
  func daemonAlwaysWins() {
    // Belt and braces over the whole matrix: no connection state may talk the
    // reading out of reporting a dead fetcher.
    let connections: [ConnectionState] = [
      .connected, .connecting, .disconnected, .error, .needsAuth, .closed, .unknown,
    ]
    for connection in connections {
      let reading = status(connection, .failed("gone"))
      #expect(reading.level == .failed("gone"), "\(connection.rawValue) hid a dead daemon")
    }
  }
}

/// The search reading's formatting.
struct SearchStatsTests {
  @Test("Sub-10ms keeps a decimal; above it, whole numbers")
  func durationFormatting() {
    // Two decimals is faux precision. Zero decimals hides the very number that
    // flatters, because the honest answer is frequently under 1ms.
    #expect(SearchStats(matched: 4, milliseconds: 0.64).displayDuration == "0.6 ms")
    #expect(SearchStats(matched: 4, milliseconds: 9.8).displayDuration == "9.8 ms")
    #expect(SearchStats(matched: 4, milliseconds: 12.4).displayDuration == "12 ms")
    #expect(SearchStats(matched: 4, milliseconds: 180).displayDuration == "180 ms")
  }
}
