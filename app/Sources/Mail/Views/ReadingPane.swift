import SwiftUI

/// The reading pane, implementing the design's right-hand column.
///
/// Layout from Figma node `3:158`: a 48pt action toolbar, a scrolling body with
/// subject / avatar header / message HTML / attachments, and a quick-reply
/// panel pinned to the bottom.
struct ReadingPane: View {
  @Bindable var store: MailStore
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    VStack(spacing: 0) {
      if let thread = store.selectedThread {
        toolbar
        Divider().overlay(Theme.Surface.border.opacity(0.5))
        content(for: thread)
        QuickReplyPane(recipient: store.detail?.messages.last?.displayName)
      } else {
        ContentUnavailableView("No message selected", systemImage: "envelope")
          .frame(maxHeight: .infinity)
      }
    }
    .background(Theme.Surface.raised)
  }

  // MARK: Toolbar

  /// Snooze is deliberately absent. Gmail exposes no snooze API — other clients
  /// fake it with their own scheduling — so a button here would do nothing.
  private var toolbar: some View {
    HStack(spacing: Theme.Space.loose) {
      // Reply is not implemented: the engine's `send` outbox op returns 501.
      // Shown because the design leads with it, but visibly inert.
      ToolbarPill(symbol: "arrowshape.turn.up.left", title: "Reply",
                  tint: Theme.Accent.muted, outlined: true, action: nil)
        .help("Replying is not implemented yet")

      ToolbarPill(symbol: "trash", title: "Trash", tint: Theme.Accent.red) {
        Task { await store.trashSelected() }
      }
      ToolbarPill(symbol: "archivebox", title: "Archive", tint: Theme.Ink.primary) {
        Task { await store.archiveSelectedAndAdvance() }
      }

      Spacer()

      ToolbarPill(
        symbol: store.selectedThread?.isStarred == true ? "flag.fill" : "flag",
        title: "Flag",
        tint: store.selectedThread?.isStarred == true
          ? Theme.Accent.flag : Theme.Accent.muted,
        outlined: true
      ) {
        Task { await store.toggleStarOnSelection() }
      }
    }
    .padding(.horizontal, Theme.Space.wide)
    .frame(height: Theme.Size.toolbar)
  }

  // MARK: Body

  private func content(for thread: ThreadRow) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Theme.Space.pane) {
        header(for: thread)

        Divider().overlay(Theme.Surface.border)

        if let detail = store.detail, !detail.messages.isEmpty {
          MessageWebView(
            html: MessageDocument.build(for: detail.messages,
                                        isDark: colorScheme == .dark)
          )
          .frame(minHeight: 240)

          let attachments = detail.messages.flatMap { $0.attachments }
            .filter { !$0.isInline }
          if !attachments.isEmpty {
            AttachmentStrip(attachments: attachments)
          }
        } else if store.detailLoaded {
          Text("This thread has no messages.")
            .font(Theme.Font.body)
            .foregroundStyle(Theme.Ink.secondary)
        } else {
          // Reads hit the local cache first, so this is usually one frame.
          HStack(spacing: Theme.Space.base) {
            ProgressView().controlSize(.small)
            Text("Loading…").font(Theme.Font.small)
              .foregroundStyle(Theme.Ink.secondary)
          }
        }
      }
      .padding(Theme.Space.pane)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .id(thread.id)  // reset scroll when switching threads
  }

  private func header(for thread: ThreadRow) -> some View {
    let newest = store.detail?.messages.last

    return VStack(alignment: .leading, spacing: Theme.Space.loose) {
      Text(store.detail?.subject ?? thread.subject)
        .font(Theme.Font.title)
        .foregroundStyle(Theme.Ink.primary)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)

      HStack(alignment: .center, spacing: Theme.Space.loose) {
        AvatarBubble(name: newest?.displayName ?? thread.displayName)

        VStack(alignment: .leading, spacing: Theme.Space.hair) {
          HStack(spacing: Theme.Space.tight) {
            Text(newest?.displayName ?? thread.displayName)
              .font(Theme.Font.bodyEmphasis)
              .foregroundStyle(Theme.Ink.primary)
            if let email = newest?.fromEmail {
              Text("<\(email)>")
                .font(Theme.Font.body)
                .fontWeight(.regular)
                .foregroundStyle(Theme.Ink.secondary)
                .lineLimit(1)
            }
          }
          if let recipients = newest?.toRecipients, !recipients.isEmpty {
            Text("To: " + recipients.map { $0.email }.joined(separator: ", "))
              .font(Theme.Font.small)
              .foregroundStyle(Theme.Ink.tertiary)
              .lineLimit(1)
          }
        }

        Spacer(minLength: Theme.Space.wide)

        if let sent = newest?.sentDate {
          Text(sent.formatted(date: .abbreviated, time: .shortened))
            .font(Theme.Font.small)
            .foregroundStyle(Theme.Ink.tertiary)
        }
      }
    }
  }
}

