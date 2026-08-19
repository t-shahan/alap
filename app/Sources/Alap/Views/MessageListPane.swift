import SwiftUI

/// The conversation list, its search field and its bulk-action toolbar.
struct MessageListPane: View {
  @Bindable var store: MailStore
  /// Shows or hides the sidebar. Always available.
  var toggleSidebar: (() -> Void)?
  /// Whether the sidebar is currently showing, so the control can say which
  /// way it goes.
  var sidebarIsShowing: Bool = true
  /// True when this pane holds keyboard focus, so the open row can show it.
  var isKeyboardFocused: Bool = false

  var body: some View {
    VStack(spacing: 0) {
      toolbar
      Divider().overlay(Theme.Surface.border.opacity(0.6))
      list
    }
    .background(Theme.Surface.base)
    .paneRule()
  }

  // MARK: Toolbar

  private var toolbar: some View {
    VStack(spacing: Theme.Space.loose) {
      // The reveal button sits OUTSIDE the field's chrome.
      //
      // It used to be inside the same `HStack` the field background wrapped,
      // immediately left of the magnifying glass — so a navigation control was
      // nested inside a text-input affordance and clicking near it was
      // ambiguous about which one you meant.
      HStack(spacing: Theme.Space.base) {
        if let toggleSidebar {
          Button(action: toggleSidebar) {
            // The glyph reports the STATE, filled when the sidebar is showing,
            // and the label reports the ACTION. Naming both the same thing is
            // how a toggle ends up contradicting itself.
            Image(systemName: sidebarIsShowing ? "sidebar.left" : "sidebar.leading")
              .font(Theme.Icon.medium)
              .padding(Theme.Space.tight)
          }
          .buttonStyle(.alap())
          .help(sidebarIsShowing ? "Hide mailboxes (⌃⌘S)" : "Show mailboxes (⌃⌘S)")
          .accessibilityLabel(sidebarIsShowing ? "Hide mailboxes" : "Show mailboxes")
          .keyboardShortcut("s", modifiers: [.control, .command])
        }
        searchField
      }

      HStack {
        Text(countLabel)
          .font(Theme.Font.caption)
          .fontWeight(store.hasMultipleSelected ? .semibold : .regular)
          // Ink, not blue. A blue count as a "you are in selection mode"
          // signal was redundant: the reading pane has become the
          // `BulkActionPanel`, which IS the mode signal, and blue means unread
          // or the primary action.
          .foregroundStyle(store.hasMultipleSelected ? Theme.Ink.primary
                                                     : Theme.Ink.secondary)
          .monospacedDigit()
          .contentTransition(.numericText())
          .animation(Theme.Motion.fade, value: countLabel)
          .lineLimit(1)
        Spacer(minLength: Theme.Space.base)

        // The icon states what the press will DO, not what is currently true:
        // filled means "this will clear", empty means "this will select all".
        toolbarButton(
          store.selectAllWouldClear ? "checkmark.square.fill" : "checkmark.square",
          store.selectAllWouldClear ? "Deselect all" : "Select all",
          isEnabled: store.canSelectAll,
          // Blue survives here as CHECKED STATE on a selection control, which
          // is the platform's own idiom rather than a new meaning.
          tint: store.selectAllWouldClear ? Theme.Accent.blue : nil
        ) { store.toggleSelectAll() }
        toolbarButton("archivebox", "Archive", isEnabled: store.hasSelection) {
          Task { await store.archiveSelection() }
        }
        toolbarButton("envelope.open", "Toggle read", isEnabled: store.hasSelection) {
          Task { await store.markSelectionRead() }
        }
        // Flag is deliberately absent from this toolbar. It required a
        // selection, so it spent its life disabled — and once every row grew
        // its own flag button, it was disabled AND duplicated. Restyling a
        // control nobody needs is not the fix for it.
      }
    }
    .padding(Theme.Space.loose)
  }

