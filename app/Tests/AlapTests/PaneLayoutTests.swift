import Foundation
import Testing
@testable import Alap

/// How the panes divide a window.
///
/// The bug these exist for: the sidebar and list were fixed at 220 and 380, so
/// 600pt never yielded and every point the window lost came out of the reading
/// pane. At the 900pt minimum that left it 300pt while its toolbar wanted ~400,
/// and the labels wrapped mid-word into "Re/ply" and "Tra/sh".
@MainActor
struct PaneLayoutTests {
  /// Every width the app can be, plus the boundaries between steps.
  private let widths: [CGFloat] = [680, 700, 779, 780, 800, 919, 920, 1000,
                                   1079, 1080, 1200, 1279, 1280, 1440, 1920, 3000]

  @Test("The reading pane always clears its floor")
  func readingPaneNeverSqueezed() {
    // The whole point. Navigation chrome yields first, because a narrower
    // sidebar is still a sidebar and a 300pt reading pane is not one.
    for width in widths {
      let layout = PaneLayout.forWidth(width)
      let chrome = layout.sidebarWidth + layout.listWidth
      let reading = width - chrome
      #expect(reading >= PaneLayout.minimumReadingWidth,
              "at \(width)pt the reading pane got \(reading)pt")
    }
  }

  @Test("Chrome never exceeds the window")
  func chromeFits() {
    for width in widths {
      let layout = PaneLayout.forWidth(width)
      #expect(layout.sidebarWidth + layout.listWidth < width, "overflow at \(width)pt")
    }
  }

  @Test("Panes only ever grow with the window")
  func layoutIsMonotonic() {
    // A pane that got narrower as the window got wider would be a step
    // boundary written the wrong way round — easy to do and hard to see.
    var previousSidebar: CGFloat = 0
    var previousList: CGFloat = 0
    for width in widths.sorted() {
      let layout = PaneLayout.forWidth(width)
      #expect(layout.sidebarWidth >= previousSidebar, "sidebar shrank at \(width)pt")
      #expect(layout.listWidth >= previousList, "list shrank at \(width)pt")
      previousSidebar = layout.sidebarWidth
      previousList = layout.listWidth
    }
  }

  @Test("Labels are dropped before anything is allowed to wrap")
  func labelsDropOnNarrowWindows() {
    // Four labelled pills need about 400pt; four icons need about 150.
    #expect(!PaneLayout.forWidth(900).showsToolbarLabels)
    #expect(!PaneLayout.forWidth(800).showsToolbarLabels)
    #expect(PaneLayout.forWidth(1200).showsToolbarLabels)
  }

  @Test("The reading pane has room for labels wherever they are shown")
  func labelsOnlyWhenTheyFit() {
    // The condition that was actually violated: labels shown in a pane too
    // narrow to hold them.
    for width in widths {
      let layout = PaneLayout.forWidth(width)
      guard layout.showsToolbarLabels else { continue }
      let reading = width - layout.sidebarWidth - layout.listWidth
      #expect(reading >= 420, "labels shown with only \(reading)pt at \(width)pt")
    }
  }

  @Test("The sidebar hides rather than shrinking indefinitely")
  func sidebarHidesWhenTiny() {
    // Past a point it is a column of truncated words, and mailboxes are
    // reachable from the menu and the keyboard regardless.
    #expect(!PaneLayout.forWidth(700).showsSidebar)
    #expect(PaneLayout.forWidth(700).sidebarWidth == 0)
    // It returns at 920 — the first width with room for a 200pt sidebar, a
    // 330pt list and a reading pane above its floor.
    #expect(!PaneLayout.forWidth(900).showsSidebar)
    #expect(PaneLayout.forWidth(920).showsSidebar)
  }

  @Test("The minimum window size supports the narrowest layout")
  func minimumWindowWorks() {
    // 680 is not arbitrary: hidden sidebar + 300 list + the 380 floor.
    let layout = PaneLayout.forWidth(680)
    #expect(layout.sidebarWidth + layout.listWidth + PaneLayout.minimumReadingWidth <= 680)
  }

  @Test("A given width always produces the same layout")
  func layoutIsDeterministic() {
    // Named steps rather than interpolation: a sidebar creeping a few points
    // as the window resizes reads as drift.
    for width in widths {
      #expect(PaneLayout.forWidth(width) == PaneLayout.forWidth(width))
    }
  }
}
