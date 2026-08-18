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
  @FocusState private var listFocused: Bool
  /// Only meaningful on the narrowest windows, where the sidebar is hidden by
  /// default and this reveals it.
  @State private var sidebarRevealed = false

  var body: some View {
    GeometryReader { geometry in
      let layout = PaneLayout.forWidth(geometry.size.width)
      panes(layout)
        .environment(\.paneLayout, layout)
    }
    .background(Theme.Surface.base)
    .task { store.start() }
    // `.task` runs before the window becomes key, so assigning focus there is
    // silently dropped and shortcuts do nothing until the user clicks a row.
    .defaultFocus($listFocused, true)
    // Bottom-trailing overlay rather than a sheet: the mailbox behind stays
    // live and clickable, so looking something up mid-message does not mean
    // discarding the draft.
    .overlay(alignment: .bottomLeading) {
      // Bottom-LEADING, clear of the composer's corner: an undo notice hidden
      // behind the composer would be an offer nobody could take.
      if let entry = store.undoStack.banner {
        UndoBanner(
          entry: entry,
          undo: { Task { await store.undoStack.undo() } },
          dismiss: { store.undoStack.dismissBanner() }
        )
      }
    }
    .overlay(alignment: .bottomTrailing) {
      if store.composer.isVisible {
        ComposerPanel(store: store, composer: store.composer)
      } else {
        ComposeLaunchButton { store.startNewMessage() }
      }
    }
    .background(BridgeHost(bridge: store.bridge).frame(width: 0, height: 0))
  }
}

// MARK: - Sidebar

