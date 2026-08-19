import SwiftUI

/// The composer, floating over the bottom-right of the window.
///
/// ## Why an overlay rather than a sheet
///
/// A modal sheet takes the whole window and blocks the mailbox behind it.
/// Writing a message almost always involves looking something up — an address,
/// a figure, what the other person actually said — and a modal turns that into
/// cancel-look-reopen-retype. Anchoring bottom-right keeps the list and the
/// reading pane live and clickable while the draft stays put.
///
/// It replaces a reply pane that was pinned to the reading pane permanently,
/// costing ~194pt of body space on every message whether or not anyone was
/// replying.
struct ComposerPanel: View {
  @Bindable var store: MailStore
  @Bindable var composer: Composer

  @FocusState private var focus: ComposerPanelField?

  var body: some View {
    VStack(spacing: 0) {
      header

      if composer.isOpen {
        Divider().overlay(Theme.Surface.border)
        fields
        Divider().overlay(Theme.Surface.border.opacity(0.6))
        footer
        // Fields fade rather than clipping in as the height springs open.
        .transition(.opacity)
      }
    }
    .frame(width: 520)
    .background(Theme.Surface.raised, in: .rect(cornerRadius: Theme.Radius.panel))
    .overlay {
      RoundedRectangle(cornerRadius: Theme.Radius.panel)
        .strokeBorder(Theme.Surface.border, lineWidth: 1)
    }
    // Depth, not decoration: this floats above scrolling content, and without
    // a shadow the boundary between panel and list disappears wherever their
    // surfaces happen to match. Palette-aware, because pure black at 34% is
    // right on a near-black ground and reads as grey smudge on white.
    .elevation(Theme.Elevation.float)
    .padding(Theme.Space.pane)
    // ONE owner for the minimise/expand spring. It used to be `withAnimation`
    // at each of the three toggles, which is the shape that leaves the fourth
    // one popping. The panel's ENTRANCE is owned further out still, by the
    // overlay in `ContentView` that inserts it — so every path that opens the
    // composer animates, not just the ones somebody remembered to wrap.
    .animation(Theme.Motion.panel, value: composer.isOpen)
  }

  // MARK: - Header

  private var header: some View {
    HStack(spacing: Theme.Space.base) {
      Text(composer.title)
        .font(Theme.Font.bodyEmphasis)
        .foregroundStyle(Theme.Ink.primary)
        .lineLimit(1)

      Spacer(minLength: Theme.Space.base)

      statusLabel

      headerButton(composer.isOpen ? "minus" : "chevron.up",
                   help: composer.isOpen ? "Minimise" : "Expand") {
        composer.isOpen ? composer.minimize() : composer.expand()
      }
      headerButton("xmark", help: "Discard") { composer.close() }
    }
    .padding(.horizontal, Theme.Space.loose)
    .frame(height: 40)
    .background(Theme.Surface.sunken)
    .contentShape(.rect)
    // The whole bar toggles, as it does in every mail client that has one.
    .onTapGesture { composer.isOpen ? composer.minimize() : composer.expand() }
  }

  /// editing → sending → queued reads as a sequence rather than three
  /// unrelated flickers, so `.transition` plus one animated owner keyed on the
  /// case.
  @ViewBuilder
  private var statusLabel: some View {
    Group {
      switch composer.status {
      case .editing:
        EmptyView()
      case .sending:
        ProgressView().controlSize(.small)
      case .queued:
        // Green, not blue. Queued IS "safely on its way", and green already
        // means that here — blue was one of the six meanings §7.4 cut.
        Label("Queued", systemImage: "checkmark.circle.fill")
          .font(Theme.Font.micro)
          .foregroundStyle(Theme.Accent.ok)
      case .failed(let message):
        Label("Failed", systemImage: "exclamationmark.triangle.fill")
          .font(Theme.Font.micro)
          .foregroundStyle(Theme.Accent.red)
          .help(message)
      }
    }
    .transition(.opacity)
    .animation(Theme.Motion.fade, value: composer.status)
  }

