import SwiftUI

/// The reading pane, implementing the design's right-hand column.
///
/// Layout from Figma node `3:158`: a 48pt action toolbar, a scrolling body with
/// subject / avatar header / message HTML / attachments, and a quick-reply
/// panel pinned to the bottom.
struct ReadingPane: View {
  @Bindable var store: MailStore
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.paneLayout) private var layout
  /// Height of the rendered message, measured by the web view.
  ///
  /// Starts at a screenful so the pane does not visibly jump on first paint;
  /// the real value arrives a frame later.
  @State private var bodyHeight: CGFloat = 400
  @State private var settings = ReadingSettings.shared
  /// A one-off "Load images" for this thread, used only while the standing
  /// preference is off. It resets when the thread changes: consenting to load
  /// one sender's images is not consent for the next one's.
  @State private var loadsImagesForThisThread = false

  /// Whether this message's remote images should render.
  private var showsRemoteImages: Bool {
    settings.loadsRemoteImages || loadsImagesForThisThread
  }

  var body: some View {
    VStack(spacing: 0) {
      if store.hasMultipleSelected {
        // The pane used to say "No message selected" here, which was true of a
        // single message and useless during a bulk operation — while being the
        // only part of the window with room to run one.
        BulkActionPanel(store: store)
      } else if let thread = store.selectedThread {
        toolbar
        Divider().overlay(Theme.Surface.border.opacity(0.5))
        content(for: thread)
      } else {
        // This is the state a reader sees on every launch and after every
        // archive-to-empty, in by far the largest region of the window. It
        // used to be a 28pt glyph and two lines of text in a 1150×1500pt void.
        // The keyboard model is what is genuinely useful in the exact moment
        // there is nothing else to do — and it is otherwise discoverable only
        // through the menu bar.
        EmptyState(
          title: "Nothing open",
          message: store.threads.isEmpty
            ? "Nothing to read in this mailbox."
            : "Choose a conversation, or press ↓ to start reading.",
          symbol: "envelope",
          shortcuts: store.threads.isEmpty ? [] : KeyboardHint.triage
        )
      }
    }
    .background(Theme.Surface.raised)
  }

  // MARK: Toolbar

  /// Snooze is deliberately absent. Gmail exposes no snooze API — other clients
  /// fake it with their own scheduling — so a button here would do nothing.
  ///
  /// ## Why the weights are what they are
  ///
  /// There used to be four buttons and three visual treatments: Reply outlined
  /// in blue, Trash bare in red **second from the left**, Archive bare in
  /// primary ink, Flag outlined and right-aligned. So the only irreversible
  /// action in the row sat in the primary hit zone next to Reply, and red on a
  /// bare ground gave it MORE salience than Archive — which is the action a
  /// triage client actually wants people to reach for.
  ///
  /// Now: Archive is the one filled action, Reply is secondary, and Trash moves
  /// to the far right beside Flag, across the spacer, as bare ink that only
  /// turns red on hover. Distance as well as colour — the same reasoning
  /// `BulkActionPanel` already applied correctly, which the toolbar should
  /// match rather than contradict.
  private var toolbar: some View {
    HStack(spacing: Theme.Space.loose) {
      ToolbarPill(symbol: "archivebox", title: "Archive",
                  role: .primary, showsTitle: layout.showsToolbarLabels) {
        Task { await store.archiveSelectedAndAdvance() }
      }
      .help("Archive (E)")

      // Opens the composer pre-filled. It used to focus a pane pinned to the
      // bottom of this view, which cost ~194pt of reading space on every
      // message whether or not anyone was replying.
      //
      // Ink, not blue: this is the SECOND action in a context whose primary is
      // now Archive, and blue means the primary one.
      ToolbarPill(symbol: "arrowshape.turn.up.left", title: "Reply",
                  role: .secondary, showsTitle: layout.showsToolbarLabels) {
        store.startReply()
      }
      .help("Reply (⌘R)")

      Spacer()

      ToolbarPill(
        symbol: store.selectedThread?.isStarred == true ? "flag.fill" : "flag",
        title: "Flag",
        role: .flag(isOn: store.selectedThread?.isStarred == true),
        showsTitle: layout.showsToolbarLabels
      ) {
        Task { await store.toggleStarOnSelection() }
      }
      // One bounce when the state changes, in either direction. The flag is the
      // only thing in this toolbar that has a state to report.
      .symbolEffect(.bounce, value: store.selectedThread?.isStarred)
      .help("Flag (S)")

      ToolbarPill(symbol: "trash", title: "Trash", role: .destructive,
                  showsTitle: layout.showsToolbarLabels) {
        Task { await store.trashSelected() }
      }
      .help("Move to Trash")
    }
    .padding(.horizontal, Theme.Space.wide)
    .frame(height: Theme.Size.toolbar)
  }

  // MARK: Body

  private func content(for thread: ThreadRow) -> some View {
    ScrollViewReader { proxy in
      scrollBody(for: thread, proxy: proxy)
    }
  }

  private func scrollBody(for thread: ThreadRow, proxy: ScrollViewProxy) -> some View {
    ScrollView {
      // Lazy so the section header can pin. The subject scrolls away and the
      // sender row stays: on a long message you always know whose it is and
      // when it arrived, which is exactly the thing you lose scrolling a
      // newsletter, without spending permanent height on a subject you have
      // already read.
      LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
        subject(for: thread)

        Section {
          messageBody
        } header: {
          SenderBar(thread: thread, newest: store.detail?.messages.last)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      // An anchor to scroll back to, INSTEAD of `.id(thread.id)` on the
      // ScrollView. That was resetting scroll by giving SwiftUI a new
      // identity, which tore the whole subtree down — including the
      // `WKWebView` — and built a fresh one per message.
      //
      // Measured over 10 real messages: a reused web view reaches `didCommit`,
      // the point where the new document can paint, in 4ms. A fresh one takes
      // 69ms, and the pane is genuinely empty for all of them. That gap is the
      // "beat" before a message appears while arrowing down the list.
      .id(Self.topAnchor)
    }
    .onChange(of: thread.id) { _, _ in
      proxy.scrollTo(Self.topAnchor, anchor: .top)
      // Height is NOT reset to a placeholder here. Doing that collapsed the
      // pane to 400pt and then jumped it to the real height a frame later,
      // which reads as a lurch even when the load itself is instant. Keeping
      // the outgoing height holds the layout still for the few milliseconds
      // until the new document is measured, and a height already seen for this
      // conversation is reused outright.
      bodyHeight = Self.heightCache[thread.id] ?? bodyHeight
      loadsImagesForThisThread = false
    }
  }

  /// Where `scrollTo` sends the pane when the conversation changes.
  private static let topAnchor = "message-top"

  /// Last measured height per conversation.
  ///
  /// Returning to a message you have already opened should not re-run the
  /// collapse-and-grow, and while arrowing up and down a thread list that is
  /// most of the navigation. Bounded because a mailbox is not.
  nonisolated(unsafe) private static var heightCache: [String: CGFloat] = [:]
  private static let heightCacheLimit = 200

  private static func rememberHeight(_ height: CGFloat, for id: String) {
    if heightCache.count >= heightCacheLimit { heightCache.removeAll(keepingCapacity: true) }
    heightCache[id] = height
  }

  private func subject(for thread: ThreadRow) -> some View {
    // The one place the app hands you someone else's words at headline size,
    // and therefore the one place the serif belongs. Everything operational
    // around it — the toolbar, the sender bar, the rail — stays on SF.
    Text(store.detail?.subject ?? thread.subject)
      .font(Theme.Font.display)
      .foregroundStyle(Theme.Ink.primary)
      .textSelection(.enabled)
      .fixedSize(horizontal: false, vertical: true)
      .padding(.horizontal, Theme.Space.pane)
      .padding(.top, Theme.Space.pane)
      .padding(.bottom, Theme.Space.wide)
      .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var blockedImages: Int {
    MessageDocument.blockedImageCount(in: store.detail?.messages ?? [])
  }

  @ViewBuilder
  private var messageBody: some View {
    VStack(alignment: .leading, spacing: Theme.Space.pane) {
      if let detail = store.detail, !detail.messages.isEmpty {
        if !showsRemoteImages, blockedImages > 0 {
          // `standard`, not `quick`: loading images changes the document's
          // height by an arbitrary amount, and a reveal that moves layout
          // wants the same spring a row insertion gets.
          RemoteImageBanner(count: blockedImages) {
            withAnimation(Theme.Motion.standard) { loadsImagesForThisThread = true }
          }
          .padding(.horizontal, Theme.Space.pane)
        }

        let rendered = MessageDocument.build(
          for: detail.messages,
          isDark: colorScheme == .dark,
          showRemoteImages: showsRemoteImages
        )

        MessageWebView(
          html: rendered.html,
          inlineImages: store.inlineImages,
          onHeightChange: { height in
            bodyHeight = height
            // Keyed off the open conversation rather than a captured value:
            // this closure outlives the render that made it, and a late
            // measurement must not be filed under the message that replaced it.
            if let id = store.selectedThreadID {
              Self.rememberHeight(height, for: id)
            }
          }
        )
        // Exactly the document's height, so the OUTER scroll view does all
        // the scrolling. A fixed minHeight gave short messages dead space
        // below them and long ones a second scrollbar inside the first.
        .frame(height: max(bodyHeight, 200))
        // ## Why a white message gets a frame
        //
        // The decision to render on a light canvas is right and well argued —
        // 11 of 30 sampled messages had sub-2:1 text otherwise. The
        // PRESENTATION was what was wrong: the body ran edge to edge on
        // `#ffffff`, butting straight into the dark sender bar with no
        // transition, so a ~1150×1000pt white rectangle sat in a navy window
        // as the single loudest thing in the interface.
        //
        // And it is not content. It is the CANVAS for content, which the
        // sender chose and the app is honouring. Inset, rounded, hairlined and
        // lifted, it reads as *a page the app is showing you* — which is what
        // it is, and what Mail, Superhuman and Missive all do.
        .documentFrame(rendered.usesLightCanvas)

        let attachments = detail.messages.flatMap { $0.attachments }
          .filter { !$0.isInline }
        if !attachments.isEmpty {
          AttachmentStrip(store: store, attachments: attachments)
            .padding(.horizontal, Theme.Space.pane)
        }
      } else if store.detailLoaded {
        Text("This thread has no messages.")
          .font(Theme.Font.body)
          .foregroundStyle(Theme.Ink.secondary)
          .padding(.horizontal, Theme.Space.pane)
      } else {
        // Reads hit the local cache first, so this is usually one frame.
        HStack(spacing: Theme.Space.base) {
          ProgressView().controlSize(.small)
          Text("Loading…").font(Theme.Font.small)
            .foregroundStyle(Theme.Ink.secondary)
        }
        .padding(.horizontal, Theme.Space.pane)
      }
    }
    // No horizontal inset here. It cost the message 48pt, and mail is laid
    // out for a canvas of about 600-700pt: measured over 30 real messages,
    // 75% overflowed at 557pt and only 6% at 700pt. The inset was buying
    // whitespace that the messages themselves already provide, and paying for
    // it by shrinking every one of them. The children that are OUR chrome
    // rather than the sender's keep their padding.
    .padding(.top, Theme.Space.wide)
    .padding(.bottom, Theme.Space.pane)
    .frame(maxWidth: .infinity, alignment: .leading)
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
      // `mutedInk`, not `muted`. The fill token measured 2.93:1 here — the
      // worst text contrast anywhere in the app, on one of the largest and
      // most persistent elements in the reading pane. A neutral fill and a
      // neutral foreground are two jobs, and one value cannot hold both.
      .foregroundStyle(Theme.Accent.mutedInk)
      .frame(width: Theme.Size.avatar, height: Theme.Size.avatar)
      .background(Theme.Accent.mutedFill, in: .circle)
      .accessibilityHidden(true)
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
  /// What this action IS, rather than how it is painted. The three visual
  /// treatments the toolbar used to carry were assigned per-button by hand,
  /// which is how the destructive action ended up more prominent than the
  /// triage one.
  enum Role: Equatable {
    /// The one action this context wants you to take. Filled.
    case primary
    /// Everything else you would ordinarily do. Ink on a quiet ground.
    case secondary
    /// Irreversible. Ink until hover, then red — isolated by distance too.
    case destructive
    /// Carries state rather than being a plain action.
    case flag(isOn: Bool)
  }

  let symbol: String
  let title: String
  let role: Role
  /// Dropped on narrow windows. Four labelled pills want about 400pt; four
  /// icons want about 150pt and lose only a word that the tooltip still
  /// carries. Previously the labels dropped but the OUTLINED BOXES stayed, so
  /// Reply and Flag read as *selected* rather than as buttons — which is why
  /// the outline is gone entirely and weight is carried by fill.
  var showsTitle: Bool = true
  let action: (() -> Void)?

  @State private var isHovering = false

  var body: some View {
    Button(action: { action?() }) {
      HStack(spacing: Theme.Space.tight) {
        Image(systemName: symbol).font(Theme.Icon.medium)
        if showsTitle {
          // fixedSize so it can never wrap: if it does not fit, the layout step
          // above should have dropped it, and a torn word is not a fallback.
          Text(title).font(Theme.Font.body).fixedSize()
        }
      }
      .padding(.horizontal, Theme.Space.loose)
      .padding(.vertical, Theme.Space.tight)
    }
    // The tint is the STYLE's, not the label's — see `AlapButtonStyle.tint`.
    // Set on the label it would outrank the disabled treatment, and this pill
    // is disabled whenever its action is nil.
    .buttonStyle(.alap(role == .primary ? .primary : .quiet,
                       tint: role == .primary ? nil : tint))
    .onHover { isHovering = $0 }
    .disabled(action == nil)
    .accessibilityLabel(title)
  }

  private var tint: Color {
    switch role {
    case .primary: return .white
    case .secondary: return Theme.Ink.primary
    case .destructive: return isHovering ? Theme.Accent.red : Theme.Ink.secondary
    case .flag(let isOn): return isOn ? Theme.Accent.flag : Theme.Ink.secondary
    }
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
            .monospacedDigit()
            .lineLimit(1)
        }
      }
      .padding(.horizontal, Theme.Space.loose)
      .padding(.vertical, Theme.Space.base)
      .overlay {
        // `borderStrong`, not blue at 50%. A hover outline is a MEANINGFUL
        // state, which is the one thing the decorative hairline is explicitly
        // not for — and blue here was one of the six diluted meanings, since
        // hovering a chip is not the primary action in any context.
        RoundedRectangle(cornerRadius: Theme.Radius.control)
          .strokeBorder(isHovering && isInteractive ? Theme.Surface.borderStrong : .clear)
      }
    }
    .buttonStyle(.alap(.secondary))
    .disabled(!isInteractive)
    .onHover { isHovering = $0 }
    .help(helpText)
    // A11y: the chip was reachable only by pointer, and its context menu
    // (Open / Reveal / Save a Copy) had no keyboard path at all. Focusable
    // plus a named default action gives it one; the Message menu mirrors the
    // rest.
    .focusable(isInteractive)
    .focusEffectDisabled(false)
    .accessibilityLabel("\(attachment.filename), \(subtitle)")
    .accessibilityHint(helpText)
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
        .font(Theme.Icon.large)
        .foregroundStyle(Theme.Accent.red)
    case .ready:
      // Ink, not blue. A file-type glyph rendered in the action colour is a
      // button that isn't — it decorates rather than offering anything.
      Image(systemName: symbol)
        .font(Theme.Icon.large)
        .foregroundStyle(Theme.Ink.secondary)
    case .idle:
      // The arrow says the chip does something. Without it the design's chips
      // read as labels, which is exactly how they behaved before.
      // The ink SHIFTS on hover rather than changing hue — the glyph already
      // changes, which is the part that says "this does something".
      Image(systemName: isHovering ? "arrow.down.circle.fill" : symbol)
        .font(Theme.Icon.large)
        .foregroundStyle(isHovering ? Theme.Ink.primary : Theme.Ink.secondary)
    case .unavailable:
      Image(systemName: symbol)
        .font(Theme.Icon.large)
        .foregroundStyle(Theme.Ink.disabled)
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


/// The sender row, pinned to the top of the reading pane while the body
/// scrolls beneath it.
///
/// Two details make the difference between "sticky" and "broken":
///
///   - The background is OPAQUE. A pinned header over a scroll view shows the
///     content sliding underneath it otherwise, which reads as a rendering
///     glitch rather than a design.
///   - A hairline sits along the bottom edge at all times. Without it the row
///     has no boundary once content is behind it, and the sender's name
///     appears to be part of the message.
private struct SenderBar: View {
  let thread: ThreadRow
  let newest: MessageRow?
  @Environment(\.paneLayout) private var layout

  var body: some View {
    HStack(alignment: .center, spacing: Theme.Space.loose) {
      AvatarBubble(name: newest?.displayName ?? thread.displayName)

      VStack(alignment: .leading, spacing: Theme.Space.hair) {
        HStack(spacing: Theme.Space.tight) {
          // The NAME truncates rather than wrapping — it used to break into
          // "Taylor Shaha / n" in a narrow pane — and the address yields first,
          // because a truncated address is still recognisable while a
          // truncated name is not.
          Text(newest?.displayName ?? thread.displayName)
            .font(Theme.Font.bodyEmphasis)
            .foregroundStyle(Theme.Ink.primary)
            .lineLimit(1)
            .fixedSize(horizontal: false, vertical: true)
            .layoutPriority(1)
          if let email = newest?.fromEmail, layout.showsToolbarLabels {
            Text("<\(email)>")
              .font(Theme.Font.body)
              .fontWeight(.regular)
              .foregroundStyle(Theme.Ink.secondary)
              .lineLimit(1)
              .truncationMode(.middle)
          }
        }
        // Recipients are the first thing to go: on a narrow pane they are a
        // truncated list of addresses, which tells you less than nothing.
        if layout.showsRowPreview,
           let recipients = newest?.toRecipients, !recipients.isEmpty {
          Text("To: " + recipients.map(\.email).joined(separator: ", "))
            .font(Theme.Font.small)
            .foregroundStyle(Theme.Ink.tertiary)
            .lineLimit(1)
            .truncationMode(.middle)
        }
      }

      Spacer(minLength: Theme.Space.wide)

      if let sent = newest?.sentDate {
        Text(sent.formatted(date: .abbreviated, time: .shortened))
          .font(Theme.Font.small)
          .foregroundStyle(Theme.Ink.tertiary)
      }
    }
    .padding(.horizontal, Theme.Space.pane)
    .padding(.vertical, Theme.Space.loose)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Theme.Surface.raised)
    .overlay(alignment: .bottom) {
      Rectangle()
        .fill(Theme.Surface.border)
        .frame(height: 1)
    }
  }
}

