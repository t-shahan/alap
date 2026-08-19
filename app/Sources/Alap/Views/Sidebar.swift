import SwiftUI

/// Navigation, and the instrument's own reading.
struct Sidebar: View {
  @Bindable var store: MailStore
  var daemon: SyncDaemon?
  @State private var connector = AccountConnector()

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Space.wide) {
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

      InstrumentRail(store: store, daemon: daemon)
        .padding(.horizontal, Theme.Space.loose)
    }
    .sheet(isPresented: .constant(connector.phase != .idle)) {
      ConnectAccountSheet(connector: connector)
    }
    .padding(.horizontal, Theme.Space.base)
    .padding(.top, Theme.Space.loose)
    .padding(.bottom, Theme.Space.wide)
    .frame(maxHeight: .infinity, alignment: .top)
    .background(Theme.Surface.sunken)
    .reservingTrafficLights()
    .paneRule()
  }

  /// Starts a new message.
  ///
  /// It used to be a dimmed `HStack` with no action at all — it read as a
  /// disabled menu item rather than the primary action in the window. Now it
  /// is a real button, filled rather than outlined so it reads as the one thing
  /// on this pane you do rather than navigate to. It is also, at every width
  /// where this pane exists, the app's ONLY compose affordance.
  private var newMessageButton: some View {
    Button {
      store.startNewMessage()
    } label: {
      HStack(spacing: Theme.Space.base) {
        Image(systemName: "square.and.pencil").font(Theme.Icon.medium)
        Text("New Message").font(Theme.Font.bodyEmphasis)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, Theme.Space.loose)
      .frame(height: 34)
    }
    .buttonStyle(.alap(.primary, radius: Theme.Radius.panel))
    .help("New message (⌘N)")
  }

  /// One row per connected mailbox, plus the way to add another.
  ///
  /// The colour marker is the point: once several accounts are unified into one
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
          Image(systemName: "plus.circle").font(Theme.Icon.medium)
          Text("Add Account").font(Theme.Font.body)
          Spacer()
        }
        .padding(.horizontal, Theme.Space.loose)
        .frame(height: Theme.Size.rowHeight)
      }
      .buttonStyle(.alap())
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
      HStack(spacing: Theme.Space.base) {
        Image(systemName: mailbox.systemImage)
          .font(Theme.Icon.medium)
          .frame(width: Theme.Space.wide, height: Theme.Space.wide)
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
    }
    // This is the most-clicked control in the app and it used to give nothing
    // back at all — no hover, no press, nothing. It is the single clearest
    // reason the app read less finished than its palette deserved.
    .buttonStyle(.alap(isOn: isSelected))
  }
}

/// The design gives the selected mailbox a solid grey pill and the rest a
/// translucent one, so the active count reads first.
private struct BadgePill: View {
  let count: Int
  let isSelected: Bool

  var body: some View {
    Text(display)
      .font(Theme.Font.micro)
      .foregroundStyle(isSelected ? Color.white : Theme.Ink.secondary)
      // Tabular, and ticking. A proportional count jiggles width as it changes,
      // which reads as decoration; one that ticks in place reads as an
      // instrument.
      .monospacedDigit()
      .contentTransition(.numericText(value: Double(count)))
      .animation(Theme.Motion.fade, value: count)
      .padding(.horizontal, Theme.Space.base)
      .padding(.vertical, Theme.Space.hair)
      .background(
        // `mutedFill` rather than a hardcoded `Color.white.opacity(0.1)`,
        // which was simply wrong in the light theme — white on near-white.
        isSelected ? Theme.Accent.muted : Theme.Accent.mutedFill,
        in: .capsule
      )
      .accessibilityLabel("\(count) unread")
  }

  /// Real counts, abbreviated where they stop being readable.
  ///
  /// Both Inbox and Unread used to cap at `999+`, and for a real mailbox they
  /// are frequently the same number — two badges conveying nothing. `12.4k` is
  /// a count; `999+` is a shrug.
  private var display: String { count.abbreviatedCount(above: 1000) }
}