  private func headerButton(_ symbol: String, help: String,
                            action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(Theme.Icon.small)
        .frame(width: 20, height: 20)
    }
    .buttonStyle(.alap())
    .help(help)
    .accessibilityLabel(help)
  }

  // MARK: - Fields

  private var fields: some View {
    VStack(spacing: 0) {
      // Only when there is a choice to make. A "From" row above a single
      // account is a control that can only ever do nothing, and it pushes the
      // fields that matter further down a panel with limited height.
      if store.accounts.count > 1 {
        FromField(accounts: store.accounts, selected: $composer.accountId)
        Divider().overlay(Theme.Surface.border.opacity(0.4))
      }

      RecipientField(
        label: "To", text: $composer.to, field: .to, focus: $focus,
        suggestions: { store.addressSuggestions(matching: $0) }
      )
      if composer.showsCc {
        Divider().overlay(Theme.Surface.border.opacity(0.4))
        RecipientField(
          label: "Cc", text: $composer.cc, field: .cc, focus: $focus,
          suggestions: { store.addressSuggestions(matching: $0) }
        )
        .transition(.opacity)
      }

      Divider().overlay(Theme.Surface.border.opacity(0.4))
      HStack(spacing: Theme.Space.base) {
        Text("Subject")
          .font(Theme.Font.small)
          .foregroundStyle(Theme.Ink.tertiary)
          .frame(width: 52, alignment: .leading)
        TextField("", text: $composer.subject)
          .textFieldStyle(.plain)
          .font(Theme.Font.body)
          .foregroundStyle(Theme.Ink.primary)
          .focused($focus, equals: .subject)
      }
      .padding(.horizontal, Theme.Space.loose)
      .frame(height: 34)

      Divider().overlay(Theme.Surface.border.opacity(0.4))
      TextEditor(text: $composer.body)
        .font(Theme.Font.reading)
        .scrollContentBackground(.hidden)
        .focused($focus, equals: .body)
        .frame(height: 220)
        .padding(.horizontal, Theme.Space.base)
        .padding(.vertical, Theme.Space.tight)
        .overlay(alignment: .topLeading) {
          if composer.body.isEmpty {
            Text("Write your message…")
              .font(Theme.Font.reading)
              .foregroundStyle(Theme.Ink.tertiary)
              // Offset from the editor's own inset by exactly one step, which
              // is what puts the placeholder on the caret rather than near it.
              .padding(.horizontal, Theme.Space.loose)
              .padding(.vertical, Theme.Space.base)
              .allowsHitTesting(false)
          }
        }

      // The quote is shown but not editable, and collapsed by default. It is
      // context rather than something being written — and keeping it out of the
      // text field means it cannot be half-deleted, which is how quoted replies
      // usually end up mangled.
      if !composer.quotedBody.isEmpty {
        Divider().overlay(Theme.Surface.border.opacity(0.4))
        quote
      }
    }
    .background(Theme.Surface.raised)
    .animation(Theme.Motion.standard, value: composer.showsCc)
  }

  private var quote: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button {
        // `standard`, not `quick`: this moves layout — the panel grows by up
        // to 120pt — and a reveal that changes height wants the same spring as
        // a row insertion.
        composer.showsQuote.toggle()
      } label: {
        HStack(spacing: Theme.Space.base) {
          Image(systemName: composer.showsQuote ? "chevron.down" : "chevron.right")
            .font(Theme.Icon.micro)
          Text(composer.showsQuote ? "Hide quoted text" : "Show quoted text")
            .font(Theme.Font.small)
          Spacer()
        }
        .padding(.horizontal, Theme.Space.loose)
        .frame(height: 28)
      }
      .buttonStyle(.alap())

      if composer.showsQuote {
        ScrollView {
          Text(composer.quotedBody)
            .font(Theme.Font.small)
            .fontWeight(.regular)
            .foregroundStyle(Theme.Ink.secondary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.Space.loose)
            .padding(.bottom, Theme.Space.base)
        }
        .frame(maxHeight: 120)
        .transition(.opacity)
      }
    }
    .background(Theme.Surface.sunken.opacity(0.5))
    .animation(Theme.Motion.standard, value: composer.showsQuote)
  }

  // MARK: - Footer

  private var footer: some View {
    HStack(spacing: Theme.Space.loose) {
      Button(action: sendNow) {
        Text("Send")
          .font(Theme.Font.bodyEmphasis)
          .padding(.horizontal, Theme.Space.pane)
          .padding(.vertical, Theme.Space.base)
      }
      // Disabled used to be a muted fill at 45% opacity, which put the label at
      // well under 2:1. The style's disabled treatment keeps the control's box
      // and drops it to `Ink.disabled`, which is inert but still legible.
      .buttonStyle(.alap(.primary))
      .disabled(!composer.canSend)
      .help("Send (⌘↩)")

      if !composer.showsCc {
        Button("Cc") {
          composer.showsCc = true
          focus = .cc
        }
        .buttonStyle(.alap())
        .font(Theme.Font.small)
      }

      Spacer()

      // Attachments are absent rather than dimmed: the engine composes
      // single-part text/plain, so there is nothing behind the button yet.
      Text("⌘↩ to send")
        .font(Theme.Font.micro)
        .fontWeight(.regular)
        .foregroundStyle(Theme.Ink.tertiary)
    }
    .padding(.horizontal, Theme.Space.loose)
    .frame(height: 48)
    .background(Theme.Surface.sunken)
    // A plain Return belongs to the body field. The shortcut sits on a hidden
    // button so the responder chain routes it, rather than the editor having to
    // intercept every keystroke.
    .background {
      Button("Send", action: sendNow)
        .keyboardShortcut(.return, modifiers: .command)
        .opacity(0)
        .frame(width: 0, height: 0)
        .disabled(!composer.canSend)
    }
  }

  private func sendNow() {
    guard composer.canSend else { return }
    Task { await store.sendComposed() }
  }
}

