import SwiftUI

/// Three-pane mail layout.
///
/// Every size, colour and spacing value comes from `Theme` — see that file for
/// the visual direction and the reasoning behind each token. No literals here.
struct ContentView: View {
  /// Owned by MailApp so the menu commands act on the same store.
  @Bindable var store: MailStore

  /// Focus lives here so the thread list can claim it on launch — otherwise
  /// bare-letter shortcuts do nothing until the user clicks a row.
  @FocusState private var listFocused: Bool

  /// A three-column NavigationSplitView hides the sidebar by default on macOS.
  /// The sidebar carries the unread badges, so it is pinned open.
  @State private var columns: NavigationSplitViewVisibility = .all

  var body: some View {
    NavigationSplitView(columnVisibility: $columns) {
      Sidebar(store: store)
        .navigationSplitViewColumnWidth(min: 200, ideal: 232, max: 300)
    } content: {
      ThreadList(store: store)
        .navigationSplitViewColumnWidth(min: 320, ideal: 380, max: 520)
        .triageShortcuts(store: store, listFocused: $listFocused)
    } detail: {
      ReadingPane(store: store)
    }
    .task { store.start() }
    // `.task` runs before the window becomes key, so assigning focus there is
    // silently dropped and shortcuts do nothing until the user clicks a row.
    // defaultFocus applies once the scene is ready.
    .defaultFocus($listFocused, true)
    // Hosts the headless web view so WebKit actually schedules it. Zero size,
    // so it costs nothing visually.
    .background(BridgeHost(bridge: store.bridge).frame(width: 0, height: 0))
    .toolbar {
      ToolbarItem(placement: .status) {
        ConnectionIndicator(state: store.bridge.connection)
      }
    }
  }
}

// MARK: - Sidebar

private struct Sidebar: View {
  @Bindable var store: MailStore

  var body: some View {
    List(selection: Binding(
      get: { store.selectedLabel?.id },
      set: { id in store.selectedLabel = store.labels.first { $0.id == id } }
    )) {
      Section {
        Label("All Inboxes", systemImage: "tray.2")
          .font(Theme.Font.body)
          .badge(store.labels.filter { $0.remoteId == "INBOX" }.reduce(0) { $0 + $1.unreadCount })
          .tag(String?.none)
      }

      ForEach(store.accounts) { account in
        Section {
          ForEach(store.labels.filter { $0.accountId == account.id }) { label in
            Label(label.name, systemImage: label.systemImage)
              .font(Theme.Font.body)
              // Reads the trigger-maintained column — not a live COUNT.
              .badge(label.unreadCount)
              .tag(String?.some(label.id))
          }
        } header: {
          HStack(spacing: Theme.Space.snug - 2) {
            Circle()
              .fill(Color(hex: account.color))
              .frame(width: 7, height: 7)
            Text(account.emailAddress)
              .font(Theme.Font.caption)
              .foregroundStyle(Theme.Palette.secondaryText)
          }
        }
      }
    }
    .listStyle(.sidebar)
  }
}

// MARK: - Thread list

private struct ThreadList: View {
  @Bindable var store: MailStore

  var body: some View {
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
        // Selection binds to the ID, not the row. See MailStore.selectedThreadID.
        List(store.threads, selection: $store.selectedThreadID) { thread in
          ThreadRowView(thread: thread)
            .tag(thread.id)
            .listRowInsets(EdgeInsets(
              top: Theme.Space.snug + 2, leading: Theme.Space.loose - 2,
              bottom: Theme.Space.snug + 2, trailing: Theme.Space.loose - 2))
            .swipeActions(edge: .trailing) {
              Button("Archive", systemImage: "archivebox") {
                Task { await store.archive(thread) }
              }
              .tint(Theme.Palette.accent)
            }
            .contextMenu {
              Button("Archive") { Task { await store.archive(thread) } }
              Button(thread.isUnread ? "Mark as Read" : "Mark as Unread") {
                Task { await store.setRead(thread, isRead: thread.isUnread) }
              }
              Button(thread.isStarred ? "Unstar" : "Star") {
                Task { await store.toggleStar(thread) }
              }
            }
        }
        .listStyle(.inset)
        // No list-wide animation. Animating on `store.threads` re-diffed and
        // re-animated all 100 rows whenever any field changed, which is every
        // time a thread is read, starred or archived.
      }
    }
    .navigationTitle(store.isSearching ? "Search" : (store.selectedLabel?.name ?? "All Inboxes"))
    .searchable(text: $store.searchText, placement: .toolbar, prompt: "Search mail")
  }
}

private struct ThreadRowView: View {
  let thread: ThreadRow

  var body: some View {
    HStack(alignment: .top, spacing: Theme.Space.snug + 2) {
      // A 6pt dot carries the unread signal so the row itself stays visually
      // quiet — the anti-clutter goal in miniature.
      Circle()
        .fill(thread.isUnread ? Theme.Palette.accent : .clear)
        .frame(width: Theme.unreadDot, height: Theme.unreadDot)
        .padding(.top, 5)

      VStack(alignment: .leading, spacing: Theme.Space.tight - 1) {
        HStack(alignment: .firstTextBaseline) {
          Text(thread.displayName)
            .font(thread.isUnread ? Theme.Font.bodyEmphasis : Theme.Font.body)
            .lineLimit(1)

          Spacer(minLength: Theme.Space.snug)

          if thread.isStarred {
            Image(systemName: "star.fill")
              .font(.system(size: 9))
              .foregroundStyle(Theme.Palette.star)
          }
          Text(thread.displayTime)
            .font(Theme.Font.caption)
            .foregroundStyle(Theme.Palette.secondaryText)
            .monospacedDigit()
        }

        Text(thread.subject)
          .font(Theme.Font.small)
          .fontWeight(thread.isUnread ? .medium : .regular)
          .lineLimit(1)

        Text(thread.snippet)
          .font(Theme.Font.small)
          .foregroundStyle(Theme.Palette.secondaryText)
          .lineLimit(2)
      }
    }
  }
}