extension ContentView {
  @ViewBuilder
  fileprivate func panes(_ layout: PaneLayout) -> some View {
    HStack(spacing: 0) {
      if layout.showsSidebar || sidebarRevealed {
        Sidebar(store: store)
          .frame(width: layout.showsSidebar ? layout.sidebarWidth : 220)
          .transition(.move(edge: .leading))
      }

      MessageListPane(store: store, revealSidebar: layout.showsSidebar ? nil : {
        withAnimation(Theme.Motion.standard) { sidebarRevealed.toggle() }
      })
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

private struct Sidebar: View {
  @Bindable var store: MailStore
  @State private var connector = AccountConnector()

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Space.wide) {
      // Clears the window's traffic lights, which sit over this pane because
      // the title bar is hidden.
      Color.clear.frame(height: 28)

      newMessageButton

      ScrollView {
        VStack(alignment: .leading, spacing: Theme.Space.wide) {
          // Unified first. The whole point of the labels-not-folders model is
          // that "Inbox" means every account's INBOX at once, so per-account
          // sections are the exception below, not the primary navigation.
          section("MAILBOXES", Mailbox.standard)
          section("SMART FILTERS", Mailbox.smartFilters)
          accountsSection
        }
      }
      .scrollIndicators(.never)

      Spacer(minLength: 0)

      HStack(spacing: Theme.Space.base) {
        ConnectionIndicator(state: store.bridge.connection) {
          store.bridge.reconnect()
        }
        Spacer(minLength: 0)
        ThemeSwitcher()
      }
      .padding(.horizontal, Theme.Space.loose)
    }
    .sheet(isPresented: .constant(connector.phase != .idle)) {
      ConnectAccountSheet(connector: connector)
    }
    .padding(.horizontal, Theme.Space.cosy)
    .padding(.top, Theme.Space.loose)
    .padding(.bottom, Theme.Space.wide)
    .frame(maxHeight: .infinity, alignment: .top)
    .background(Theme.Surface.sunken)
  }

  /// Starts a new message.
  ///
  /// It used to be a dimmed `HStack` with no action at all — it read as a
  /// disabled menu item rather than the primary action in the window. Now it
  /// is a real button, filled rather than outlined so it reads as the one thing
  /// on this pane you do rather than navigate to.
  private var newMessageButton: some View {
    Button {
      store.startNewMessage()
    } label: {
      HStack(spacing: Theme.Space.base) {
        Image(systemName: "square.and.pencil")
          .font(.system(size: Theme.Size.smallIcon, weight: .medium))
        Text("New Message").font(Theme.Font.bodyEmphasis)
        Spacer(minLength: 0)
      }
      .foregroundStyle(.white)
      .padding(.horizontal, Theme.Space.loose)
      .frame(height: 34)
      .background(Theme.Accent.blue, in: .rect(cornerRadius: Theme.Radius.panel))
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .help("New message (⌘N)")
  }

  /// One row per connected mailbox, plus the way to add another.
  ///
  /// The colour dot is the point: once several accounts are unified into one
  /// inbox, colour is the only cheap way to tell whose mail a row belongs to —
  /// so the same value drives the stripe in the thread list.
  private var accountsSection: some View {
    VStack(alignment: .leading, spacing: Theme.Space.tight) {
      Text("ACCOUNTS")
        .font(Theme.Font.caption)
        .foregroundStyle(Theme.Ink.tertiary)
        .padding(.horizontal, Theme.Space.loose)

      ForEach(store.accounts) { account in
        AccountRowView(
          account: account,
          unread: store.unreadCount(forAccount: account.id),
          isSelected: store.selectedMailbox == .account(id: account.id),
          select: { store.selectedMailbox = .account(id: account.id) },
          save: { name, color in
            await store.updateAccount(account.id, displayName: name, color: color)
          }
        )
      }

      Button {
        connector.connect()
      } label: {
        HStack(spacing: Theme.Space.base) {
          Image(systemName: "plus.circle")
            .font(.system(size: Theme.Size.smallIcon))
          Text("Add Account").font(Theme.Font.body)
          Spacer()
        }
        .foregroundStyle(Theme.Ink.secondary)
        .padding(.horizontal, Theme.Space.loose)
        .frame(height: 30)
        .contentShape(.rect)
      }
      .buttonStyle(.plain)
      .disabled(connector.isRunning)
      .help("Authorize another Gmail mailbox")
    }
  }

  private func section(_ title: String, _ mailboxes: [Mailbox]) -> some View {
    VStack(alignment: .leading, spacing: Theme.Space.tight) {
      Text(title)
        .font(Theme.Font.caption)
        .foregroundStyle(Theme.Ink.tertiary)
        .padding(.horizontal, Theme.Space.loose)

      ForEach(mailboxes) { mailbox in
        SidebarRow(
          mailbox: mailbox,
          badge: store.badge(for: mailbox),
          isSelected: store.selectedMailbox == mailbox
        ) {
          store.selectedMailbox = mailbox
        }
      }
    }
  }
}

private struct SidebarRow: View {
  let mailbox: Mailbox
  let badge: Int?
  let isSelected: Bool
  let select: () -> Void

  var body: some View {
    Button(action: select) {
      HStack(spacing: Theme.Space.cosy) {
        Image(systemName: mailbox.systemImage)
          .font(.system(size: Theme.Size.icon - 2))
          .frame(width: Theme.Size.icon, height: Theme.Size.icon)
        Text(mailbox.title)
          .font(isSelected ? Theme.Font.bodyEmphasis : Theme.Font.body)
        Spacer(minLength: Theme.Space.base)
        if let badge {
          BadgePill(count: badge, isSelected: isSelected)
        }
      }
      .foregroundStyle(isSelected ? Theme.Ink.primary : Theme.Ink.secondary)
      .padding(.horizontal, Theme.Space.loose)
      .frame(height: Theme.Size.rowHeight)
      .frame(maxWidth: .infinity)
      .background(
        isSelected ? Theme.Surface.control : .clear,
        in: .rect(cornerRadius: Theme.Radius.control)
      )
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
  }
}

/// The design gives the selected mailbox a solid grey pill and the rest a
/// translucent one, so the active count reads first.
private struct BadgePill: View {
  let count: Int
  let isSelected: Bool

  var body: some View {
    Text(count > 999 ? "999+" : "\(count)")
      .font(Theme.Font.micro)
      .foregroundStyle(isSelected ? Color.white : Theme.Ink.secondary)
      .padding(.horizontal, Theme.Space.snug)
      .padding(.vertical, Theme.Space.hair)
      .background(
        isSelected ? Theme.Accent.muted : Color.white.opacity(0.1),
        in: .rect(cornerRadius: Theme.Radius.badge)
      )
  }
}

// MARK: - Message list

private struct MessageListPane: View {
  @Bindable var store: MailStore
  /// Non-nil only when the sidebar is hidden, in which case this reveals it.
  var revealSidebar: (() -> Void)?

  var body: some View {
    VStack(spacing: 0) {
      toolbar
      Divider().overlay(Theme.Surface.border.opacity(0.5))
      list
    }
    .background(Theme.Surface.base)
  }

  private var toolbar: some View {
    VStack(spacing: Theme.Space.loose) {
      HStack(spacing: Theme.Space.snug) {
        if let revealSidebar {
          Button(action: revealSidebar) {
            Image(systemName: "sidebar.leading")
              .font(.system(size: Theme.Size.smallIcon))
              .foregroundStyle(Theme.Ink.secondary)
              .contentShape(.rect)
          }
          .buttonStyle(.plain)
          .help("Show mailboxes")
        }
        Image(systemName: "magnifyingglass")
          .font(.system(size: Theme.Size.smallIcon - 1))
          .foregroundStyle(Theme.Ink.secondary)
        TextField("Search \(store.selectedMailbox.title)", text: $store.searchText)
          .textFieldStyle(.plain)
          .font(Theme.Font.small)
        if !store.searchText.isEmpty {
          Button {
            store.searchText = ""
          } label: {
            Image(systemName: "xmark.circle.fill")
              .font(.system(size: Theme.Size.smallIcon - 2))
              .foregroundStyle(Theme.Ink.tertiary)
          }
          .buttonStyle(.plain)
        }
      }
      .padding(.horizontal, Theme.Space.base)
      .frame(height: 28)
      .background(Theme.Surface.sunken, in: .rect(cornerRadius: Theme.Radius.control))

      HStack {
        Text(countLabel)
          .font(store.hasMultipleSelected ? Theme.Font.caption : Theme.Font.caption)
          .fontWeight(store.hasMultipleSelected ? .semibold : .regular)
          .foregroundStyle(store.hasMultipleSelected ? Theme.Accent.blue
                                                     : Theme.Ink.secondary)
          .lineLimit(1)
        Spacer(minLength: Theme.Space.base)

        // The icon states what the press will DO, not what is currently true:
        // filled means "this will clear", empty means "this will select all".
        toolbarButton(
          store.selectAllWouldClear ? "checkmark.square.fill" : "checkmark.square",
          store.selectAllWouldClear ? "Deselect all" : "Select all (⌘A)",
          isEnabled: store.canSelectAll,
          tint: store.selectAllWouldClear ? Theme.Accent.blue : nil
        ) { store.toggleSelectAll() }
        toolbarButton("archivebox", "Archive",
                      isEnabled: store.hasSelection) {
          Task { await store.archiveSelection() }
        }
        toolbarButton("envelope.open", "Toggle read",
                      isEnabled: store.hasSelection) {
          Task { await store.markSelectionRead() }
        }
        toolbarButton("flag", "Flag", isEnabled: store.hasSelection) {
          Task { await store.toggleFlagOnSelection() }
        }
      }
    }
    .padding(Theme.Space.loose)
  }

  private var countLabel: String {
    if store.hasMultipleSelected {
      return "\(store.selectionCount) selected"
    }
    return store.threadsLoaded ? "\(store.threads.count) conversations" : "Loading…"
  }

  private var threadList: some View {
    // Bound to what is OPEN, not to what is ticked.
    //
    // This was a Set binding, which is what makes AppKit treat the list as
    // multi-select — and so every plain click wrote the row straight into the
    // ticked set. Splitting the two values in the store did not fix that on
    // its own, because the list was still writing to the wrong one: clicking a
    // message to read it kept arming the bulk actions.
    //
    // An optional binding is a single-selection list, which is what reading
    // mail actually is. Ticking is the checkbox's job, and only the checkbox's.
    // ⌘-click and shift-click go with the Set binding; they were selecting
    // rows for reading rather than for a bulk action, which is not what either
    // gesture is for here.
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
      .contextMenu { menu(for: thread) }
  }

  /// Two distinct states, not one.
  ///
  /// A row can be SELECTED (part of a bulk action) and separately FOCUSED (the
  /// one in the reading pane). With several selected there is no focused row,
  /// and the previous version only ever drew the focused one — so selecting
  /// two rows made the highlight vanish entirely.
  ///
  /// The listRowBackground also has to carry this itself: an opaque background
  /// masks List's own selection highlight, so nothing else is going to draw it.
  private func background(for thread: ThreadRow) -> Color {
    if thread.id == store.selectedThreadID { return Theme.Surface.selection }
    if store.selection.contains(thread.id) { return Theme.Surface.selection.opacity(0.55) }
    return Theme.Surface.base
  }

  @ViewBuilder
  private func menu(for thread: ThreadRow) -> some View {
    Button("Archive") { Task { await store.archiveSelectedAndAdvance() } }
    Button(thread.isUnread ? "Mark as Read" : "Mark as Unread") {
      Task { await store.toggleReadOnSelection() }
    }
    // `thread`, not the selection: this menu belongs to the row under the
    // pointer, and `toggleStarOnSelection` acts on whatever is OPEN — so
    // right-clicking any other row flagged the wrong conversation.
    Button(thread.isStarred ? "Remove Flag" : "Flag") {
      Task { await store.toggleStar(thread) }
    }
  }

  /// - Parameter isEnabled: Stated per button rather than shared.
  ///
  /// This used to be one rule for all of them — `selectedThread == nil` — which
  /// was wrong in two directions at once. It disabled Select All exactly when
  /// nothing was selected, which is the only time it is useful; and it disabled
  /// every bulk action once SEVERAL were selected, because `selectedThread` is
  /// deliberately nil in that case. Both were invisible while the app
  /// auto-selected a thread on launch.
  private func toolbarButton(
    _ symbol: String, _ help: String, isEnabled: Bool,
    tint: Color? = nil,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: Theme.Size.icon - 2))
        .foregroundStyle(isEnabled ? (tint ?? Theme.Ink.secondary)
                                   : Theme.Ink.tertiary.opacity(0.4))
        .padding(.horizontal, Theme.Space.base)
        .padding(.vertical, Theme.Space.snug)
        .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .disabled(!isEnabled)
    .help(help)
  }

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
  }
}

