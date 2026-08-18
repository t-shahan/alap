import Foundation

/// Which of a thread row's gutter controls are showing, and in what state.
///
/// Extracted from `ThreadListRow` because that view is private to
/// `ContentView` and a SwiftUI body cannot be asserted against. The rules
/// below are the whole point of the gutter — a control that appears at the
/// wrong moment is the bug, not the drawing — so they live somewhere a test
/// can reach them, exactly as `PaneLayout` does for pane widths.
///
/// Nothing here knows about SwiftUI. Colour is the view's business; this type
/// answers only "is it there" and "which glyph".
struct ThreadRowAffordances: Equatable {
  /// The pointer is over this row.
  let isHovering: Bool
  /// This row is the one in the reading pane.
  let isOpen: Bool
  /// This row is ticked for a bulk action.
  let isChecked: Bool
  /// Anything at all is ticked, anywhere in the list.
  let isSelecting: Bool
  let isFlagged: Bool

  /// The checkbox shows under the pointer, and stays on every row once a
  /// selection exists — otherwise extending a selection means hunting for a
  /// control that only appears under the pointer, one row at a time.
  var showsCheckbox: Bool { isSelecting || isHovering }

  /// The flag shows whenever the row IS flagged, because that is the row's
  /// state and it has to be legible without pointing at it. Unflagged, it
  /// shows only as an offer: under the pointer, on the open row, or while a
  /// selection is being assembled.
  var showsFlag: Bool { isFlagged || isHovering || isOpen || isSelecting }

  var checkboxSymbol: String { isChecked ? "checkmark.square.fill" : "square" }
  var flagSymbol: String { isFlagged ? "flag.fill" : "flag" }

  /// Names the ACTION, not the state — it is a button, and VoiceOver reads it
  /// to someone deciding whether to press it.
  var flagLabel: String { isFlagged ? "Remove flag" : "Flag" }
}
