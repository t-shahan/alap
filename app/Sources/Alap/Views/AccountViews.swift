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
  let save: (String?, String?) async -> Void

  @State private var isHovering = false
  @State private var isEditing = false

  var body: some View {
    Button(action: select) {
      HStack(spacing: Theme.Space.base) {
        // Colour AND an initial. Colour was the only channel separating one
        // account from another, here and on the thread stripe; a marker that
        // also carries a letter still works when the hue does not.
        AccountMarker(color: Color(hex: account.color) ?? Theme.Accent.muted,
                      initial: account.shortName.first.map { String($0).uppercased() } ?? "?")

        VStack(alignment: .leading, spacing: 0) {
          Text(account.shortName)
            .font(Theme.Font.body)
            .foregroundStyle(isSelected ? Theme.Ink.primary : Theme.Ink.secondary)
            .lineLimit(1)
        }

        Spacer(minLength: Theme.Space.base)

        // The ⋯ replaces the count on hover rather than sitting beside it.
        // A 220pt sidebar has no room for both, and an always-visible control
        // on every row is clutter in the one part of the app that should be
        // quietest.
        if isHovering || isEditing {
          Image(systemName: "ellipsis")
            .font(Theme.Icon.small)
            .foregroundStyle(Theme.Ink.secondary)
            .frame(width: 18, height: 18)
            .background(Theme.Surface.raised, in: .rect(cornerRadius: Theme.Radius.tight))
            .onTapGesture { isEditing = true }
            .help("Account settings")
            .accessibilityLabel("Account settings for \(account.emailAddress)")
        } else if unread > 0 {
          Text("\(unread)")
            .font(Theme.Font.micro)
            .fontWeight(.medium)
            .foregroundStyle(Theme.Ink.secondary)
            .monospacedDigit()
        }
      }
      .padding(.horizontal, Theme.Space.loose)
      // One height for every navigation row in this pane. Mailbox rows were
      // 32, account rows 30, add-account 30 — three values for the same kind
      // of thing, which is what stops a sidebar reading as a column.
      .frame(height: Theme.Size.rowHeight)
      .background(
        isSelected ? Theme.Surface.selection : .clear,
        in: .rect(cornerRadius: Theme.Radius.control)
      )
      .contentShape(.rect)
    }
    // Hover and pressed come from the shared style now, not from this view.
    .buttonStyle(.alap())
    .onHover { isHovering = $0 }
    .help(account.emailAddress)
    .popover(isPresented: $isEditing, arrowEdge: .trailing) {
      AccountSettingsPopover(account: account, save: save)
    }
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
          // Green, not blue. It is literally a success checkmark, and it was
          // rendered in the action colour — blue means unread or the primary
          // action in context, and this is neither.
          .foregroundStyle(Theme.Accent.ok)
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

  var body: some View {
    Button {
      // `fade`, permanently. A palette swap is a colour interpolation, and a
      // spring's overshoot would visibly sail past the destination palette and
      // come back. This must never acquire a spring by riding a
      // general-purpose token.
      withAnimation(Theme.Motion.fade) { themes.theme = next }
    } label: {
      Image(systemName: next.symbol)
        .font(Theme.Icon.small)
        .frame(width: 22, height: 22)
    }
    .buttonStyle(.alap())
    .help("Switch to the \(next.title) appearance")
    // Names the ACTION. It used to report the CURRENT theme while the button
    // switched to the next one, so the label contradicted the press.
    .accessibilityLabel("Switch to \(next.title) appearance")
  }

  private var next: AppTheme {
    let all = AppTheme.allCases
    let index = all.firstIndex(of: themes.theme) ?? 0
    return all[(index + 1) % all.count]
  }
}

/// The colours offered for an account.
///
/// Built on the same cool axis as the app icon rather than reusing the iOS
/// system palette, which was the previous default: those hues are tuned to sit
/// on white at full saturation and read as loud, plasticky dots against a navy
/// sidebar. These are desaturated and mid-lightness, so they stay legible on
/// all three themes without shouting on any of them.
///
/// Order matters — it is the assignment order for new accounts, so the first
/// two must be maximally distinguishable, including for the most common forms
/// of colour blindness. Teal and clay differ in both hue and warmth, so they
/// separate on lightness alone if hue perception fails.
enum AccountPalette {
  static let choices: [(name: String, hex: String)] = [
    ("Teal", "#4aa3a2"),
    ("Clay", "#c2705a"),
    ("Slate", "#5b7ba8"),
    ("Sage", "#7d9a6d"),
    ("Plum", "#8a6a9e"),
    ("Amber", "#c39a4e"),
    ("Rose", "#b5697f"),
    ("Steel", "#6f7d8c"),
  ]