private struct ThreadListRow: View {
  let thread: ThreadRow
  /// The owning account's colour, or nil when only one account is connected.
  ///
  /// Nil is not the same as "no colour": with a single mailbox the stripe is
  /// pure noise, and every row carrying it would be a decoration that means
  /// nothing. It appears exactly when it starts carrying information.
  let accountTint: Color?
  let isSelected: Bool
  /// True once anything is selected.
  ///
  /// Once a selection exists, every checkbox stays visible — otherwise
  /// extending it means hunting for a control that only appears under the
  /// pointer, one row at a time.
  let isSelecting: Bool
  /// True for the one row showing in the reading pane.
  ///
  /// Distinct from `isSelected`, which is the checkbox. Reading a conversation
  /// does not tick it, so the row that is OPEN is the one whose flag is worth
  /// offering without being pointed at.
  let isOpen: Bool
  let toggle: () -> Void
  let flag: () -> Void

  @Environment(\.paneLayout) private var layout
  @State private var isHovering = false

  private var affordances: ThreadRowAffordances {
    ThreadRowAffordances(
      isHovering: isHovering,
      isOpen: isOpen,
      isChecked: isSelected,
      isSelecting: isSelecting,
      isFlagged: thread.isStarred
    )
  }

  var body: some View {
    HStack(spacing: 0) {
      // A 2pt edge stripe rather than another dot. The row already has an
      // unread dot and a flag; a third circle would compete with both, whereas
      // an edge marker reads as "which pile is this from" at a glance.
      Rectangle()
        .fill(accountTint ?? .clear)
        .frame(width: 2)
        .padding(.vertical, Theme.Space.tight)

      gutter

      rowContent
    }
    .onHover { isHovering = $0 }
  }