/// A recipient row with inline suggestions.
private struct RecipientField: View {
  let label: String
  @Binding var text: String
  let field: ComposerPanelField
  var focus: FocusState<ComposerPanelField?>.Binding
  let suggestions: (String) -> [Participant]

  @State private var showsSuggestions = false

  /// Suggestions come from threads already in memory, so this list costs a
  /// filter rather than a query — and appears without a perceptible delay.
  private var matches: [Participant] {
    showsSuggestions ? suggestions(currentFragment) : []
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: Theme.Space.base) {
        Text(label)
          .font(Theme.Font.small)
          .foregroundStyle(Theme.Ink.tertiary)
          .frame(width: 52, alignment: .leading)
        TextField("", text: $text)
          .textFieldStyle(.plain)
          .font(Theme.Font.body)
          .foregroundStyle(Theme.Ink.primary)
          .focused(focus, equals: field)
          .onChange(of: text) { _, _ in showsSuggestions = true }
      }
      .padding(.horizontal, Theme.Space.loose)
      .frame(height: 34)

      if !matches.isEmpty {
        SuggestionList(matches: matches, complete: complete)
          .transition(.opacity)
      }
    }
    // The list used to appear and vanish abruptly *while changing the panel's
    // height*. `quick`, and only on the container: suggestions chase
    // keystrokes, so the CONTENT still updates instantly and only the reveal
    // softens. Anything slower here would put motion between typing and
    // seeing, which is lag rather than polish.
    .animation(Theme.Motion.quick, value: matches.count)
  }

  /// The address currently being typed — everything after the last separator.
  private var currentFragment: String {
    text.split(whereSeparator: { $0 == "," || $0 == ";" }).last.map(String.init) ?? text
  }

  private func complete(with email: String) {
    var parts = text.split(separator: ",").map {
      $0.trimmingCharacters(in: .whitespaces)
    }
    if !parts.isEmpty { parts.removeLast() }
    parts.append(email)
    text = parts.joined(separator: ", ") + ", "
    showsSuggestions = false
  }
}

private struct SuggestionList: View {
  let matches: [Participant]
  let complete: (String) -> Void

  var body: some View {
    VStack(spacing: 0) {
      ForEach(matches, id: \.email) { participant in
        Button {
          complete(participant.email)
        } label: {
          HStack(spacing: Theme.Space.base) {
            Text(participant.name.isEmpty ? participant.email : participant.name)
              .font(Theme.Font.small)
              .foregroundStyle(Theme.Ink.primary)
            if !participant.name.isEmpty {
              Text(participant.email)
                .font(Theme.Font.micro)
                .fontWeight(.regular)
                .foregroundStyle(Theme.Ink.tertiary)
            }
            Spacer()
          }
          .padding(.horizontal, Theme.Space.loose)
          .frame(height: 26)
        }
        .buttonStyle(.alap(radius: Theme.Radius.tight))
      }
    }
    .padding(.bottom, Theme.Space.tight)
    .background(Theme.Surface.control)
  }
}

/// Focus targets, lifted out so `RecipientField` can name the type.
enum ComposerPanelField: Hashable { case to, cc, subject, body }

