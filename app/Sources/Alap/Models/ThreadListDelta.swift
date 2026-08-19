import Foundation

/// Which ids in a thread-list update count as newly arrived mail, and whether
/// the change should animate at all.
///
/// ## Why this is a value and not an `if` in the callback
///
/// Motion timing is not unit-testable and nobody should pretend otherwise. The
/// *rules for when motion applies* are, and they are the part that goes wrong:
/// a mailbox switch that plays 500 insert animations, or a pagination page that
/// flashes 200 rows as "new mail", are both the same bug — the app treating
/// navigation as an event. Extracting the decision follows the codebase's own
/// `ThreadRowAffordances` precedent.
///
/// SwiftUI-free on purpose. This answers "does it animate" and "what is new";
/// how that is drawn is the view's business.
struct ThreadListDelta: Equatable {
  /// True when this update represents *events* rather than navigation.
  let animates: Bool
  /// Ids present now that were not present before. Empty whenever the update
  /// does not animate — a first paint has no arrivals, it has contents.
  let arrivals: Set<String>

  /// - Parameters:
  ///   - listWasLive: False for the first delivery of a list. `resubscribe`
  ///     clears `threadsLoaded` before every mailbox switch and every search,
  ///     so this is already tracked; a mailbox switch is navigation, not mail
  ///     arriving.
  ///   - isGrowing: True while a larger page is in flight. Appended history is
  ///     not arriving mail.
  init(previous: [String], current: [String], listWasLive: Bool, isGrowing: Bool) {
    animates = listWasLive && !isGrowing
    arrivals = animates ? Set(current).subtracting(previous) : []
  }

  /// True when the update changed which conversations exist at all.
  ///
  /// Drives the status rail's "synced N ago": a re-render that reorders or
  /// re-decodes the same set is not a delivery.
  var changedMembership: Bool { !arrivals.isEmpty }
}
