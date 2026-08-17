import SwiftUI

/// How the three panes divide the window at a given width.
///
/// ## The problem this solves
///
/// The sidebar and message list were fixed at 220pt and 380pt. That is 600pt
/// which never yields, so every point the window loses comes out of the reading
/// pane — the one actually holding content. At the 900pt minimum the reading
/// pane got 300pt, and its toolbar wants roughly 400pt for four labelled
/// buttons, so the labels wrapped mid-word into "Re/ply" and "Tra/sh".
///
/// The fix is ordering which panes give way. Navigation chrome shrinks first,
/// because a narrower sidebar is still a usable sidebar; a reading pane below
/// about 380pt stops being a reading pane at all.
struct PaneLayout: Equatable {
  let sidebarWidth: CGFloat
  let listWidth: CGFloat
  /// False on the narrowest windows, where the sidebar is behind a toggle.
  let showsSidebar: Bool
  /// Whether the reading pane's actions have room for their labels.
  let showsToolbarLabels: Bool
  /// Whether a thread row can afford a second line of preview text.
  let showsRowPreview: Bool

  /// Below this the reading pane stops being one.
  static let minimumReadingWidth: CGFloat = 380

  /// Chosen from the window's width.
  ///
  /// Deliberately a small number of named steps rather than continuous
  /// interpolation: a sidebar that creeps a few points narrower as the window
  /// resizes reads as drift, and text that reflows on every pixel is worse than
  /// text that reflows once at a threshold.
  static func forWidth(_ width: CGFloat) -> PaneLayout {
    // Every step satisfies width - (sidebar + list) >= minimumReadingWidth.
    // Written by hand and therefore easy to get wrong: the first version gave
    // the reading pane 290pt at 800pt wide, which is the exact bug this type
    // exists to prevent. A test now checks every step and both sides of every
    // boundary.
    switch width {
    case 1280...:
      PaneLayout(sidebarWidth: 240, listWidth: 400, showsSidebar: true,
                 showsToolbarLabels: true, showsRowPreview: true)
    case 1080..<1280:
      PaneLayout(sidebarWidth: 220, listWidth: 360, showsSidebar: true,
                 showsToolbarLabels: true, showsRowPreview: true)
    case 920..<1080:
      // The first step that drops labels. Four labelled pills need about
      // 400pt; icons need about 150pt and lose only a word the tooltip keeps.
      PaneLayout(sidebarWidth: 200, listWidth: 330, showsSidebar: true,
                 showsToolbarLabels: false, showsRowPreview: true)
    case 780..<920:
      // The sidebar goes before the list narrows further. A 240pt list is a
      // worse mail list than no sidebar is a navigation problem — mailboxes
      // are still one keystroke or one menu away.
      PaneLayout(sidebarWidth: 0, listWidth: 320, showsSidebar: false,
                 showsToolbarLabels: false, showsRowPreview: true)
    default:
      PaneLayout(sidebarWidth: 0, listWidth: 300, showsSidebar: false,
                 showsToolbarLabels: false, showsRowPreview: false)
    }
  }

}

private struct PaneLayoutKey: EnvironmentKey {
  static let defaultValue = PaneLayout.forWidth(1280)
}

extension EnvironmentValues {
  /// Read by panes that need to adapt. In the environment rather than passed
  /// down explicitly so a deeply nested toolbar does not need every view
  /// between it and the window to forward the value.
  var paneLayout: PaneLayout {
    get { self[PaneLayoutKey.self] }
    set { self[PaneLayoutKey.self] = newValue }
  }
}