/// The resting state of the composer: a small button in the corner it opens
/// from.
///
/// Occupying the same spot the panel expands from is what makes the panel feel
/// like it came from somewhere rather than appearing over everything — the same
/// reason Gmail puts it there. That claim used to be true only in this comment:
/// nothing animated the swap, so the button vanished and a panel appeared. The
/// overlay in `ContentView` now owns both halves of the transition, and this is
/// genuinely the collapsed endpoint of it.
struct ComposeLaunchButton: View {
  let action: () -> Void
  @State private var isHovering = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: Theme.Space.base) {
        Image(systemName: "square.and.pencil")
          .font(Theme.Icon.medium)
        if isHovering {
          // Fades in as the capsule stretches. Inserting the label without a
          // transition made it pop in and clip mid-word during the width
          // change, because the text arrived at full strength inside a box
          // still growing to hold it.
          Text("Compose")
            .font(Theme.Font.bodyEmphasis)
            .fixedSize()
            .transition(.opacity)
        }
      }
      .foregroundStyle(.white)
      .padding(.horizontal, isHovering ? Theme.Space.wide : Theme.Space.loose)
      .frame(height: 44)
      .background(Theme.Accent.blue, in: .capsule)
      .elevation(Theme.Elevation.lifted)
      .contentShape(.capsule)
    }
    .buttonStyle(.plain)
    .onHover { hovering in
      withAnimation(Theme.Motion.quick) { isHovering = hovering }
    }
    .padding(Theme.Space.pane)
    .help("New message (⌘N)")
    .accessibilityLabel("New message")
  }
}

/// Which address the message is sent from.
///
/// Present only when more than one account is connected. Sending from the
/// wrong identity is a mistake visible only to the recipient, and only after
/// the message has gone — so with several mailboxes this is worth a row, and
/// with one it is worth nothing.
///
/// The marker carries the same colour as the account's sidebar entry and the
/// stripe on its threads. That is the whole point of having chosen those
/// colours: the identity is recognisable here without reading the address.
///
/// ## Why this is a Button and a popover rather than a Menu
///
/// It was a `Menu` with `.menuStyle(.borderlessButton)` and a custom `label:`
/// closure, and macOS does not honour one: the style extracts the label,
/// applies its own alignment and draws its own indicator. So the `Circle()`,
/// the `Spacer` and the custom chevron were all discarded or reflowed — the
/// row's label sat ~240pt right of where `To` and `Subject` sit, the chevron
/// rendered *before* the address instead of after it, and **the account colour
/// did not render at all**, which defeated the entire documented purpose of the
/// control.
///
/// Driving the popup by hand is the only way the label is really ours.
private struct FromField: View {
  let accounts: [AccountRow]
  @Binding var selected: String?

  @State private var isPicking = false

  private var current: AccountRow? {
    accounts.first { $0.id == selected } ?? accounts.first
  }

  var body: some View {
    HStack(spacing: Theme.Space.base) {
      Text("From")
        .font(Theme.Font.small)
        .foregroundStyle(Theme.Ink.tertiary)
        .frame(width: 52, alignment: .leading)

      Button { isPicking = true } label: {
        HStack(spacing: Theme.Space.base) {
          marker(for: current)
          Text(current?.emailAddress ?? "No account")
            .font(Theme.Font.body)
            .foregroundStyle(Theme.Ink.primary)
            .lineLimit(1)
          Image(systemName: "chevron.down")
            .font(Theme.Icon.micro)
            .foregroundStyle(Theme.Ink.tertiary)
          Spacer(minLength: 0)
        }
      }
      .buttonStyle(.alap())
      .accessibilityLabel("From: \(current?.emailAddress ?? "no account")")
      .popover(isPresented: $isPicking, arrowEdge: .bottom) { accountList }
    }
    .padding(.horizontal, Theme.Space.loose)
    .frame(height: 34)
  }

  private var accountList: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(accounts) { account in
        Button {
          selected = account.id
          isPicking = false
        } label: {
          HStack(spacing: Theme.Space.base) {
            marker(for: account)
            Text(account.emailAddress)
              .font(Theme.Font.body)
              .foregroundStyle(Theme.Ink.primary)
            Spacer(minLength: Theme.Space.wide)
            Image(systemName: "checkmark")
              .font(Theme.Icon.micro)
              .foregroundStyle(Theme.Accent.blueText)
              .opacity(account.id == current?.id ? 1 : 0)
          }
          .padding(.horizontal, Theme.Space.loose)
          .frame(height: 30)
        }
        .buttonStyle(.alap(radius: Theme.Radius.tight))
      }
    }
    .padding(.vertical, Theme.Space.base)
    .frame(minWidth: 260)
  }

  @ViewBuilder
  private func marker(for account: AccountRow?) -> some View {
    if let account {
      AccountMarker(
        color: Color(hex: account.color) ?? Theme.Accent.muted,
        initial: account.shortName.first.map { String($0).uppercased() } ?? "?",
        diameter: 12
      )
    } else {
      Circle().fill(Theme.Accent.muted).frame(width: 12, height: 12)
    }
  }
}