  static func hex(at index: Int) -> String {
    choices[index % choices.count].hex
  }
}

/// Rename and recolour, in a popover from the account row's ⋯ button.
///
/// A popover rather than a settings window: it edits exactly two fields
/// belonging to the row it is anchored to, and a whole window for that would
/// put more chrome on screen than content.
struct AccountSettingsPopover: View {
  let account: AccountRow
  let save: (String?, String?) async -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var name: String
  @State private var color: String

  init(account: AccountRow, save: @escaping (String?, String?) async -> Void) {
    self.account = account
    self.save = save
    _name = State(initialValue: account.displayName == account.emailAddress
                  ? "" : account.displayName)
    _color = State(initialValue: account.color.lowercased())
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Space.wide) {
      VStack(alignment: .leading, spacing: Theme.Space.tight) {
        Text("DISPLAY NAME")
          .font(Theme.Font.caption)
          .foregroundStyle(Theme.Ink.tertiary)
        // The address is the placeholder rather than the value, so leaving it
        // blank keeps the current fallback instead of pinning the address in
        // as a literal name you would then have to delete.
        TextField(account.emailAddress, text: $name)
          .textFieldStyle(.plain)
          .font(Theme.Font.body)
          .foregroundStyle(Theme.Ink.primary)
          .padding(.horizontal, Theme.Space.base)
          .frame(height: 28)
          .background(Theme.Surface.control, in: .rect(cornerRadius: Theme.Radius.control))
          .onSubmit { commit() }
      }

      VStack(alignment: .leading, spacing: Theme.Space.base) {
        Text("COLOUR")
          .font(Theme.Font.caption)
          .foregroundStyle(Theme.Ink.tertiary)
        LazyVGrid(
          columns: Array(repeating: GridItem(.fixed(28), spacing: Theme.Space.base), count: 4),
          spacing: Theme.Space.base
        ) {
          ForEach(AccountPalette.choices, id: \.hex) { choice in
            swatch(choice.hex, name: choice.name)
          }
        }
      }

      Text(account.emailAddress)
        .font(Theme.Font.micro)
        .fontWeight(.regular)
        .foregroundStyle(Theme.Ink.tertiary)
        .lineLimit(1)

      HStack {
        Spacer()
        Button("Done") { commit() }
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(Theme.Space.wide)
    .frame(width: 260)
  }

  private func swatch(_ hex: String, name: String) -> some View {
    let isSelected = hex.lowercased() == color.lowercased()
    return Button {
      color = hex
      // Applied immediately rather than on Done: recolouring is reversible and
      // the point is to see it against the real list while choosing.
      Task { await save(nil, hex) }
    } label: {
      Circle()
        .fill(Color(hex: hex) ?? Theme.Accent.muted)
        .frame(width: 24, height: 24)
        .overlay {
          Circle().strokeBorder(Theme.Ink.primary.opacity(isSelected ? 0.9 : 0),
                                lineWidth: 2)
        }
        .padding(2)
    }
    .buttonStyle(.alap())
    .help(name)
    .accessibilityLabel(name)
  }

  private func commit() {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    Task { await save(trimmed.isEmpty ? nil : trimmed, color) }
    dismiss()
  }
}

/// An account's marker: its colour, and its initial.
///
/// Colour was the only channel telling one account from another — the sidebar
/// dot, the composer's From dot and the thread stripe were all hue and nothing
/// else. `AccountPalette` already does unusually well here by separating its
/// first two choices on lightness as well as hue, and this finishes the job:
/// the letter survives any colour vision at all.
struct AccountMarker: View {
  let color: Color
  let initial: String
  var diameter: CGFloat = 14

  var body: some View {
    Text(initial)
      .font(.system(size: diameter * 0.62, weight: .bold))
      // White on the account colour rather than an ink level: these hues are
      // mid-lightness by design, so a palette-following ink would invert
      // legibility between themes while the swatch stays put.
      .foregroundStyle(.white)
      .frame(width: diameter, height: diameter)
      .background(color, in: .circle)
      .accessibilityHidden(true)
  }
}