// MARK: - Pieces

/// Initials in a circle, as the design's `SL` bubble.
private struct AvatarBubble: View {
  let name: String

  var body: some View {
    Text(initials)
      .font(Theme.Font.reading)
      .fontWeight(.semibold)
      .foregroundStyle(Theme.Accent.muted)
      .frame(width: Theme.Size.avatar, height: Theme.Size.avatar)
      .background(Theme.Accent.mutedFill, in: .circle)
  }

  /// First letters of the first two words, falling back to the leading
  /// character — senders are frequently a single token like "GitHub".
  private var initials: String {
    let words = name.split(separator: " ").prefix(2)
    let letters = words.compactMap { $0.first }.map(String.init)
    return letters.isEmpty ? String(name.prefix(1)).uppercased()
                           : letters.joined().uppercased()
  }
}

private struct ToolbarPill: View {
  let symbol: String
  let title: String
  let tint: Color
  var outlined: Bool = false
  let action: (() -> Void)?

  var body: some View {
    Button(action: { action?() }) {
      HStack(spacing: Theme.Space.tight) {
        Image(systemName: symbol).font(.system(size: Theme.Size.icon - 3))
        Text(title).font(Theme.Font.body)
      }
      .foregroundStyle(tint)
      .padding(.horizontal, Theme.Space.base)
      .padding(.vertical, Theme.Space.snug)
      .background(
        outlined ? Theme.Accent.mutedFill : .clear,
        in: .rect(cornerRadius: Theme.Radius.control)
      )
      .overlay(
        RoundedRectangle(cornerRadius: Theme.Radius.control)
          .stroke(outlined ? tint.opacity(0.7) : .clear, lineWidth: 1)
      )
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .disabled(action == nil)
    .opacity(action == nil ? 0.45 : 1)
  }
}

/// The design's ATTACHMENTS strip.
///
/// Metadata only. The engine records filename, type and size but never
/// downloads the bytes, so these are not openable yet — hence no click target
/// and a tooltip that says so, rather than a chip that does nothing when
/// clicked.
private struct AttachmentStrip: View {
  let attachments: [AttachmentRow]

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Space.base) {
      Text("ATTACHMENTS (\(attachments.count))")
        .font(Theme.Font.caption)
        .foregroundStyle(Theme.Ink.tertiary)

      FlowRow(spacing: Theme.Space.loose) {
        ForEach(attachments) { attachment in
          HStack(spacing: Theme.Space.base) {
            Image(systemName: symbol(for: attachment.mimeType))
              .font(.system(size: 18))
              .foregroundStyle(Theme.Ink.secondary)
            VStack(alignment: .leading, spacing: Theme.Space.hair) {
              Text(attachment.filename)
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Ink.primary)
                .lineLimit(1)
              Text(attachment.displaySize)
                .font(Theme.Font.micro)
                .fontWeight(.regular)
                .foregroundStyle(Theme.Ink.secondary)
            }
          }
          .padding(.horizontal, Theme.Space.cosy)
          .padding(.vertical, Theme.Space.base)
          .background(Theme.Surface.control, in: .rect(cornerRadius: Theme.Radius.control))
          .help("Attachment downloads are not implemented yet")
        }
      }
    }
  }

  private func symbol(for mimeType: String) -> String {
    if mimeType.hasPrefix("image/") { return "photo" }
    if mimeType.contains("pdf") { return "doc.richtext" }
    if mimeType.contains("zip") || mimeType.contains("compressed") { return "doc.zipper" }
    if mimeType.contains("csv") || mimeType.contains("sheet") { return "tablecells" }
    return "doc.text"
  }
}

