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
      } else {
        EmptyState(
          title: "No message selected",
          message: store.threads.isEmpty
            ? "Nothing to read in this mailbox."
            : "Choose a conversation, or press ↓ to start reading.",
          symbol: "envelope"
        )
      }
    }
    .background(Theme.Surface.raised)
  }

  // MARK: Toolbar

  /// Snooze is deliberately absent. Gmail exposes no snooze API — other clients
  /// fake it with their own scheduling — so a button here would do nothing.
  private var toolbar: some View {
    HStack(spacing: Theme.Space.loose) {
      // Opens the composer pre-filled. It used to focus a pane pinned to the
      // bottom of this view, which cost ~194pt of reading space on every
      // message whether or not anyone was replying.
      ToolbarPill(symbol: "arrowshape.turn.up.left", title: "Reply",
                  tint: Theme.Accent.blue, outlined: true) {
        store.startReply()
      }
      .help("Reply (⌘R)")

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
                                        isDark: colorScheme == .dark),
            inlineImages: store.inlineImages
          )
          .frame(minHeight: 240)

          let attachments = detail.messages.flatMap { $0.attachments }
            .filter { !$0.isInline }
          if !attachments.isEmpty {
            AttachmentStrip(store: store, attachments: attachments)
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
  @Bindable var store: MailStore
  let attachments: [AttachmentRow]

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Space.base) {
      Text("ATTACHMENTS (\(attachments.count))")
        .font(Theme.Font.caption)
        .foregroundStyle(Theme.Ink.tertiary)

      FlowRow(spacing: Theme.Space.loose) {
        ForEach(attachments) { attachment in
          AttachmentChip(
            attachment: attachment,
            state: store.state(of: attachment),
            symbol: symbol(for: attachment.mimeType),
            open: { Task { await store.openAttachment(attachment) } },
            download: { Task { await store.downloadAttachment(attachment) } }
          )
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

/// One attachment, in whatever state it is actually in.
///
/// The chip is deliberately the same size in every state — the icon is swapped
/// and the subtitle changes, but nothing reflows. Attachments arrive in rows,
/// and a chip that grew while downloading would shove its neighbours around
/// under the pointer that is about to click them.
private struct AttachmentChip: View {
  let attachment: AttachmentRow
  let state: MailStore.AttachmentState
  let symbol: String
  let open: () -> Void
  let download: () -> Void

  @State private var isHovering = false

  var body: some View {
    Button(action: primaryAction) {
      HStack(spacing: Theme.Space.base) {
        leading
          .frame(width: 20, height: 20)

        VStack(alignment: .leading, spacing: Theme.Space.hair) {
          Text(attachment.filename)
            .font(Theme.Font.body)
            .foregroundStyle(Theme.Ink.primary)
            .lineLimit(1)
          Text(subtitle)
            .font(Theme.Font.micro)
            .fontWeight(.regular)
            .foregroundStyle(subtitleTint)
            .lineLimit(1)
        }
      }
      .padding(.horizontal, Theme.Space.cosy)
      .padding(.vertical, Theme.Space.base)
      .background(
        isHovering && isInteractive ? Theme.Surface.selection : Theme.Surface.control,
        in: .rect(cornerRadius: Theme.Radius.control)
      )
      .overlay {
        RoundedRectangle(cornerRadius: Theme.Radius.control)
          .strokeBorder(
            isHovering && isInteractive ? Theme.Accent.blue.opacity(0.5) : .clear
          )
      }
    }
    .buttonStyle(.plain)
    .disabled(!isInteractive)
    .onHover { isHovering = $0 }
    .help(helpText)
    .contextMenu {
      if case .ready(let file) = state {
        Button("Open") { NSWorkspace.shared.open(file) }
        Button("Reveal in Finder") {
          NSWorkspace.shared.activateFileViewerSelecting([file])
        }
        Divider()
        Button("Save a Copy…") { saveCopy(of: file) }
      } else if case .idle = state {
        Button("Download", action: download)
      } else if case .failed = state {
        Button("Try Again", action: download)
      }
    }
  }

  @ViewBuilder
  private var leading: some View {
    switch state {
    case .downloading:
      ProgressView().controlSize(.small)
    case .failed:
      Image(systemName: "exclamationmark.triangle.fill")
        .font(.system(size: 16))
        .foregroundStyle(Theme.Accent.red)
    case .ready:
      Image(systemName: symbol)
        .font(.system(size: 18))
        .foregroundStyle(Theme.Accent.blue)
    case .idle:
      // The arrow says the chip does something. Without it the design's chips
      // read as labels, which is exactly how they behaved before.
      Image(systemName: isHovering ? "arrow.down.circle.fill" : symbol)
        .font(.system(size: 18))
        .foregroundStyle(isHovering ? Theme.Accent.blue : Theme.Ink.secondary)
    case .unavailable:
      Image(systemName: symbol)
        .font(.system(size: 18))
        .foregroundStyle(Theme.Ink.tertiary)
    }
  }

  private var subtitle: String {
    switch state {
    case .idle: attachment.displaySize
    case .downloading: "Downloading…"
    case .ready: attachment.displaySize
    case .failed: "Failed — click to retry"
    case .unavailable: attachment.displaySize
    }
  }

  private var subtitleTint: Color {
    if case .failed = state { return Theme.Accent.red }
    return Theme.Ink.secondary
  }

  private var isInteractive: Bool {
    if case .unavailable = state { return false }
    if case .downloading = state { return false }
    return true
  }

  private var helpText: String {
    switch state {
    case .idle: "Download \(attachment.filename)"
    case .downloading: "Downloading \(attachment.filename)…"
    case .ready: "Open \(attachment.filename)"
    case .failed(let message): message
    case .unavailable: "Gmail exposes no downloadable copy of this part"
    }
  }

  private func primaryAction() {
    switch state {
    case .ready, .idle, .failed: open()
    case .downloading, .unavailable: break
    }
  }

  /// Copies the blob out under its real filename.
  ///
  /// The cache stores it under its content hash, so the file on disk is not
  /// named anything a person would recognise. Exporting is where the display
  /// name from Postgres finally gets applied — and note it is applied by
  /// NSSavePanel, which resolves the user's chosen destination itself. The
  /// email-supplied name never becomes a path we construct.
  private func saveCopy(of file: URL) {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = attachment.filename
    panel.canCreateDirectories = true
    guard panel.runModal() == .OK, let destination = panel.url else { return }
    try? FileManager.default.removeItem(at: destination)
    try? FileManager.default.copyItem(at: file, to: destination)
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

