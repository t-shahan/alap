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

  var body: some View {
    HStack(spacing: 0) {
      Sidebar(store: store)
        .frame(width: Theme.Size.sidebar)

      MessageListPane(store: store)
        .frame(width: Theme.Size.list)
        .triageShortcuts(store: store, listFocused: $listFocused)

      ReadingPane(store: store)
        .frame(maxWidth: .infinity)
    }
    .background(Theme.Surface.base)
    .task { store.start() }
    // `.task` runs before the window becomes key, so assigning focus there is
    // silently dropped and shortcuts do nothing until the user clicks a row.
    .defaultFocus($listFocused, true)
    .background(BridgeHost(bridge: store.bridge).frame(width: 0, height: 0))
  }
}

// MARK: - Sidebar

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
        ConnectionIndicator(state: store.bridge.connection)
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

  /// Compose is not implemented — the engine's `send` outbox op returns 501 —
  /// so this is visibly disabled rather than silently doing nothing.
  private var newMessageButton: some View {
    HStack(spacing: Theme.Space.base) {
      Image(systemName: "square.and.pencil")
        .font(.system(size: Theme.Size.smallIcon))
      Text("New Message").font(Theme.Font.bodyEmphasis)
    }
    .foregroundStyle(Theme.Accent.blue)
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, Theme.Space.loose)
    .frame(height: 36)
    .background(Theme.Surface.control, in: .rect(cornerRadius: Theme.Radius.panel))
    .overlay(
      RoundedRectangle(cornerRadius: Theme.Radius.panel)
        .stroke(Theme.Surface.border, lineWidth: 1)
    )
    .opacity(0.45)
    .help("Composing is not implemented yet")
  }

  /// One row per connected mailbox, plus the way to add another.
  ///
  /// The colour dot is the whole point: once two accounts are unified into one
  /// inbox, the only cheap way to tell whose mail you are looking at is a
  /// consistent colour, and it has to be the SAME colour here and in the list.
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
          isSelected: store.selectedMailbox == .account(id: account.id)
        ) {
          store.selectedMailbox = .account(id: account.id)
        }
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
        Text(store.threadsLoaded ? "\(store.threads.count) conversations" : "Loading…")
          .font(Theme.Font.caption)
          .fontWeight(.regular)
          .foregroundStyle(Theme.Ink.secondary)
        Spacer()
        // These act on the current selection. The design shows them operating
        // on checkbox multi-selection, which the app does not support.
        toolbarButton("archivebox", "Archive") {
          Task { await store.archiveSelectedAndAdvance() }
        }
        toolbarButton("envelope.open", "Toggle read") {
          Task { await store.toggleReadOnSelection() }
        }
        toolbarButton("flag", "Flag") {
          Task { await store.toggleStarOnSelection() }
        }
      }
    }
    .padding(Theme.Space.loose)
  }

  private var threadList: some View {
    List(store.threads, selection: $store.selectedThreadID) { thread in
      row(for: thread)
    }
    .listStyle(.plain)
    .scrollContentBackground(.hidden)
    .background(Theme.Surface.base)
  }

  /// Extracted from `threadList` because the combined modifier chain exceeded
  /// the type-checker's budget.
  private func row(for thread: ThreadRow) -> some View {
    ThreadListRow(thread: thread, accountTint: store.tint(forAccount: thread.accountId))
      .tag(thread.id)
      .listRowInsets(EdgeInsets())
      .listRowBackground(background(for: thread))
      .contextMenu { menu(for: thread) }
  }

  private func background(for thread: ThreadRow) -> Color {
    thread.id == store.selectedThreadID ? Theme.Surface.selection : Theme.Surface.base
  }

  @ViewBuilder
  private func menu(for thread: ThreadRow) -> some View {
    Button("Archive") { Task { await store.archiveSelectedAndAdvance() } }
    Button(thread.isUnread ? "Mark as Read" : "Mark as Unread") {
      Task { await store.toggleReadOnSelection() }
    }
    Button(thread.isStarred ? "Remove Flag" : "Flag") {
      Task { await store.toggleStarOnSelection() }
    }
  }

  private func toolbarButton(
    _ symbol: String, _ help: String, action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: Theme.Size.icon - 2))
        .foregroundStyle(Theme.Ink.secondary)
        .padding(.horizontal, Theme.Space.base)
        .padding(.vertical, Theme.Space.snug)
        .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .disabled(store.selectedThread == nil)
    .help(help)
  }

  private var list: some View {
    Group {
      if store.threads.isEmpty && store.threadsLoaded {
        ContentUnavailableView(
          store.isSearching ? "No matches" : "Nothing here",
          systemImage: store.isSearching ? "magnifyingglass" : "checkmark.circle",
          description: Text(store.isSearching
            ? "Nothing in the local index matches that."
            : "This mailbox is empty.")
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

  var body: some View {
    HStack(spacing: 0) {
      // A 2pt edge stripe rather than another dot. The row already has an
      // unread dot and a flag; a third circle would compete with both, whereas
      // an edge marker reads as "which pile is this from" at a glance.
      Rectangle()
        .fill(accountTint ?? .clear)
        .frame(width: 2)
        .padding(.vertical, Theme.Space.tight)

      rowContent
    }
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
          .lineLimit(2)
      }
      .padding(.leading, Theme.Space.wide)

      if thread.isStarred {
        Image(systemName: "flag.fill")
          .font(.system(size: Theme.Size.flagIcon - 2))
          .foregroundStyle(Theme.Accent.flag)
          .padding(.leading, Theme.Space.wide)
      }
    }
    .padding(.horizontal, Theme.Space.wide)
    .padding(.vertical, Theme.Space.loose)
  }
}

// MARK: - Status

private struct ConnectionIndicator: View {
  let state: ConnectionState

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
  }

  private var indicatorColor: Color {
    switch state {
    case .connected: Theme.Accent.ok
    case .connecting: Theme.Accent.flag
    default: Theme.Accent.red
    }
  }
}