  /// The two controls that act on this row alone.
  ///
  /// Both slots are held open whether or not their control is showing, and
  /// only the opacity changes. Inserting them conditionally moved every row's
  /// text sideways as the pointer swept down the list — the unread dot in
  /// `rowContent` already avoids exactly this ("always occupying its slot so
  /// names stay aligned"), and with two controls the jump would have been
  /// ~50pt rather than ~28pt.
  private var gutter: some View {
    HStack(spacing: 0) {
      // Without it, multi-select is discoverable only by knowing to hold ⌘ —
      // which is a feature nobody finds.
      Button(action: toggle) {
        Image(systemName: affordances.checkboxSymbol)
          .font(.system(size: 13))
          .foregroundStyle(isSelected ? Theme.Accent.blue : Theme.Ink.tertiary)
          .frame(width: 20, height: 22)
          .contentShape(.rect)
      }
      .buttonStyle(.plain)
      .opacity(affordances.showsCheckbox ? 1 : 0)
      .allowsHitTesting(affordances.showsCheckbox)
      .accessibilityLabel(isSelected ? "Deselect conversation" : "Select conversation")

      // Flagging one conversation used to mean ticking it first, or opening
      // it and crossing to the reading pane's toolbar. Both are detours from
      // a list you are already pointing at.
      Button(action: flag) {
        Image(systemName: affordances.flagSymbol)
          .font(.system(size: Theme.Size.flagIcon))
          .foregroundStyle(thread.isStarred ? Theme.Accent.flag : Theme.Ink.tertiary)
          .frame(width: 18, height: 22)
          .contentShape(.rect)
      }
      .buttonStyle(.plain)
      .opacity(affordances.showsFlag ? 1 : 0)
      .allowsHitTesting(affordances.showsFlag)
      .accessibilityLabel(affordances.flagLabel)
      // S is named only on the open row, because that is the only row it
      // acts on — advertising it on every row would teach a shortcut that
      // flags a different conversation than the one being pointed at.
      .help(isOpen ? "\(affordances.flagLabel) (S)" : affordances.flagLabel)
    }
    .padding(.leading, Theme.Space.tight)
    .animation(Theme.Motion.quick, value: affordances)
  }

