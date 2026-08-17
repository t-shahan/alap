import Foundation
import Observation

/// Recently performed actions, and how to reverse them.
///
/// ## Why this exists
///
/// Archive and Trash were one-way from inside the app: repairing a mis-keyed
/// `E` meant leaving for Gmail and finding the message there. Bulk actions made
/// that sharper — the same slip now moves fifty conversations instead of one.
///
/// ## Why it stores a closure rather than a diff
///
/// The alternative is recording the state before the action and restoring it.
/// That requires the undo path to know how to write every field it might have
/// touched, and to keep working as those fields change.
///
/// Every action here already has an exact inverse expressed as another action —
/// archive/restore, read/unread, flag/unflag — so the reversal is a call the
/// store already knows how to make. Undo becomes "do the opposite", which
/// cannot drift out of step with the thing it reverses.
///
/// ## What it does NOT promise
///
/// Undoing is a new forward operation, not time travel. It queues its own
/// outbox row and reaches Gmail moments later, so a thread archived and
/// restored ends where it started but visits the archive on the way. Nothing
/// here can retract a message that has already been sent.
@MainActor
@Observable
final class UndoStack {
  struct Entry: Identifiable {
    let id = UUID()
    /// Phrased in the past tense, for a banner reporting what just happened.
    let description: String
    /// Reverses it. Async because every reversal is a mutation.
    let reverse: () async -> Void
  }

  /// The most recent reversible action, or nil.
  private(set) var top: Entry?

  /// Shown in the undo banner. Cleared when the banner is dismissed or expires.
  private(set) var banner: Entry?

  /// How long the banner stays up.
  ///
  /// Long enough to notice and react to, short enough not to sit over the list
  /// after attention has moved on. Undo remains available on ⌘Z after the
  /// banner goes — dismissing the notice is not withdrawing the offer.
  static let bannerDuration: Duration = .seconds(6)

  @ObservationIgnored private var bannerTask: Task<Void, Never>?

  /// Depth of one.
  ///
  /// A deep stack sounds better than it is: undoing several mail operations in
  /// sequence means reversing them against a mailbox that has since changed,
  /// and each step is a fresh round trip to Gmail that can fail independently.
  /// One step covers the case this exists for — the action just taken was
  /// wrong — without pretending to a history it cannot honour.
  func record(_ description: String, reverse: @escaping () async -> Void) {
    let entry = Entry(description: description, reverse: reverse)
    top = entry
    show(entry)
  }

  /// Reverses the most recent action, if there is one.
  func undo() async {
    guard let entry = top else { return }
    // Cleared FIRST. Reversing is itself an action that takes time, and a
    // second ⌘Z arriving during it would otherwise reverse the same thing
    // twice — which for archive/restore is harmless and for trash is not.
    top = nil
    dismissBanner()
    await entry.reverse()
  }

  func dismissBanner() {
    bannerTask?.cancel()
    bannerTask = nil
    banner = nil
  }

  private func show(_ entry: Entry) {
    bannerTask?.cancel()
    banner = entry
    bannerTask = Task { [weak self] in
      try? await Task.sleep(for: UndoStack.bannerDuration)
      guard !Task.isCancelled else { return }
      // Only clears the banner if it is still THIS one — a newer action has
      // its own timer, and this one expiring must not take it down early.
      if self?.banner?.id == entry.id { self?.banner = nil }
    }
  }
}
