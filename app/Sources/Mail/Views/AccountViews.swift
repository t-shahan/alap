import SwiftUI

/// One connected mailbox in the sidebar.
///
/// The colour dot carries real information rather than decoration. Once several
/// accounts are unified into one inbox, colour is the only cheap way to tell
/// whose mail a row belongs to — so the same value drives the stripe in the
/// thread list, and the two must never drift apart.
struct AccountRowView: View {
  let account: AccountRow
  let unread: Int
  let isSelected: Bool
  let select: () -> Void

  @State private var isHovering = false

  var body: some View {
    Button(action: select) {
      HStack(spacing: Theme.Space.base) {
        Circle()
          .fill(Color(hex: account.color) ?? Theme.Accent.muted)
          .frame(width: 8, height: 8)

        VStack(alignment: .leading, spacing: 0) {
          Text(account.shortName)
            .font(Theme.Font.body)
            .foregroundStyle(isSelected ? Theme.Ink.primary : Theme.Ink.secondary)
            .lineLimit(1)
        }

        Spacer(minLength: Theme.Space.base)

        if unread > 0 {
          Text("\(unread)")
            .font(Theme.Font.micro)
            .fontWeight(.medium)
            .foregroundStyle(Theme.Ink.secondary)
        }
      }
      .padding(.horizontal, Theme.Space.loose)
      .frame(height: 30)
      .background(
        isSelected ? Theme.Surface.selection
          : (isHovering ? Theme.Surface.control : .clear),
        in: .rect(cornerRadius: Theme.Radius.control)
      )
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .onHover { isHovering = $0 }
    .help(account.emailAddress)
  }
}

/// Progress for an in-flight connect.
///
/// Deliberately not dismissible while running. The engine holds a loopback
/// listener open waiting for Google's redirect, and closing this without
/// cancelling would leave that process running with nothing watching it.
struct ConnectAccountSheet: View {
  @Bindable var connector: AccountConnector

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Space.wide) {
      Text(title)
        .font(Theme.Font.title)
        .foregroundStyle(Theme.Ink.primary)

      detail

      HStack {
        Spacer()
        if connector.isRunning {
          Button("Cancel") { connector.cancel() }
        } else {
          Button("Done") { connector.dismiss() }
            .keyboardShortcut(.defaultAction)
        }
      }
    }
    .padding(Theme.Space.pane)
    .frame(width: 420)
    .background(Theme.Surface.raised)
  }

  private var title: String {
    switch connector.phase {
    case .idle, .authorizing: "Connect a mailbox"
    case .syncing: "Syncing"
    case .finished: "Mailbox connected"
    case .failed: "Could not connect"
    }
  }

  @ViewBuilder
  private var detail: some View {
    switch connector.phase {
    case .idle:
      EmptyView()

    case .authorizing:
      HStack(spacing: Theme.Space.loose) {
        ProgressView().controlSize(.small)
        Text("Waiting for authorization in your browser…")
          .font(Theme.Font.body)
          .foregroundStyle(Theme.Ink.secondary)
      }

    case .syncing(let email, let done, let total):
      VStack(alignment: .leading, spacing: Theme.Space.base) {
        Text(email).font(Theme.Font.bodyEmphasis).foregroundStyle(Theme.Ink.primary)
        // Determinate only once the total is known: Gmail reports it after the
        // first page, and a bar that jumps from nothing to 90% is worse than
        // one that admits it does not know yet.
        if total > 0 {
          ProgressView(value: Double(done), total: Double(total))
          Text("\(done.formatted()) of \(total.formatted()) messages")
            .font(Theme.Font.small)
            .foregroundStyle(Theme.Ink.tertiary)
        } else {
          ProgressView().progressViewStyle(.linear)
          Text("Reading your mailbox…")
            .font(Theme.Font.small)
            .foregroundStyle(Theme.Ink.tertiary)
        }
        Text("You can keep using the app while this finishes.")
          .font(Theme.Font.small)
          .foregroundStyle(Theme.Ink.tertiary)
      }

    case .finished(let email, let messages):
      VStack(alignment: .leading, spacing: Theme.Space.base) {
        Label(email, systemImage: "checkmark.circle.fill")
          .font(Theme.Font.bodyEmphasis)
          .foregroundStyle(Theme.Accent.blue)
        Text("\(messages.formatted()) messages synced.")
          .font(Theme.Font.body)
          .foregroundStyle(Theme.Ink.secondary)
      }

    case .failed(let message):
      VStack(alignment: .leading, spacing: Theme.Space.base) {
        Label("Connection failed", systemImage: "exclamationmark.triangle.fill")
          .font(Theme.Font.bodyEmphasis)
          .foregroundStyle(Theme.Accent.red)
        Text(message)
          .font(Theme.Font.small)
          .foregroundStyle(Theme.Ink.secondary)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}

extension Color {
  /// Parses `#rrggbb`, returning nil rather than a wrong colour.
  ///
  /// Account colours come from Postgres, so a malformed value must degrade to
  /// the muted default rather than silently rendering black on near-black.
  init?(hex: String) {
    var value = hex.trimmingCharacters(in: .whitespaces)
    if value.hasPrefix("#") { value.removeFirst() }
    guard value.count == 6, let rgb = UInt32(value, radix: 16) else { return nil }

    self.init(
      .sRGB,
      red: Double((rgb >> 16) & 0xFF) / 255,
      green: Double((rgb >> 8) & 0xFF) / 255,
      blue: Double(rgb & 0xFF) / 255
    )
  }
}

/// Cycles the appearance from the sidebar footer.
///
/// The menu command is the canonical control, but a setting nobody finds is a
/// setting nobody has. This sits beside the connection indicator — the corner
/// already reserved for status rather than content — and shows the icon of the
/// theme it will switch TO, so the affordance says what it does rather than
/// what is currently true.
struct ThemeSwitcher: View {
  @State private var themes = ThemeController.shared
  @State private var isHovering = false

  var body: some View {
    Button {
      withAnimation(Theme.Motion.standard) { themes.theme = next }
    } label: {
      Image(systemName: next.symbol)
        .font(.system(size: Theme.Size.smallIcon - 2))
        .foregroundStyle(isHovering ? Theme.Ink.secondary : Theme.Ink.tertiary)
        .frame(width: 22, height: 22)
        .background(
          isHovering ? Theme.Surface.control : .clear,
          in: .rect(cornerRadius: Theme.Radius.control)
        )
        .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .onHover { isHovering = $0 }
    .help("Switch to the \(next.title) appearance")
    .accessibilityLabel("Appearance: \(themes.theme.title)")
  }

  private var next: AppTheme {
    let all = AppTheme.allCases
    let index = all.firstIndex(of: themes.theme) ?? 0
    return all[(index + 1) % all.count]
  }
}
