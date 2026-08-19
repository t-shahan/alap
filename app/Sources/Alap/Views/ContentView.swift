import SwiftUI

/// Three-pane mail workspace, implementing the `email-app-dark` Figma frame.
///
/// Fixed-width sidebar (220) and list (380) with a flexible reading pane, laid
/// out as a plain `HStack` rather than `NavigationSplitView`. The design has no
/// title bar and places the traffic lights inside the sidebar, which the
/// navigation container's own chrome would fight.
///
/// Every colour, size and spacing value comes from `Theme`.
struct ContentView: View {
  @Bindable var store: MailStore
  /// The sync engine, passed explicitly rather than through the environment.
  ///
  /// It is one value one level deep, and the explicit seam is what lets a test
  /// hand the footer a canned daemon state — which matters, because the whole
  /// point of reading it is a failure mode with no other symptom.
  var daemon: SyncDaemon?
  @FocusState private var listFocused: Bool
  /// An explicit choice about the sidebar, or nil to follow the window width.
  ///
  /// The width-derived default is right on first sight and wrong the moment
  /// someone disagrees with it — a wide window whose owner wants the room for
  /// mail, or a narrow one they want to navigate. So the layout decides until
  /// the reader says otherwise, and after that the reader decides. Resizing
  /// does not silently take the choice back.
  @State private var sidebarOverride: Bool?

  var body: some View {
    GeometryReader { geometry in
      let layout = PaneLayout.forWidth(geometry.size.width)
      panes(layout, showsSidebar: sidebarOverride ?? layout.showsSidebar)
        .environment(\.paneLayout, layout)
        // Bottom-LEADING, clear of the composer's corner: an undo notice hidden
        // behind the composer would be an offer nobody could take.
        .overlay(alignment: .bottomLeading) { undoOverlay }
        .overlay(alignment: .bottomTrailing) { composerOverlay(layout) }
    }
    .background(Theme.Surface.base)
    .task { store.start() }
    // `.task` runs before the window becomes key, so assigning focus there is
    // silently dropped and shortcuts do nothing until the user clicks a row.
    .defaultFocus($listFocused, true)
    .background(BridgeHost(bridge: store.bridge).frame(width: 0, height: 0))
  }

  /// The notice enters and leaves like a notice rather than a glitch.
  ///
  /// `UndoBanner` has always declared
  /// `.transition(.move(edge: .bottom).combined(with: .opacity))`, and it has
  /// never played: a SwiftUI transition only runs when the state change that
  /// inserts the view happens inside an animated transaction, and none of the
  /// three paths that set `banner` — record, timer expiry, dismiss — was
  /// wrapped. So the banner popped in and popped out, always.
  ///
  /// The animation is driven from the CONTAINER rather than from those three
  /// call sites, which is the difference between fixing this and fixing it
  /// until somebody adds a fourth path. Keyed on the entry's id, so a NEW
  /// action replaces the banner — animated — rather than mutating the old
  /// one's text in place.
  @ViewBuilder
  private var undoOverlay: some View {
    ZStack(alignment: .bottomLeading) {
      if let entry = store.undoStack.banner {
        UndoBanner(
          entry: entry,
          undo: { Task { await store.undoStack.undo() } },
          dismiss: { store.undoStack.dismissBanner() }
        )
        .id(entry.id)
      }
    }
    .animation(Theme.Motion.standard, value: store.undoStack.banner?.id)
  }