  private var rowContent: some View {
    VStack(alignment: .leading, spacing: Theme.Space.snug) {
      HStack(spacing: Theme.Space.base) {
        // 8pt unread dot, always occupying its slot so names stay aligned.
        Circle()
          .fill(thread.isUnread ? Theme.Accent.blue : .clear)
          .frame(width: Theme.Size.unreadDot, height: Theme.Size.unreadDot)

        Text(thread.displayName)
          .font(thread.isUnread ? Theme.Font.bodyStrong : Theme.Font.bodyEmphasis)
          .foregroundStyle(Theme.Ink.primary)
          .lineLimit(1)

        Spacer(minLength: Theme.Space.base)

        Text(thread.displayTime)
          .font(Theme.Font.caption)
          .fontWeight(.regular)
          .foregroundStyle(Theme.Ink.secondary)
          .monospacedDigit()
      }

      VStack(alignment: .leading, spacing: Theme.Space.hair) {
        Text(thread.subject)
          .font(thread.isUnread ? Theme.Font.smallEmphasis : Theme.Font.small)
          .foregroundStyle(Theme.Ink.primary)
          .lineLimit(1)
        Text(thread.snippet)
          .font(Theme.Font.small)
          .foregroundStyle(Theme.Ink.secondary)
          .lineLimit(layout.showsRowPreview ? 2 : 1)
      }
      .padding(.leading, Theme.Space.wide)
    }
    .padding(.leading, Theme.Space.tight)
    .padding(.trailing, Theme.Space.wide)
    .padding(.vertical, Theme.Space.loose)
  }
}

