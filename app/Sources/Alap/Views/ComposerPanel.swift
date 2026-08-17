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
    // surfaces happen to match.
    .shadow(color: .black.opacity(0.34), radius: 22, y: 10)
    .padding(Theme.Space.section)
    .transition(.move(edge: .bottom).combined(with: .opacity))
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
        withAnimation(Theme.Motion.standard) {
          composer.isOpen ? composer.minimize() : composer.expand()
        }
      }
      headerButton("xmark", help: "Discard") {
        withAnimation(Theme.Motion.standard) { composer.close() }
      }
    }
    .padding(.horizontal, Theme.Space.loose)
    .frame(height: 40)
    .background(Theme.Surface.sunken)
    .contentShape(.rect)
    // The whole bar toggles, as it does in every mail client that has one.
    .onTapGesture {
      withAnimation(Theme.Motion.standard) {
        composer.isOpen ? composer.minimize() : composer.expand()
      }
    }
  }

  @ViewBuilder
  private var statusLabel: some View {
    switch composer.status {
    case .editing:
      EmptyView()
    case .sending:
      ProgressView().controlSize(.small)
    case .queued:
      Label("Queued", systemImage: "checkmark.circle.fill")
        .font(Theme.Font.micro)
        .foregroundStyle(Theme.Accent.blue)
    case .failed(let message):
      Label("Failed", systemImage: "exclamationmark.triangle.fill")
        .font(Theme.Font.micro)
        .foregroundStyle(Theme.Accent.red)
        .help(message)
    }
  }

  private func headerButton(_ symbol: String, help: String,
                            action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: Theme.Size.smallIcon - 3, weight: .medium))
        .foregroundStyle(Theme.Ink.secondary)
        .frame(width: 20, height: 20)
        .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .help(help)
  }

  // MARK: - Fields

  private var fields: some View {
    VStack(spacing: 0) {
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
        .padding(.vertical, Theme.Space.snug)
        .overlay(alignment: .topLeading) {
          if composer.body.isEmpty {
            Text("Write your message…")
              .font(Theme.Font.reading)
              .foregroundStyle(Theme.Ink.tertiary)
              .padding(.horizontal, Theme.Space.loose)
              .padding(.vertical, Theme.Space.cosy)
              .allowsHitTesting(false)
          }
        }
    }
    .background(Theme.Surface.raised)
  }

  // MARK: - Footer

  private var footer: some View {
    HStack(spacing: Theme.Space.loose) {
      Button(action: sendNow) {
        Text("Send")
          .font(Theme.Font.bodyEmphasis)
          .foregroundStyle(.white)
          .padding(.horizontal, Theme.Space.section)
          .padding(.vertical, Theme.Space.snug)
          .background(
            composer.canSend ? Theme.Accent.blue : Theme.Accent.muted,
            in: .rect(cornerRadius: Theme.Radius.control)
          )
          .opacity(composer.canSend ? 1 : 0.45)
      }
      .buttonStyle(.plain)
      .disabled(!composer.canSend)
      .help("Send (⌘↩)")

      if !composer.showsCc {
        Button("Cc") {
          composer.showsCc = true
          focus = .cc
        }
        .buttonStyle(.plain)
        .font(Theme.Font.small)
        .foregroundStyle(Theme.Ink.secondary)
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

      // Suggestions come from threads already in memory, so this list costs a
      // filter rather than a query — and appears without a perceptible delay.
      let matches = showsSuggestions ? suggestions(currentFragment) : []
      if !matches.isEmpty {
        VStack(spacing: 0) {
          ForEach(matches, id: \.email) { participant in
            Button {
              complete(with: participant.email)
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
              .contentShape(.rect)
            }
            .buttonStyle(.plain)
          }
        }
        .padding(.bottom, Theme.Space.tight)
        .background(Theme.Surface.control)
      }
    }
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

/// Focus targets, lifted out so `RecipientField` can name the type.
enum ComposerPanelField: Hashable { case to, cc, subject, body }

/// The resting state of the composer: a small button in the corner it opens
/// from.
///
/// Occupying the same spot the panel expands from is what makes the panel feel
/// like it came from somewhere rather than appearing over everything — the same
/// reason Gmail puts it there.
struct ComposeLaunchButton: View {
  let action: () -> Void
  @State private var isHovering = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: Theme.Space.base) {
        Image(systemName: "square.and.pencil")
          .font(.system(size: Theme.Size.smallIcon, weight: .medium))
        if isHovering {
          Text("Compose").font(Theme.Font.bodyEmphasis)
        }
      }
      .foregroundStyle(.white)
      .padding(.horizontal, isHovering ? Theme.Space.wide : Theme.Space.loose)
      .frame(height: 44)
      .background(Theme.Accent.blue, in: .capsule)
      .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
      .contentShape(.capsule)
    }
    .buttonStyle(.plain)
    .onHover { hovering in
      withAnimation(Theme.Motion.quick) { isHovering = hovering }
    }
    .padding(Theme.Space.section)
    .help("New message (⌘N)")
  }
}