  private var searchField: some View {
    HStack(spacing: Theme.Space.base) {
      Image(systemName: "magnifyingglass")
        .font(Theme.Icon.small)
        .foregroundStyle(Theme.Ink.secondary)
      TextField("Search \(store.selectedMailbox.title)", text: $store.searchText)
        .textFieldStyle(.plain)
        .font(Theme.Font.small)
      if !store.searchText.isEmpty {
        Button {
          store.searchText = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
            .font(Theme.Icon.small)
            .foregroundStyle(Theme.Ink.tertiary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Clear search")
      }
    }
    .padding(.horizontal, Theme.Space.base)
    .frame(height: 28)
    .background(Theme.Surface.sunken, in: .rect(cornerRadius: Theme.Radius.control))
  }

  private var countLabel: String {
    if store.hasMultipleSelected {
      return "\(store.selectionCount) selected"
    }
    return store.threadsLoaded ? "\(store.threads.count) conversations" : "Loading…"
  }

  /// - Parameter isEnabled: Stated per button rather than shared.
  ///
  /// This used to be one rule for all of them — `selectedThread == nil` — which
  /// was wrong in two directions at once. It disabled Select All exactly when
  /// nothing was selected, which is the only time it is useful; and it disabled
  /// every bulk action once SEVERAL were selected, because `selectedThread` is
  /// deliberately nil in that case.
  private func toolbarButton(
    _ symbol: String, _ label: String, isEnabled: Bool,
    tint: Color? = nil,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      // NO `foregroundStyle` here. It would sit inside the style's own wrap
      // and win, which silently opted these three buttons out of the disabled
      // treatment — and they spend most of their life disabled. The tint goes
      // to the style, which is the thing that knows whether they are enabled.
      Image(systemName: symbol)
        .font(Theme.Icon.medium)
        .padding(.horizontal, Theme.Space.base)
        .padding(.vertical, Theme.Space.tight)
    }
    .buttonStyle(.alap(tint: tint ?? Theme.Ink.secondary))
    .disabled(!isEnabled)
    .help(label)
    .accessibilityLabel(label)
  }

  // MARK: List

  private var list: some View {
    Group {
      if store.threads.isEmpty && store.threadsLoaded {
        EmptyState(
          title: store.isSearching ? "No matches" : store.selectedMailbox.emptyTitle,
          message: store.isSearching
            ? "Nothing in the local index matches “\(store.searchText)”."
            : store.selectedMailbox.emptyMessage,
          symbol: store.isSearching ? "magnifyingglass" : store.selectedMailbox.systemImage,
          actionTitle: store.isSearching ? "Clear search" : nil,
          action: store.isSearching ? { store.searchText = "" } : nil
        )
      } else {
        ScrollViewReader { proxy in
          threadList
            // Keyboard navigation must keep the selection on screen.
            .onChange(of: store.selectedThreadID) { _, id in
              guard let id else { return }
              withAnimation(Theme.Motion.quick) { proxy.scrollTo(id, anchor: .center) }
            }
        }
      }
    }
    // Reaching inbox zero deserves a beat of settle rather than a jump cut.
    // Subtle on purpose: this is a moment, not a celebration.
    .animation(Theme.Motion.fade, value: store.threads.isEmpty)
  }

  private var threadList: some View {
    // Bound to what is OPEN, not to what is ticked.
    //
    // This was a Set binding, which is what makes AppKit treat the list as
    // multi-select — and so every plain click wrote the row straight into the
    // ticked set. An optional binding is a single-selection list, which is what
    // reading mail actually is. Ticking is the checkbox's job, and only the
    // checkbox's.
    List(selection: $store.selectedThreadID) {
      ForEach(store.threads) { thread in
        row(for: thread)
      }

      // A sentinel at the very end, rather than relying on a row 40 from it.
      // This is BOTH the scroll trigger and a visible control: growth used to
      // depend entirely on a near-the-end row appearing, and when that signal
      // did not arrive the mailbox simply stopped at 200 with nothing to
      // indicate that 17,000 more existed.
      if store.hasMoreThreads {
        LoadMoreRow(
          isLoading: store.isLoadingMoreThreads,
          loaded: store.threads.count,
          load: { store.growThreads() }
        )
        .listRowInsets(EdgeInsets())
        .listRowBackground(Theme.Surface.base)
        .onAppear { store.growThreads() }
      }
    }
    .listStyle(.plain)
    .scrollContentBackground(.hidden)
    .background(Theme.Surface.base)
    // AppKit draws its own focus ring around the selected row, inset by
    // several points on each side with its own corner radius — so it sat
    // visibly INSIDE a selection fill that is already full-bleed, and stopped
    // short of the timestamp it was supposed to be enclosing. The row draws
    // its own indicator instead, which is the only way to make the two agree
    // about where a row ends.
    .focusEffectDisabled()
  }

  /// Extracted from `threadList` because the combined modifier chain exceeded
  /// the type-checker's budget.
  private func row(for thread: ThreadRow) -> some View {
    ThreadListRow(
      thread: thread,
      accountTint: store.tint(forAccount: thread.accountId),
      isSelected: store.selection.contains(thread.id),
      isSelecting: !store.selection.isEmpty,
      isOpen: thread.id == store.selectedThreadID,
      isKeyboardFocused: isKeyboardFocused && thread.id == store.selectedThreadID,
      toggle: { store.toggleSelection(of: thread.id) },
      flag: { Task { await store.toggleStar(thread) } }
    )
    .tag(thread.id)
      // List is lazy, so a row appearing IS the viewport reaching it. That
      // makes this the cheapest possible scroll signal — no offset tracking,
      // no content-height measurement per frame.
      .onAppear { store.growThreadsIfNeeded(reaching: thread.id) }
      .listRowInsets(EdgeInsets())
      .listRowBackground(background(for: thread))
      // Full-bleed, so the separator starts at the pane edge rather than at
      // the row's content.
      //
      // `List` insets separators to the leading edge of the row's TEXT by
      // default, which left the account rail as the one column nothing
      // separated — a ladder of hairlines with a coloured strip running past
      // the end of each rung. The review called that the worst of both
      // options; now that the pane seams carry a real rule, the row separator
      // should either match them or not exist, and matching is cheaper than
      // arguing about density.
      .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
      .contextMenu { menu(for: thread) }
  }

  /// Three distinct states, not one.
  ///
  /// A row can be SELECTED (part of a bulk action) and separately FOCUSED (the
  /// one in the reading pane). With several selected there is no focused row,
  /// and the previous version only ever drew the focused one — so selecting
  /// two rows made the highlight vanish entirely.
  ///
  /// The third is the arrival flash. Priority order matters: what is open and
  /// what is ticked both outrank "this just landed", because those are things
  /// the reader did and the flash is something that happened to them.
  ///
  /// Blue for the flash, deliberately: the accent means unread and the primary
  /// action, and an arrival IS unread. No new colour meaning is introduced, and
  /// a 10% tint is a background shift of about 1.1:1 in every palette — well
  /// under any text-contrast concern.
  ///
  /// The listRowBackground also has to carry this itself: an opaque background
  /// masks List's own selection highlight, so nothing else is going to draw it.
  private func background(for thread: ThreadRow) -> Color {
    if thread.id == store.selectedThreadID { return Theme.Surface.selection }
    if store.selection.contains(thread.id) { return Theme.Surface.selection.opacity(0.55) }
    if store.recentlyArrived.contains(thread.id) { return Theme.Accent.blue.opacity(0.10) }
    return Theme.Surface.base
  }

  /// Every item acts on the row under the pointer.
  ///
  /// All three used to call the `…OnSelection` variants, which operate on
  /// whatever is OPEN — so right-clicking any other row archived, marked or
  /// flagged a different conversation than the one being pointed at. Flag was
  /// fixed first; these are the other two.
  @ViewBuilder
  private func menu(for thread: ThreadRow) -> some View {
    Button("Archive") { Task { await store.archive([thread]) } }
    Button(thread.isUnread ? "Mark as Read" : "Mark as Unread") {
      Task { await store.setRead([thread], isRead: thread.isUnread) }
    }
    Button(thread.isStarred ? "Remove Flag" : "Flag") {
      Task { await store.toggleStar(thread) }
    }
  }
}

// MARK: - Undo

/// Reports what just happened, and offers to take it back.
///
/// Placed bottom-left, clear of the composer's corner. Deliberately transient:
/// it is a notice, not a dialog, and it must not require dismissing before the
/// mailbox can be used again — the whole point of fast triage is that nothing
/// interrupts it.
///
/// The offer outlives the notice. ⌘Z keeps working after the banner fades,
/// because letting the message expire is not the same as declining it. Its
/// entrance and exit are owned by the overlay in `ContentView`; a notice that
/// fades out on its own reads as "the offer lapsed", where one that vanishes
/// between frames reads as a bug.
struct UndoBanner: View {
  let entry: UndoStack.Entry
  let undo: () -> Void
  let dismiss: () -> Void