// MARK: - Status

private struct ConnectionIndicator: View {
  let state: ConnectionState
  var reconnect: (() -> Void)?

  var body: some View {
    HStack(spacing: Theme.Space.snug) {
      Circle()
        .fill(indicatorColor)
        .frame(width: Theme.Space.snug, height: Theme.Space.snug)
      Text(state.label)
        .font(Theme.Font.caption)
        .fontWeight(.regular)
        .foregroundStyle(Theme.Ink.tertiary)
    }
    .animation(Theme.Motion.quick, value: state)
    // Clickable in the two states Zero refuses to retry from. Automatic
    // recovery backs off to a minute; past that a person watching it should
    // not have to wait for the timer.
    .onTapGesture {
      if state == .error || state == .needsAuth { reconnect?() }
    }
    .help(state == .error || state == .needsAuth
          ? "Click to reconnect" : state.label)
  }

  private var indicatorColor: Color {
    switch state {
    case .connected: Theme.Accent.ok
    case .connecting: Theme.Accent.flag
    default: Theme.Accent.red
    }
  }
}


/// Reports what just happened, and offers to take it back.
///
/// Placed bottom-left, clear of the composer's corner. Deliberately transient:
/// it is a notice, not a dialog, and it must not require dismissing before the
/// mailbox can be used again — the whole point of fast triage is that nothing
/// interrupts it.
///
/// The offer outlives the notice. ⌘Z keeps working after the banner fades,
/// because letting the message expire is not the same as declining it.
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
        .buttonStyle(.plain)
        .font(Theme.Font.smallEmphasis)
        .foregroundStyle(Theme.Accent.blue)

      Button(action: dismiss) {
        Image(systemName: "xmark")
          .font(.system(size: 9, weight: .semibold))
          .foregroundStyle(Theme.Ink.tertiary)
          .contentShape(.rect)
      }
      .buttonStyle(.plain)
    }
    .padding(.horizontal, Theme.Space.wide)
    .frame(height: 36)
    .background(Theme.Surface.control, in: .capsule)
    .overlay { Capsule().strokeBorder(Theme.Surface.border, lineWidth: 1) }
    .shadow(color: .black.opacity(0.28), radius: 14, y: 5)
    .padding(Theme.Space.section)
    .transition(.move(edge: .bottom).combined(with: .opacity))
  }
}

/// The end of the loaded list, and the way past it.
///
/// Serves two purposes that used to have none. It TELLS you the list is not
/// the whole mailbox — previously it just ended, indistinguishable from having
/// reached the last conversation — and it gives an explicit way to continue
/// when the scroll trigger does not fire.
private struct LoadMoreRow: View {
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
            .foregroundStyle(Theme.Accent.blue)
            .padding(.horizontal, Theme.Space.wide)
            .padding(.vertical, Theme.Space.snug)
            .background(Theme.Accent.blue.opacity(0.12),
                        in: .rect(cornerRadius: Theme.Radius.control))
        }
        .buttonStyle(.plain)
        Text("\(loaded.formatted()) loaded")
          .font(Theme.Font.micro)
          .fontWeight(.regular)
          .foregroundStyle(Theme.Ink.tertiary)
      }
      Spacer()
    }
    .padding(.vertical, Theme.Space.loose)
  }
}