/// Offers to load the remote images the sanitiser withheld.
///
/// Phrased as what it costs rather than what it does. "Images blocked" tells
/// you nothing about why you would or would not want them; a remote image in
/// mail is a tracking pixel far more often than it is a picture, and loading
/// one tells the sender the message was opened, by whom, and roughly from
/// where. That is the decision being made, so that is what the row says.
private struct RemoteImageBanner: View {
  let count: Int
  let load: () -> Void

  var body: some View {
    HStack(spacing: Theme.Space.loose) {
      Image(systemName: "eye.slash")
        .font(Theme.Icon.medium)
        .foregroundStyle(Theme.Ink.secondary)

      VStack(alignment: .leading, spacing: Theme.Space.hair) {
        Text(count == 1 ? "1 remote image not loaded"
                        : "\(count) remote images not loaded")
          .font(Theme.Font.small)
          .foregroundStyle(Theme.Ink.primary)
        Text("Loading them tells the sender you opened this message.")
          .font(Theme.Font.micro)
          .fontWeight(.regular)
          .foregroundStyle(Theme.Ink.tertiary)
      }

      Spacer(minLength: Theme.Space.base)

      Button(action: load) {
        // Outlined, NOT tinted.
        //
        // `blueText` on its own 12% tint is a self-tint, and the tint drags the
        // backdrop toward the label: over `Surface.control` — which is exactly
        // what this banner sits on — it measures 4.37/4.39/4.15:1 across the
        // three palettes, i.e. straight back into the 3.82-4.37 band the split
        // token was introduced to escape. The same treatment is fine on
        // `base` (5.0-5.8:1), which is why the two other sites keep it.
        //
        // Dropping the fill puts the label on bare `control` at 4.91-5.31:1,
        // and `borderStrong` carries the affordance — it is the token for an
        // outline that means something, and clears the 3:1 graphical floor.
        Text("Load images")
          .font(Theme.Font.small)
          .foregroundStyle(Theme.Accent.blueText)
          .padding(.horizontal, Theme.Space.loose)
          .padding(.vertical, Theme.Space.tight)
          .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.control)
              .strokeBorder(Theme.Surface.borderStrong, lineWidth: 1)
          }
      }
      .buttonStyle(.alap())
    }
    .padding(.horizontal, Theme.Space.loose)
    .padding(.vertical, Theme.Space.base)
    .background(Theme.Surface.control, in: .rect(cornerRadius: Theme.Radius.control))
    .transition(.opacity)
  }
}

// MARK: - The document frame

extension View {
  /// Frames a sender's white page as a document rather than adopting it as an
  /// app surface.
  ///
  /// Only when the message actually brought its own colours. A message
  /// rendering on the app's own theme is already on an app surface and framing
  /// it would be inventing a boundary that is not there.
  @MainActor
  @ViewBuilder
  func documentFrame(_ isLightCanvas: Bool) -> some View {
    if isLightCanvas {
      background(Color.white)
        .clipShape(.rect(cornerRadius: Theme.Radius.panel))
        .overlay {
          RoundedRectangle(cornerRadius: Theme.Radius.panel)
            .strokeBorder(Theme.Surface.border.opacity(0.6), lineWidth: 1)
        }
        .elevation(Theme.Elevation.raised)
        .padding(.horizontal, Theme.Space.wide)
    } else {
      self
    }
  }
}
