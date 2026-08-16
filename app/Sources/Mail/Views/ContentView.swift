import SwiftUI

/// Three-pane mail layout.
///
/// Visual direction is restrained-editorial rather than dense-utility: the
/// problem statement is visual clutter, so hierarchy comes from type scale and
/// whitespace instead of borders and chrome. Unread is signalled by weight and
/// a single accent dot, not by a filled row background.
struct ContentView: View {
  @State private var store = MailStore()

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
    } detail: {
      ReadingPane(thread: store.selectedThread)
    }
    .task { store.start() }
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
          .badge(store.labels.filter { $0.remoteId == "INBOX" }.reduce(0) { $0 + $1.unreadCount })
          .tag(String?.none)
      }

      ForEach(store.accounts) { account in
        Section {
          ForEach(store.labels.filter { $0.accountId == account.id }) { label in
            Label(label.name, systemImage: label.systemImage)
              // Reads the trigger-maintained column — not a live COUNT.
              .badge(label.unreadCount)
              .tag(String?.some(label.id))
          }
        } header: {
          HStack(spacing: 6) {
            Circle()
              .fill(Color(hex: account.color))
              .frame(width: 7, height: 7)
            Text(account.emailAddress)
              .font(.caption)
              .foregroundStyle(.secondary)
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
          "Nothing here",
          systemImage: "checkmark.circle",
          description: Text("This mailbox is empty.")
        )
      } else {
        List(store.threads, selection: $store.selectedThread) { thread in
          ThreadRowView(thread: thread)
            .tag(thread)
            .listRowInsets(EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14))
            .swipeActions(edge: .trailing) {
              Button("Archive", systemImage: "archivebox") {
                Task { await store.archive(thread) }
              }
              .tint(.accentColor)
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
      }
    }
    .navigationTitle(store.selectedLabel?.name ?? "All Inboxes")
  }
}

private struct ThreadRowView: View {
  let thread: ThreadRow

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      // Unread marker. A 6pt dot carries the signal so the row itself can stay
      // visually quiet — the anti-clutter goal in miniature.
      Circle()
        .fill(thread.isUnread ? Color.accentColor : .clear)
        .frame(width: 6, height: 6)
        .padding(.top, 5)

      VStack(alignment: .leading, spacing: 3) {
        HStack(alignment: .firstTextBaseline) {
          Text(thread.displayName)
            .font(.system(size: 13, weight: thread.isUnread ? .semibold : .regular))
            .lineLimit(1)

          Spacer(minLength: 8)

          if thread.isStarred {
            Image(systemName: "star.fill")
              .font(.system(size: 9))
              .foregroundStyle(.orange)
          }
          Text(RelativeTime.short(thread.lastMessageDate))
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }

        Text(thread.subject)
          .font(.system(size: 12.5, weight: thread.isUnread ? .medium : .regular))
          .lineLimit(1)

        Text(thread.snippet)
          .font(.system(size: 11.5))
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
    }
  }
}

// MARK: - Reading pane

private struct ReadingPane: View {
  let thread: ThreadRow?

  var body: some View {
    if let thread {
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          Text(thread.subject)
            // Deliberate scale jump from the 13pt list — hierarchy through
            // contrast rather than through rules and boxes.
            .font(.system(size: 24, weight: .semibold))
            .textSelection(.enabled)

          HStack(spacing: 8) {
            Text(thread.displayName).font(.system(size: 13, weight: .medium))
            Text(thread.participants.first?.email ?? "")
              .font(.system(size: 12))
              .foregroundStyle(.secondary)
            Spacer()
            Text(thread.lastMessageDate.formatted(date: .abbreviated, time: .shortened))
              .font(.system(size: 12))
              .foregroundStyle(.secondary)
          }

          Divider()

          // Bodies live in a separate table and are pulled by the detail
          // query. Wiring that is the next step.
          Text(thread.snippet)
            .font(.system(size: 13.5))
            .lineSpacing(4)
            .textSelection(.enabled)

          Spacer()
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    } else {
      ContentUnavailableView("No message selected", systemImage: "envelope")
    }
  }
}

// MARK: - Status

private struct ConnectionIndicator: View {
  let state: ConnectionState

  var body: some View {
    HStack(spacing: 5) {
      Circle()
        .fill(state == .connected ? Color.green : state.acceptsWrites ? .yellow : .red)
        .frame(width: 6, height: 6)
      Text(state.label)
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }
    .help("Zero sync status")
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