  /// The compose button becomes the panel.
  ///
  /// ## What was wrong
  ///
  /// `ComposerPanel` declared an entrance transition and `ComposeLaunchButton`
  /// carried a doc comment claiming that occupying the same corner "is what
  /// makes the panel feel like it came from somewhere". Neither was true in
  /// the running app: of the six paths that open the composer — sidebar button,
  /// FAB, ⌘N, Reply, Send-then-close, and the ✕ — only the ✕ was wrapped in
  /// `withAnimation`. The composer popped in through every path anyone
  /// actually takes.
  ///
  /// Driving it from the container fixes all six at once and the seventh in
  /// advance. The `ZStack` matters: `if`/`else` branches inside an overlay do
  /// not cross-animate reliably without a shared identity container. The scale
  /// anchors mean both views grow from and shrink into the same corner, which
  /// alone delivers most of the metaphor.
  ///
  /// ## `matchedGeometryEffect` was tried here and removed. Do not re-add it.
  ///
  /// The hero version of this — pairing the button and the panel on a shared
  /// `id` with `anchor: .bottomTrailing` — was implemented and inspected on a
  /// running build at 900pt, where the FAB exists. It was worse, and not in
  /// the way that was anticipated.
  ///
  /// The predicted risk was the `TextEditor` re-laying-out mid-animation. That
  /// did not happen: the fields render cleanly at every intermediate frame.
  /// What happens instead is that the panel enters from the **top-left**,
  /// travels down and right, and then overshoots past the corner before
  /// settling — captured across a frame burst. So the modifier produces the
  /// precise opposite of the metaphor it was meant to deliver, which is a
  /// panel that grew out of the button in the bottom-right corner.
  ///
  /// The cause is that the interpolated frame overrides the `ZStack`'s
  /// `.bottomTrailing` alignment rather than cooperating with it, and the two
  /// matched views carry their own differing `.padding` inside the measured
  /// frame — so the geometry being interpolated between is not the geometry
  /// either view actually occupies.
  ///
  /// Anyone re-attempting this needs to move the padding OUTSIDE both matched
  /// views first, and then verify on a running build rather than in a
  /// screenshot: a still frame cannot show a trajectory. The corner-scale
  /// entrance below is already the difference between "pops" and "expands from
  /// the corner", and it is correct.
  @ViewBuilder
  private func composerOverlay(_ layout: PaneLayout) -> some View {
    ZStack(alignment: .bottomTrailing) {
      if store.composer.isVisible {
        ComposerPanel(store: store, composer: store.composer)
          .transition(.scale(scale: 0.92, anchor: .bottomTrailing)
            .combined(with: .opacity))
      } else if !layout.showsSidebar {
        // ONE compose affordance at any width. The sidebar's full-width blue
        // "New Message" button and this circular FAB used to be visible
        // simultaneously, both in the accent colour, both doing the same
        // thing — and the FAB is a Material pattern that reads foreign on
        // macOS and overlaps content besides. It survives only for the case
        // that justifies it: the sidebar is hidden and its button with it.
        ComposeLaunchButton { store.startNewMessage() }
          .transition(.scale(scale: 0.75, anchor: .bottomTrailing)
            .combined(with: .opacity))
      }
    }
    .animation(Theme.Motion.panel, value: store.composer.isVisible)
  }
}

// MARK: - Panes

extension ContentView {
  @ViewBuilder
  fileprivate func panes(_ layout: PaneLayout, showsSidebar: Bool) -> some View {
    HStack(spacing: 0) {
      if showsSidebar {
        Sidebar(store: store, daemon: daemon)
          // The layout's width when the layout is the one showing it; the full
          // width when the reader asked for it at a size that would not.
          .frame(width: layout.showsSidebar ? layout.sidebarWidth : Theme.Size.sidebar)
          .transition(.move(edge: .leading))
      }

      MessageListPane(
        store: store,
        // Always offered, at every width. It used to appear only below 920pt,
        // where the layout had already taken the sidebar away — so the control
        // existed to undo a decision the reader never made, and there was no
        // way to make the opposite one.
        toggleSidebar: {
          withAnimation(Theme.Motion.standard) { sidebarOverride = !showsSidebar }
        },
        sidebarIsShowing: showsSidebar,
        isKeyboardFocused: listFocused
      )
      .frame(width: layout.listWidth)
      .triageShortcuts(store: store, listFocused: $listFocused)

      ReadingPane(store: store)
        // A floor rather than only a flexible width: below this the pane stops
        // being readable, and it is better for the window to refuse to squeeze
        // it than to render a column two words wide.
        .frame(minWidth: PaneLayout.minimumReadingWidth, maxWidth: .infinity)
    }
  }
}

// MARK: - Structure

extension View {
  /// A 1pt structural rule down a pane's trailing edge.
  ///
  /// The design carried pane separation entirely in surface steps and
  /// explicitly avoided dividers, "which is what keeps the interface quiet".
  /// That is exactly why the light theme collapsed: the steps measure
  /// 1.08–1.16:1, and at the boundary that matters most — list to reading pane
  /// — the light theme managed 1.04:1, which is to say nothing at all. An
  /// instrument uses rules. Keep the quiet surfaces **and** add the rule.
  ///
  /// An overlay rather than a `Divider()`: a divider wants to participate in
  /// layout, and these panes' widths are arithmetic that `PaneLayoutTests`
  /// asserts. An overlay cannot shift it.
  ///
  /// These are DECORATIVE hairlines — the 3:1 `borderStrong` floor governs
  /// focus rings and meaningful outlines, not seams between surfaces that
  /// already separate.
  @MainActor
  func paneRule() -> some View {
    overlay(alignment: .trailing) {
      Rectangle()
        .fill(Theme.Surface.border.opacity(0.6))
        .frame(width: 1)
    }
  }
}
