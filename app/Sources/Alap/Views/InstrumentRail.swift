import SwiftUI

/// The sidebar footer: what the instrument is doing, in three lines.
///
/// ## Why this replaces "Connected"
///
/// The footer used to show one dot and one word, and the word was about the
/// wrong process — see `SyncStatus`. It also sat alone in the corner of an app
/// whose one genuinely remarkable property is that everything is instant, and
/// said nothing about it. The performance IS the product, and not one pixel of
/// the interface expressed it.
///
/// ## What belongs here, and what does not
///
/// A reading, not a debug panel. This shows what the instrument is *doing* —
/// counts, recency, latency — never how it works. No subscription ids, no SQL,
/// no process names. The test is that every line is legible to someone who has
/// never heard of Zero.
///
/// It is also the QUIETEST text in the app: tertiary ink, caption sizes, no
/// accent except the status dot. The moment it acquires a headline weight it
/// becomes a dashboard and that principle dies.
struct InstrumentRail: View {
  @Bindable var store: MailStore
  var daemon: SyncDaemon?

  var body: some View {
    // The switcher shares the SYNC line rather than the whole block.
    //
    // Beside the block it stole 30pt from all three readings, and the mailbox
    // line — the longest of them — truncated to "32.4k messages · 1,0…". Line
    // one is the shortest by construction ("Synced 12s ago", "Sync: external"),
    // so that is where a 22pt control costs nothing.
    VStack(alignment: .leading, spacing: Theme.Space.tight) {
      HStack(spacing: Theme.Space.base) {
        syncLine
        Spacer(minLength: 0)
        ThemeSwitcher()
      }
      mailboxLine
      latencyLine
    }
    // Every numeral in here is born tabular.
    .monospacedDigit()
  }

  // MARK: Line 1 — sync, truthfully

  /// Ticks once a second so "Synced 12s ago" is true rather than decorative.
  /// One `Text` re-rendering on a timeline is cheap; a stale number is not.
  private var syncLine: some View {
    TimelineView(.periodic(from: .now, by: 1)) { context in
      let status = SyncStatus(
        connection: store.bridge.connection,
        daemon: daemon?.state ?? .running,
        lastDelivery: store.lastDelivery,
        now: context.date
      )

      Button {
        guard status.isRecoverable else { return }
        store.bridge.reconnect()
        daemon?.start()
      } label: {
        HStack(spacing: Theme.Space.base) {
          StatusDot(level: status.level)
          Text(status.label)
            .font(Theme.Font.caption)
            .fontWeight(.regular)
            .foregroundStyle(Theme.Ink.tertiary)
            .lineLimit(1)
        }
      }
      .buttonStyle(.alap(radius: Theme.Radius.tight))
      .disabled(!status.isRecoverable)
      .help(status.isRecoverable ? "Click to retry" : status.label)
      .accessibilityLabel("Sync status: \(status.label)")
      // The recency ticks once a second, which without this trait means
      // VoiceOver interrupts with "Synced 12s ago, 13s ago, 14s ago" for as
      // long as focus rests here. `updatesFrequently` tells it to let the
      // reader poll the value instead of being read it.
      .accessibilityAddTraits(.updatesFrequently)
    }
  }

  // MARK: Line 2 — the mailbox, in numbers

  private var mailboxLine: some View {
    Text(mailboxReading)
      .font(Theme.Font.caption)
      .fontWeight(.regular)
      .foregroundStyle(Theme.Ink.tertiary)
      .lineLimit(1)
      .contentTransition(.numericText())
      .animation(Theme.Motion.fade, value: mailboxReading)
  }

  /// Drops to unread alone when the index is unavailable. "0 messages" over a
  /// full mailbox is a worse reading than no reading.
  ///
  /// Abbreviated above ten thousand, and not as a nicety: at the sidebar's
  /// width the full figures ran off the end and the line rendered as
  /// "32,429 messages · 1…", which is a reading that has stopped reading. The
  /// badges use the same formatter, so the two never disagree about what a
  /// number looks like.
  private var mailboxReading: String {
    // Abbreviated from a thousand, not ten: this line carries two figures and
    // a separator inside a 200pt sidebar, and "1,043" spends five characters
    // to say what "1.0k" says in four.
    let unread = "\(store.unreadTotal.abbreviatedCount(above: 1000)) unread"
    guard let indexed = store.indexedMessageCount else { return unread }
    return "\(indexed.abbreviatedCount()) messages · \(unread)"
  }

  // MARK: Line 3 — the latency reading, only when there is one

  /// Contextual, and absent otherwise: a permanently-empty slot is chrome,
  /// while an appearing reading is an event.
  ///
  /// Deliberately rejected here: conversation-open timing, which would mean
  /// instrumenting the whole `WKWebView` pipeline for a number already
  /// measured at ~3–4ms; and poll-cycle countdowns, which are telemetry rather
  /// than a reading.
  @ViewBuilder
  private var latencyLine: some View {
    if let search = store.lastSearch {
      Text("\(search.matched.formatted()) matched · \(search.displayDuration)")
        .font(Theme.Font.micro)
        .fontWeight(.regular)
        .foregroundStyle(Theme.Ink.tertiary)
        .lineLimit(1)
        .transition(.opacity)
        .contentTransition(.numericText())
    }
  }
}

/// The status light.
///
/// Solid in every terminal state, and pulsing only while something is
/// genuinely working — a light that moves for no reason is decoration, and a
/// light that moves only while working is instrument grammar. Gated on Reduce
/// Motion, because a permanent autoreversing animation is exactly what that
/// setting exists to stop.
private struct StatusDot: View {
  let level: SyncStatus.Level
  @State private var isPulsing = false

  var body: some View {
    Circle()
      .fill(tint)
      .frame(width: Theme.Space.snugDot, height: Theme.Space.snugDot)
      .opacity(isPulsing ? 0.35 : 1)
      .animation(Theme.Motion.fade, value: tint)
      .onAppear { startPulseIfWorking() }
      .onChange(of: isWorking) { _, _ in startPulseIfWorking() }
  }

  private var isWorking: Bool { level == .working }

  private func startPulseIfWorking() {
    guard isWorking, !Theme.Motion.isReduced else {
      isPulsing = false
      return
    }
    // The one deliberately-inline animation in the app, because a repeating
    // autoreverse is not a token: it has no end state and nothing else needs
    // one. It is gated above on the same Reduce Motion answer the tokens use.
    withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
      isPulsing = true
    }
  }

  private var tint: Color {
    switch level {
    case .ok: Theme.Accent.ok
    case .working: Theme.Accent.flag
    case .degraded: Theme.Ink.tertiary
    case .failed: Theme.Accent.red
    }
  }
}

extension Theme.Space {
  /// The status light's diameter.
  ///
  /// A real size rather than a spacing token used as one — the dot used to be
  /// `frame(width: Theme.Space.snug, height: Theme.Space.snug)`, which is the
  /// kind of borrowing that makes a spacing change resize an indicator.
  static let snugDot: CGFloat = 6
}