// MARK: - Reading pane

private struct ReadingPane: View {
  @Bindable var store: MailStore
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    if let thread = store.selectedThread {
      VStack(alignment: .leading, spacing: 0) {
        // The subject stays in SwiftUI rather than moving into the document,
        // so it keeps the app's type scale and does not scroll away with the
        // body.
        Text(store.detail?.subject ?? thread.subject)
          .font(Theme.Font.title)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, Theme.Space.reading)
          .padding(.top, Theme.Space.reading)
          .padding(.bottom, Theme.Space.loose)

        if let detail = store.detail, !detail.messages.isEmpty {
          MessageWebView(
            html: MessageDocument.build(
              for: detail.messages,
              isDark: colorScheme == .dark
            )
          )
          .padding(.horizontal, Theme.Space.reading)
        } else if store.detailLoaded {
          Text("This thread has no messages.")
            .font(Theme.Font.body)
            .foregroundStyle(Theme.Palette.secondaryText)
            .padding(.horizontal, Theme.Space.reading)
          Spacer()
        } else {
          // Reads hit the local cache first, so this is usually a single frame.
          HStack(spacing: Theme.Space.snug) {
            ProgressView().controlSize(.small)
            Text("Loading…")
              .font(Theme.Font.small)
              .foregroundStyle(Theme.Palette.secondaryText)
          }
          .padding(.horizontal, Theme.Space.reading)
          Spacer()
        }
      }
      .id(thread.id)  // rebuild when switching threads, resetting scroll
    } else {
      ContentUnavailableView("No message selected", systemImage: "envelope")
    }
  }
}

private struct MessageView: View {
  let message: MessageRow

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Space.base) {
      header

      Divider().overlay(Theme.Palette.divider)

      if message.isBodyMissing {
        Label("Body not downloaded yet", systemImage: "arrow.down.circle")
          .font(Theme.Font.small)
          .foregroundStyle(Theme.Palette.secondaryText)
      } else {
        Text(message.displayBody)
          // Plain-text mail carries its own wrapping, so a monospaced face
          // keeps signatures and quoted blocks aligned. Converted HTML has no
          // such structure and reads better proportionally.
          .font(message.isDowngradedFromHTML ? Theme.Font.reading : Theme.Font.monospacedBody)
          .lineSpacing(4)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)

        if message.isTruncated {
          Text("Message truncated for display")
            .font(Theme.Font.caption)
            .foregroundStyle(Theme.Palette.secondaryText)
        }
      }

      if !message.attachments.isEmpty {
        attachments
      }
    }
  }

  private var header: some View {
    HStack(alignment: .firstTextBaseline, spacing: Theme.Space.snug) {
      Text(message.displayName).font(Theme.Font.bodyEmphasis)
      Text(message.fromEmail)
        .font(Theme.Font.small)
        .foregroundStyle(Theme.Palette.secondaryText)
        .lineLimit(1)

      Spacer(minLength: Theme.Space.base)

      if message.isStarred {
        Image(systemName: "star.fill")
          .font(.system(size: 10))
          .foregroundStyle(Theme.Palette.star)
      }
      Text(message.sentDate.formatted(date: .abbreviated, time: .shortened))
        .font(Theme.Font.caption)
        .foregroundStyle(Theme.Palette.secondaryText)
        .monospacedDigit()
    }
  }

  private var attachments: some View {
    VStack(alignment: .leading, spacing: Theme.Space.tight) {
      ForEach(message.attachments.filter { !$0.isInline }) { attachment in
        HStack(spacing: Theme.Space.snug) {
          Image(systemName: "paperclip")
            .font(.system(size: 10))
            .foregroundStyle(Theme.Palette.secondaryText)
          Text(attachment.filename).font(Theme.Font.small)
          Text(attachment.displaySize)
            .font(Theme.Font.caption)
            .foregroundStyle(Theme.Palette.secondaryText)
        }
      }
    }
    .padding(.top, Theme.Space.tight)
  }
}

// MARK: - Status

private struct ConnectionIndicator: View {
  let state: ConnectionState

  var body: some View {
    HStack(spacing: Theme.Space.tight + 1) {
      Circle()
        .fill(indicatorColor)
        .frame(width: Theme.unreadDot, height: Theme.unreadDot)
      Text(state.label)
        .font(Theme.Font.caption)
        .foregroundStyle(Theme.Palette.secondaryText)
    }
    .help("Zero sync status")
    .animation(Theme.Motion.quick, value: state)
  }

  private var indicatorColor: Color {
    switch state {
    case .connected: Theme.Palette.ok
    case .connecting: Theme.Palette.star
    default: Theme.Palette.alert
    }
  }
}

// MARK: - Helpers

extension Color {
  /// Parses the `#RRGGBB` values stored on `account.color`.
  init(hex: String) {
    let cleaned = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
    let value = UInt32(cleaned, radix: 16) ?? 0x6E7B8B
    self.init(
      .sRGB,
      red: Double((value >> 16) & 0xFF) / 255,
      green: Double((value >> 8) & 0xFF) / 255,
      blue: Double(value & 0xFF) / 255
    )
  }
}