  var body: some View {
    HStack(spacing: Theme.Space.loose) {
      Text(entry.description)
        .font(Theme.Font.small)
        .foregroundStyle(Theme.Ink.primary)
        .lineLimit(1)

      Button("Undo", action: undo)
        .buttonStyle(.alap(radius: Theme.Radius.tight))
        .font(Theme.Font.smallEmphasis)
        // The one action this context offers, so it keeps the accent — in
        // `blueText`, which is the token for blue drawn as a label. The fill
        // blue measured 3.82:1 here.
        .foregroundStyle(Theme.Accent.blueText)

      Button(action: dismiss) {
        Image(systemName: "xmark").font(Theme.Icon.micro)
      }
      .buttonStyle(.alap(radius: Theme.Radius.tight))
      .accessibilityLabel("Dismiss")
    }
    .padding(.horizontal, Theme.Space.wide)
    .frame(height: 36)
    .background(Theme.Surface.control, in: .capsule)
    .overlay { Capsule().strokeBorder(Theme.Surface.border, lineWidth: 1) }
    .elevation(Theme.Elevation.lifted)
    .padding(Theme.Space.pane)
    .transition(.move(edge: .bottom).combined(with: .opacity))
  }
}

// MARK: - The end of the list

/// The end of the loaded list, and the way past it.
///
/// Serves two purposes that used to have none. It TELLS you the list is not
/// the whole mailbox — previously it just ended, indistinguishable from having
/// reached the last conversation — and it gives an explicit way to continue
/// when the scroll trigger does not fire.
struct LoadMoreRow: View {
  let isLoading: Bool
  let loaded: Int
  let load: () -> Void

  var body: some View {
    HStack(spacing: Theme.Space.base) {
      Spacer()
      if isLoading {
        ProgressView().controlSize(.small)
        Text("Loading more…")
          .font(Theme.Font.small)
          .foregroundStyle(Theme.Ink.tertiary)
      } else {
        Button(action: load) {
          Text("Load more")
            .font(Theme.Font.smallEmphasis)
            .foregroundStyle(Theme.Accent.blueText)
            .padding(.horizontal, Theme.Space.wide)
            .padding(.vertical, Theme.Space.tight)
            .background(Theme.Accent.blueText.opacity(0.12),
                        in: .rect(cornerRadius: Theme.Radius.control))
        }
        .buttonStyle(.alap())
        Text("\(loaded.formatted()) loaded")
          .font(Theme.Font.micro)
          .fontWeight(.regular)
          .foregroundStyle(Theme.Ink.tertiary)
          .monospacedDigit()
      }
      Spacer()
    }
    .padding(.vertical, Theme.Space.loose)
    // The button↔spinner swap crossfades; both states occupy the same row
    // height, so the list never shifts while it switches.
    .animation(Theme.Motion.fade, value: isLoading)
  }
}
