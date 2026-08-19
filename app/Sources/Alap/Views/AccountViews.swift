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
  /// Signs the account out. Nil while a disconnect is already running, which
  /// is what stops a second one being started against the same mailbox.
  var disconnect: (() -> Void)?

  @State private var isHovering = false
  @State private var isEditing = false

  /// The row and its ⋯ are SIBLINGS, not nested.
  ///
  /// The ⋯ used to be an `Image` with an `.onTapGesture` inside the row's own
  /// `Button`, and it did nothing at all: the button owns the whole hit area,
  /// so the tap never reached the gesture. It was also hover-gated, so there
  /// was no keyboard or VoiceOver path to it either — which made renaming,
  /// recolouring and (once it existed) signing out unreachable by any means
  /// except a mouse that happened to land on eighteen points of glyph.
  ///
  /// A `ZStack` puts them side by side. Two controls need two buttons.
  var body: some View {
    ZStack(alignment: .trailing) {
      rowButton
      trailingControl
    }
    .onHover { isHovering = $0 }
    .popover(isPresented: $isEditing, arrowEdge: .trailing) {
      AccountSettingsPopover(account: account, save: save, disconnect: disconnect)
    }
  }

  private var rowButton: some View {
    Button(action: select) {
      HStack(spacing: Theme.Space.base) {
        // Colour AND an initial. Colour was the only channel separating one
        // account from another, here and on the thread stripe; a marker that
        // also carries a letter still works when the hue does not.
        AccountMarker(color: AccountPalette.tint(for: account.color) ?? Theme.Accent.muted,
                      initial: account.shortName.first.map { String($0).uppercased() } ?? "?")

        VStack(alignment: .leading, spacing: 0) {
          Text(account.shortName)
            .font(Theme.Font.body)
            .foregroundStyle(isSelected ? Theme.Ink.primary : Theme.Ink.secondary)
            .lineLimit(1)
        }

        Spacer(minLength: Theme.Space.base)

        // Room reserved for the ⋯ that sits above this row, so the count does
        // not shift sideways when the pointer arrives.
        Text(unread > 0 ? "\(unread)" : "")
          .font(Theme.Font.micro)
          .fontWeight(.medium)
          .foregroundStyle(Theme.Ink.secondary)
          .monospacedDigit()
          .opacity(showsOptions ? 0 : 1)
          .frame(minWidth: 24, alignment: .trailing)
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
    .help(account.emailAddress)
  }

  /// The ⋯, as a real button.
  ///
  /// Shown on hover AND on the selected row, and always present to the
  /// accessibility tree.
  ///
  /// Hover alone is the normal macOS sidebar idiom, but it is a poor way to
  /// find something you do not already know is there — and signing out is
  /// exactly the thing a reader goes looking for without knowing where it
  /// lives. The selected row carries it permanently at no clutter cost, since
  /// there is only ever one.
  ///
  /// `.accessibilityHidden(false)` plus a zero opacity rather than an `if` is
  /// what keeps it focusable while invisible, so there is a keyboard path even
  /// when there is no pointer.
  private var showsOptions: Bool { isHovering || isEditing || isSelected }

  private var trailingControl: some View {
    Button { isEditing = true } label: {
      Image(systemName: "ellipsis")
        .font(Theme.Icon.small)
        .frame(width: 24, height: 24)
    }
    .buttonStyle(.alap(.secondary, radius: Theme.Radius.tight))
    .opacity(showsOptions ? 1 : 0)
    .padding(.trailing, Theme.Space.base)
    .help("Account options")
    .accessibilityLabel("Options for \(account.emailAddress)")
    .accessibilityHidden(false)
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

/// Chooses the appearance from the sidebar footer.
///
/// The menu command is the canonical control, but a setting nobody finds is a
/// setting nobody has. This sits beside the connection indicator — the corner
/// already reserved for status rather than content.
///
/// ## Why this is a chooser rather than a cycle
///
/// It used to advance one step through `allCases` per press, and showed the
/// icon of the theme it would switch TO so the affordance said what it did
/// rather than what was currently true. That reasoning was right for three
/// themes and stops being right as soon as there are more: reaching the one
/// you want costs up to `allCases.count - 1` presses, each of which repaints
/// the entire window, and a control whose icon changes on every press never
/// settles into something you can aim at. Cycling is a fine gesture for a
/// binary and a poor one for a list.
///
/// So the button now OPENS the list, which inverts the icon rule with it: an
/// affordance that reveals a chooser is not claiming to perform a switch, so
/// showing the current theme is the honest label rather than the contradictory
/// one. The old comment's warning still applies in its new form — the button
/// says what it does, it is just doing something else now.
///
/// A `Button` and a popover rather than a `Menu`, for the reason `FromField`
/// documents at length: macOS does not honour a custom `label:` on a menu
/// style, and this label is ours.
struct ThemeSwitcher: View {
  @State private var themes = ThemeController.shared
  @State private var isPicking = false

  var body: some View {
    Button { isPicking = true } label: {
      Image(systemName: themes.theme.symbol)
        .font(Theme.Icon.small)
        .frame(width: Theme.Size.hitTarget, height: Theme.Size.hitTarget)
    }
    .buttonStyle(.alap())
    .help("Change the appearance")
    // Reports the state AND names the action, because the button now does the
    // second while displaying the first — "Appearance: Signature" alone would
    // read as a label rather than as something pressable.
    .accessibilityLabel("Appearance: \(themes.theme.title)")
    .accessibilityHint("Choose an appearance")
    // `.trailing`, not `.top`: this sits at the bottom of a 220pt sidebar, and
    // a list wider than the sidebar opening upward would hang off the window.
    .popover(isPresented: $isPicking, arrowEdge: .trailing) { themeList }
  }

  private var themeList: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(AppTheme.allCases) { theme in
        Button {
          // `fade`, permanently. A palette swap is a colour interpolation, and
          // a spring's overshoot would visibly sail past the destination
          // palette and come back. This must never acquire a spring by riding
          // a general-purpose token.
          withAnimation(Theme.Motion.fade) { themes.theme = theme }
          isPicking = false
        } label: {
          row(for: theme)
        }
        .buttonStyle(.alap())
        // The checkmark is decorative here — this trait is what actually
        // reaches VoiceOver, and `.opacity(0)` does not remove a view from the
        // accessibility tree, so an unmarked row would still announce one.
        .accessibilityAddTraits(theme == themes.theme ? [.isSelected] : [])
      }
    }
    .padding(.vertical, Theme.Space.base)
    .frame(width: 240)
  }

  /// Symbol, name and the one-line description of what the palette is.
  ///
  /// `subtitle` has existed on `AppTheme` since the themes did and had no
  /// reader until now. It earns its place here: with more than a couple of
  /// appearances the titles alone stop distinguishing them, and "Signature"
  /// tells you nothing that "Cool navy, matched to the app icon" does.
  private func row(for theme: AppTheme) -> some View {
    HStack(spacing: Theme.Space.base) {
      Image(systemName: theme.symbol)
        .font(Theme.Icon.small)
        .foregroundStyle(Theme.Ink.secondary)
        .frame(width: 16)

      VStack(alignment: .leading, spacing: 0) {
        Text(theme.title)
          .font(Theme.Font.body)
          .foregroundStyle(Theme.Ink.primary)
        Text(theme.subtitle)
          .font(Theme.Font.micro)
          .fontWeight(.regular)
          .foregroundStyle(Theme.Ink.tertiary)
          .lineLimit(1)
      }

      Spacer(minLength: Theme.Space.wide)

      // Held in the layout at zero opacity rather than removed, so selecting a
      // different theme does not reflow every row beside it.
      Image(systemName: "checkmark")
        .font(Theme.Icon.micro)
        .foregroundStyle(Theme.Accent.blueText)
        .opacity(theme == themes.theme ? 1 : 0)
        .accessibilityHidden(true)
    }
    .padding(.horizontal, Theme.Space.loose)
    .frame(height: 40)
  }
}

/// The colours offered for an account.
///
/// Built on the same cool axis as the app icon rather than reusing the iOS
/// system palette, which was the previous default: those hues are tuned to sit
/// on white at full saturation and read as loud, plasticky dots against a navy
/// sidebar. These are desaturated and mid-lightness, so they stay legible on
/// the dark themes without shouting on any of them.
///
/// Order matters — it is the assignment order for new accounts, so the first
/// two must be maximally distinguishable, including for the most common forms
/// of colour blindness. Teal and clay differ in both hue and warmth, so they
/// separate on lightness alone if hue perception fails.
///
/// ## One stored vocabulary, two render sets
///
/// "Mid-lightness so they work everywhere" was true of the dark palettes and
/// false of the light one, and nothing measured it. Against `light`'s surfaces
/// six of these eight fell below the 3:1 graphical floor — Amber at **1.83:1**
/// on `control`, Teal at 2.09 — because a mid-lightness dot on a near-white
/// ground has nowhere to get contrast from. `accountMarkersAreLegible` could
/// not catch it by construction: it checks the INITIAL against its own fill,
/// which is a closed system that never asks whether the fill can be seen.
///
/// The marker survives that failure — its letter stays readable, so the account
/// is still identifiable. **The thread-list rail does not.** It is two points
/// of pure colour at 0.35 opacity with no letter and no shape to fall back on,
/// and it is the app's only answer to "whose mailbox did this arrive in". A
/// rail below 3:1 is not a quiet ownership cue; it is an absent one.
///
/// So `choices` is now the STORED vocabulary and nothing else: it is what the
/// picker saves, what Postgres holds, and the identity a name attaches to.
/// `darkChoices` and `lightChoices` are what actually get drawn, chosen per
/// polarity and index-aligned with it. Keeping storage separate from rendering
/// is what lets a contrast fix be a lookup instead of a migration — and the
/// dark set needed one too: the deeper `signature` and the new `umber` put
/// Slate at 2.96:1 and Plum at 2.84:1, which the new sweep caught immediately.
///
/// ## Why they are not simply "the same colours, darker"
///
/// The first attempt at the light set normalised all eight to one luminance. It
/// cleared the floor and destroyed the property the ORDER exists to guarantee:
/// at equal lightness they separate on hue ALONE, which is precisely the
/// channel that fails for the reader that ordering is written for. Both sets
/// preserve real lightness spacing, and Teal against Clay — the pair the order
/// promises — is 1.22 on dark and 1.27 on light.
///
/// Slate and Steel sit closer than any other pair and always have, in every
/// set. That is not what this palette promises and it is not worth distorting
/// three other colours to chase; the guarantee is about the first two assigned.
enum AccountPalette {
  /// The stored vocabulary. Never rendered directly — see `resolve`.
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

  /// Rendered on dark appearances. Worst case 3.16:1 (Plum), swept across every
  /// surface of `signature`, `dark` and `umber`.
  ///
  /// Five are the stored values unchanged. Slate, Plum and Steel are lifted by
  /// 2-7% — the least that clears the floor, because these are colours people
  /// have already assigned to mailboxes and recognise.
  static let darkChoices: [(name: String, hex: String)] = [
    ("Teal", "#4aa3a2"),
    ("Clay", "#c2705a"),
    ("Slate", "#5f80af"),
    ("Sage", "#7d9a6d"),
    ("Plum", "#9371a8"),
    ("Amber", "#c39a4e"),
    ("Rose", "#b5697f"),
    ("Steel", "#72808f"),
  ]

  /// Rendered on light appearances. Worst case 3.37:1 (Amber).
  ///
  /// The darkest light surface any of these must clear is `noon`'s `selection`,
  /// which is what sets the ceiling on how light they may be.
  static let lightChoices: [(name: String, hex: String)] = [
    ("Teal", "#285858"),
    ("Clay", "#5f372c"),
    ("Slate", "#263446"),
    ("Sage", "#42523a"),
    ("Plum", "#362a3e"),
    ("Amber", "#6f572c"),
    ("Rose", "#54303b"),
    ("Steel", "#30363c"),
  ]

  static func hex(at index: Int) -> String {
    choices[index % choices.count].hex
  }

  /// The stored colour, mapped to the set the appearance can actually carry.
  ///
  /// Falls through unchanged for anything not in `choices` — an account
  /// recoloured by hand, or by some future picker — because a value this cannot
  /// recognise is one it has no business rewriting.
  static func resolve(_ hex: String, isDark: Bool) -> String {
    guard let index = choices.firstIndex(where: {
      $0.hex.caseInsensitiveCompare(hex) == .orderedSame
    }) else { return hex }
    return (isDark ? darkChoices : lightChoices)[index].hex
  }

  /// `resolve` against the appearance currently selected.
  ///
  /// Reading `ThemeController.shared.theme` here is what makes account colour
  /// track a theme switch: `@Observable` registers the access inside whichever
  /// view body is evaluating, so the dot and the rail repaint with everything
  /// else. A cached `Color` computed once at load would not.
  @MainActor
  static func tint(for hex: String) -> Color? {
    Color(hex: resolve(hex, isDark: ThemeController.shared.theme.isDark))
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
  /// Nil when there is nothing to disconnect to — a single connected mailbox
  /// still offers it, because signing out of the only account is a legitimate
  /// thing to want and refusing it would be the app deciding for you.
  var disconnect: (() -> Void)?

  @Environment(\.dismiss) private var dismiss
  @State private var name: String
  @State private var color: String
  @State private var isConfirmingDisconnect = false

  init(account: AccountRow,
       save: @escaping (String?, String?) async -> Void,
       disconnect: (() -> Void)? = nil) {
    self.account = account
    self.save = save
    self.disconnect = disconnect
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

      if disconnect != nil {
        Divider().overlay(Theme.Surface.border)
        disconnectRow
      }

      HStack {
        Spacer()
        Button("Done") { commit() }
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(Theme.Space.wide)
    .frame(width: 280)
  }

  /// Sign out.
  ///
  /// Phrased as what it costs rather than as a neutral toggle, which is the
  /// same discipline the remote-image banner uses: this deletes the local copy
  /// of the mailbox, and saying "Disconnect" alone would let someone find that
  /// out afterwards.
  ///
  /// Destructive and irreversible, so it is confirmed — and the confirmation
  /// names the account, because a popover anchored to the wrong row is exactly
  /// the mistake this guards against.
  private var disconnectRow: some View {
    VStack(alignment: .leading, spacing: Theme.Space.tight) {
      Button {
        isConfirmingDisconnect = true
      } label: {
        HStack(spacing: Theme.Space.base) {
          Image(systemName: "rectangle.portrait.and.arrow.right")
            .font(Theme.Icon.small)
          Text("Disconnect account").font(Theme.Font.body)
          Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Space.base)
        .frame(height: 28)
      }
      .buttonStyle(.alap(tint: Theme.Accent.red))

      Text("Removes the saved credential and deletes this mailbox from this "
           + "Mac. Your mail stays in Gmail.")
        .font(Theme.Font.micro)
        .fontWeight(.regular)
        .foregroundStyle(Theme.Ink.tertiary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, Theme.Space.base)
    }
    .confirmationDialog(
      "Disconnect \(account.emailAddress)?",
      isPresented: $isConfirmingDisconnect,
      titleVisibility: .visible
    ) {
      Button("Disconnect", role: .destructive) {
        disconnect?()
        dismiss()
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("The saved credential is removed and every message, thread and "
           + "attachment for this account is deleted from this Mac. Nothing is "
           + "deleted from Gmail, and you can reconnect at any time.\n\n"
           + "This does not revoke access at Google — do that in your Google "
           + "Account settings if you want the grant withdrawn too.")
    }
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
        // Previews what the appearance will actually draw, not the stored
        // value. `color` above keeps the canonical hex either way — the swatch
        // grid is `choices`, so what is saved is theme-independent and only the
        // rendering follows the palette.
        .fill(AccountPalette.tint(for: hex) ?? Theme.Accent.muted)
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
      // Black or white, whichever the fill can actually carry.
      //
      // This was flatly `.white`, and `AccountPalette`'s eight hues are
      // mid-lightness by design, so seven of the eight failed 4.5:1 against a
      // white letter — Amber at 2.61:1, Teal at 2.98:1. Those two are the
      // FIRST TWO assigned, which the palette's own comment picks for being
      // "maximally distinguishable" for colour-blind readers. So the letter
      // that exists as the fallback when hue perception fails was itself
      // unreadable exactly where it mattered most.
      //
      // Black passes on seven of eight and white on the remaining one, so
      // choosing per-fill clears the floor everywhere without touching the
      // palette. Not a palette-following ink: the swatch does not change with
      // the theme, so an ink that did would invert legibility for free.
      .foregroundStyle(Self.readableInk(on: color))
      .frame(width: diameter, height: diameter)
      .background(color, in: .circle)
      .accessibilityHidden(true)
  }

  /// The higher-contrast of black and white against a fill.
  ///
  /// WCAG relative luminance, the same arithmetic `ThemeTests` and
  /// `tools/palette-audit/contrast.py` use. The 0.179 threshold is where the
  /// two ratios cross.
  static func readableInk(on fill: Color) -> Color {
    guard let rgb = NSColor(fill).usingColorSpace(.sRGB) else { return .white }
    func channel(_ value: CGFloat) -> Double {
      let v = Double(value)
      return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }
    let luminance = 0.2126 * channel(rgb.redComponent)
      + 0.7152 * channel(rgb.greenComponent)
      + 0.0722 * channel(rgb.blueComponent)
    return luminance > 0.179 ? .black : .white
  }
}