/// Wraps children onto multiple lines, which `HStack` cannot do.
private struct FlowRow: Layout {
  var spacing: CGFloat

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let maxWidth = proposal.width ?? .infinity
    var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0

    for subview in subviews {
      let size = subview.sizeThatFits(.unspecified)
      if x + size.width > maxWidth, x > 0 {
        x = 0
        y += rowHeight + spacing
        rowHeight = 0
      }
      x += size.width + spacing
      rowHeight = max(rowHeight, size.height)
    }
    return CGSize(width: maxWidth, height: y + rowHeight)
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0

    for subview in subviews {
      let size = subview.sizeThatFits(.unspecified)
      if x + size.width > bounds.maxX, x > bounds.minX {
        x = bounds.minX
        y += rowHeight + spacing
        rowHeight = 0
      }
      subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
      x += size.width + spacing
      rowHeight = max(rowHeight, size.height)
    }
  }
}

/// The design's quick-reply panel.
///
/// Present but inert. Sending requires composing an RFC 5322 message and
/// calling `users.messages.send`; the outbox already has a `send` op defined,
/// but it returns 501. The panel is kept because removing it would take 194pt
/// out of the reading pane and change the design's proportions — and because a
/// visible, honestly-disabled affordance is better than a missing one.
private struct QuickReplyPane: View {
  let recipient: String?
  @State private var draft = ""

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Space.loose) {
      HStack {
        HStack(spacing: Theme.Space.base) {
          Image(systemName: "arrowshape.turn.up.left")
            .font(.system(size: Theme.Size.smallIcon))
          Text(recipient.map { "Reply to \($0)" } ?? "Reply")
            .font(Theme.Font.bodyEmphasis)
        }
        .foregroundStyle(Theme.Ink.primary)

        Spacer()

        Text("Not implemented yet")
          .font(Theme.Font.caption)
          .fontWeight(.regular)
          .foregroundStyle(Theme.Ink.tertiary)
      }

      TextEditor(text: $draft)
        .font(Theme.Font.body)
        .fontWeight(.regular)
        .scrollContentBackground(.hidden)
        .frame(height: 72)
        .padding(Theme.Space.loose)
        .background(Theme.Surface.raised, in: .rect(cornerRadius: Theme.Radius.panel))
        .disabled(true)
        .overlay(alignment: .topLeading) {
          if draft.isEmpty {
            Text("Composing is not available yet.")
              .font(Theme.Font.body)
              .fontWeight(.regular)
              .foregroundStyle(Theme.Ink.tertiary)
              .padding(Theme.Space.loose + Theme.Space.tight)
              .allowsHitTesting(false)
          }
        }

      HStack {
        Image(systemName: "paperclip")
          .foregroundStyle(Theme.Ink.tertiary)
        Spacer()
        Text("Send Reply")
          .font(Theme.Font.bodyEmphasis)
          .foregroundStyle(.white)
          .padding(.horizontal, Theme.Space.wide)
          .padding(.vertical, Theme.Space.base)
          .background(Theme.Accent.muted, in: .rect(cornerRadius: Theme.Radius.control))
          .opacity(0.45)
      }
    }
    .padding(Theme.Space.wide)
    .background(Theme.Surface.sunken)
  }
}
