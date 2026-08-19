import CoreGraphics
import Foundation

/// How dense the thread list is.
///
/// Density is a design value here rather than a comfort setting. The product's
/// thesis is fast triage of a 32,000-message mailbox, and at the old ~81pt row
/// a 900pt window showed **nine** conversations — not enough context to triage
/// against.
///
/// ## Why comfortable is the default and compact is not
///
/// Compact was the default first, on the argument that density is what a tool
/// for 32,000 messages looks like. Opening the running build settled it the
/// other way: the one-line row is normally drawn at 500-600pt and this list is
/// 300-340pt, so the subject truncated to a stub — the row told you who wrote
/// and never what about, which is the half that decides whether to open it.
///
/// Comfortable still shows roughly fourteen conversations against the old
/// nine, and shows a real subject line for every one of them. Compact remains a
/// setting rather than being deleted, because at a wider list it is the better
/// row and this list may yet get wider.
enum ListDensity: String, CaseIterable, Sendable, Identifiable {
  case compact
  case comfortable
  case relaxed

  var id: String { rawValue }

  /// The shipped default.
  ///
  /// Named here rather than left as a literal in `ReadingSettings` so the
  /// choice has one home and the test asserts the real thing.
  static let standard: ListDensity = .comfortable

  var title: String {
    switch self {
    case .compact: "Compact"
    case .comfortable: "Comfortable"
    case .relaxed: "Relaxed"
    }
  }

  var subtitle: String {
    switch self {
    case .compact: "One line per conversation. About 20 in a standard window."
    case .comfortable: "Two lines, with a single line of preview."
    case .relaxed: "Three lines, with a full preview."
    }
  }
}

/// The row's shape at a given density.
///
/// SwiftUI-free so the rules are assertable, following the same reasoning as
/// `ThreadRowAffordances` and `PaneLayout`: the row view is private to its
/// pane and a body cannot be tested, but *how tall a row is and what it shows*
/// is exactly the thing that must not drift.
///
/// ## Why the height is fixed rather than emergent
///
/// It used to be whatever the content stacked up to — measured at ~81pt, with
/// three different variants depending on whether the window was narrow and
/// whether the row happened to be flagged. So the list had no vertical rhythm
/// and `List` could not use a constant row height, which is a real scroll cost
/// at 500 rows. Fixing the height per density buys the rhythm and the
/// performance in the same move.
struct RowAnatomy: Equatable {
  /// Fixed row height. All three sit on the 4pt grid.
  let height: CGFloat
  /// Whether subject and snippet share one line, run on after an em-dash.
  let isSingleLine: Bool
  /// Lines of snippet, when it has a line of its own. Zero in `compact`, where
  /// the snippet runs on after the subject instead.
  let snippetLines: Int

  init(_ density: ListDensity) {
    switch density {
    case .compact:
      // The Superhuman-class row: dot, name, subject — snippet, then the
      // trailing cluster. ~20 conversations in a 900pt window, which is the
      // bar the direction sets — at the cost of a heavily truncated subject
      // until the list pane is wider than it is today.
      self.init(height: 44, isSingleLine: true, snippetLines: 0)
    case .comfortable:
      // What used to be the narrow-window variant, promoted to the default.
      // Name row, subject on its own line, one line of preview.
      self.init(height: 64, isSingleLine: false, snippetLines: 1)
    case .relaxed:
      // The old three-line row, at a height that is now chosen rather than
      // emergent.
      self.init(height: 80, isSingleLine: false, snippetLines: 2)
    }
  }

  private init(height: CGFloat, isSingleLine: Bool, snippetLines: Int) {
    self.height = height
    self.isSingleLine = isSingleLine
    self.snippetLines = snippetLines
  }

  /// How many conversations fit in a list of this height.
  ///
  /// The direction's stated bar is 20 in a 900pt window, and this is how that
  /// claim stays checkable.
  func visibleRows(inListHeight listHeight: CGFloat) -> Int {
    Int((listHeight / height).rounded(.down))
  }
}
