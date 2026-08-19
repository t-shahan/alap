import SwiftUI

/// One conversation in the list.
///
/// ## Anatomy
///
/// `[rail 2][gutter 38][content …]`, at a height fixed by the density
/// preference rather than emergent from the content. The rail and the gutter
/// are not density's business — a control and its reserved slot are the same
/// size whatever the row height — so only `content` changes shape.
struct ThreadListRow: View {
  let thread: ThreadRow
  /// The owning account's colour, or nil when only one account is connected.
  ///
  /// Nil is not the same as "no colour": with a single mailbox the rail is
  /// pure noise, and every row carrying it would be a decoration that means
  /// nothing. It appears exactly when it starts carrying information.
  let accountTint: Color?
  let isSelected: Bool
  /// True once anything is selected.
  ///
  /// Once a selection exists, every checkbox stays visible — otherwise
  /// extending it means hunting for a control that only appears under the
  /// pointer, one row at a time.
  let isSelecting: Bool
  /// True for the one row showing in the reading pane.
  ///
  /// Distinct from `isSelected`, which is the checkbox. Reading a conversation
  /// does not tick it, so the row that is OPEN is the one whose flag is worth
  /// offering without being pointed at.
  let isOpen: Bool
  /// True when this is the open row AND the list holds keyboard focus.
  let isKeyboardFocused: Bool
  let toggle: () -> Void
  let flag: () -> Void

  @Environment(\.paneLayout) private var layout
  @State private var isHovering = false
  @State private var settings = ReadingSettings.shared

  private var anatomy: RowAnatomy { RowAnatomy(settings.listDensity) }

  private var affordances: ThreadRowAffordances {
    ThreadRowAffordances(
      isHovering: isHovering,
      isOpen: isOpen,
      isChecked: isSelected,
      isSelecting: isSelecting,
      isFlagged: thread.isStarred
    )
  }

  var body: some View {
    HStack(spacing: 0) {
      rail
      gutter
      content
    }
    // Fixed per density, so `List` gets a constant row height — a real scroll
    // win at 500 rows — and the list finally has a vertical rhythm. It used to
    // be whatever the content stacked up to, in three different variants.
    .frame(height: anatomy.height)
    .onHover { isHovering = $0 }
    // A focus indicator the keyboard user can actually see, drawn here rather
    // than by AppKit so it matches the row it is marking.
    //
    // It encloses the WHOLE row: it begins just inside the account rail —
    // which is a pane-level ownership marker rather than part of this row's
    // box — and runs to the row's trailing edge, so the timestamp is inside
    // the outline rather than beside it.
    .overlay {
      RoundedRectangle(cornerRadius: Theme.Radius.control)
        .strokeBorder(Theme.State.focus, lineWidth: 2)
        .padding(.leading, 2)
        .padding(.vertical, 1)
        .opacity(isKeyboardFocused ? 1 : 0)
    }
    .animation(Theme.Motion.fade, value: isKeyboardFocused)
    // One combined element with named actions, rather than five sibling `Text`
    // views read out separately, five hundred rows deep. `.combine` alone
    // would swallow the two gutter buttons, so the actions are named
    // explicitly instead.
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilityDescription)
    .accessibilityAction(named: isSelected ? "Deselect" : "Select", toggle)
    .accessibilityAction(named: affordances.flagLabel, flag)
  }

  // MARK: The rail

  /// A continuous account rail rather than a dashed ladder.
  ///
  /// It used to be inset 4pt top and bottom on every row, so down the left edge
  /// the result was a broken ladder with a gap at each row boundary — which
  /// reads as a rendering defect rather than as a quiet ownership cue. Running
  /// it full-bleed makes it break only where the account actually changes,
  /// which turns it from decoration into information.
  ///
  /// Quiet by default and full strength on the row you are dealing with: in the
  /// light theme it was the single most saturated element in the list, which
  /// made an ownership marker read as an unread or error state.
  private var rail: some View {
    Rectangle()
      .fill(accountTint ?? .clear)
      .frame(width: 2)
      .opacity(isOpen || isSelected || isHovering ? 1 : 0.35)
      .animation(Theme.Motion.fade, value: isHovering)
  }

  // MARK: The gutter

  /// The two controls that act on this row alone.
  ///
  /// Both slots are held open whether or not their control is showing, and
  /// only the opacity changes. Inserting them conditionally moved every row's
  /// text sideways as the pointer swept down the list — the unread dot already
  /// avoids exactly this, and with two controls the jump would have been ~50pt.
  private var gutter: some View {
    HStack(spacing: 0) {
      // Without it, multi-select is discoverable only by knowing to hold ⌘ —
      // which is a feature nobody finds.
      Button(action: toggle) {
        Image(systemName: affordances.checkboxSymbol)
          .font(Theme.Icon.small)
          // Blue as CHECKED STATE on a selection control: the platform's own
          // idiom, not a sixth meaning for the accent.
          .foregroundStyle(isSelected ? Theme.Accent.blue : Theme.Ink.tertiary)
          .frame(width: Theme.Size.hitTarget, height: Theme.Size.hitTarget)
          .contentShape(.rect)
      }
      .buttonStyle(.plain)
      .opacity(affordances.showsCheckbox ? 1 : 0)
      .allowsHitTesting(affordances.showsCheckbox)

      // Flagging one conversation used to mean ticking it first, or opening
      // it and crossing to the reading pane's toolbar. Both are detours from
      // a list you are already pointing at.
      Button(action: flag) {
        Image(systemName: affordances.flagSymbol)
          .font(Theme.Icon.small)
          .foregroundStyle(thread.isStarred ? Theme.Accent.flag : Theme.Ink.tertiary)
          .frame(width: Theme.Size.hitTarget, height: Theme.Size.hitTarget)
          .contentShape(.rect)
      }
      .buttonStyle(.plain)
      .opacity(affordances.showsFlag ? 1 : 0)
      .allowsHitTesting(affordances.showsFlag)
      .symbolEffect(.bounce, value: thread.isStarred)
      // S is named only on the open row, because that is the only row it
      // acts on — advertising it on every row would teach a shortcut that
      // flags a different conversation than the one being pointed at.
      .help(isOpen ? "\(affordances.flagLabel) (S)" : affordances.flagLabel)
    }
    .padding(.leading, Theme.Space.tight)
    .animation(Theme.Motion.quick, value: affordances)
    // The buttons are reached through the row's named accessibility actions.
    .accessibilityHidden(true)
  }

  // MARK: Content

  @ViewBuilder
  private var content: some View {
    if anatomy.isSingleLine {
      compactContent
    } else {
      stackedContent
    }
    // The gutter already IS the left margin. Reserving 44pt of it on top of a
    // 16pt content inset stacked margin on margin and pushed every subject a
    // checkbox-and-a-half clear of the controls — visibly too far at the list
    // widths the layout allows. Any slot reserved outside a content box should
    // come out of that box's inset, not add to it.
  }

  /// The sender column's width in the compact row.
  ///
  /// A FIXED column, not a flexible one, and this is the detail that decides
  /// whether a one-line row works at all.
  ///
  /// Letting the name size to its content looked reasonable and read terribly:
  /// at the 300-340pt list widths `PaneLayout` allows, "Navy Federal Credit
  /// Union" alone consumed the row and the subject was truncated to a single
  /// character — so the list showed you who wrote and never what about, which
  /// is the half that decides whether a conversation is worth opening.
  ///
  /// A fixed column also buys the thing that makes a dense list scannable in
  /// the first place: a consistent vertical edge the eye can track down. That
  /// is why every list-first client that ships a one-line row has one.
  /// Proportional, and clamped at both ends.
  ///
  /// A flat 116pt was the first attempt and it was too greedy: this list is
  /// 300-340pt, not the 500-600pt the one-line row is usually drawn at, so a
  /// fixed column sized for the widest sender starved the subject on every row
  /// with a short one. Thirty per cent of the list keeps the alignment edge
  /// while leaving the subject the larger share, which is the correct
  /// priority — the sender tells you who, the subject tells you whether.
  private var senderColumn: CGFloat {
    min(112, max(64, layout.listWidth * 0.30))
  }

  /// One line: dot, name, subject — snippet, then the trailing cluster.
  private var compactContent: some View {
    HStack(spacing: Theme.Space.base) {
      unreadDot
      Text(thread.displayName)
        .font(thread.isUnread ? Theme.Font.bodyStrong : Theme.Font.bodyEmphasis)
        .foregroundStyle(Theme.Ink.primary)
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(width: senderColumn, alignment: .leading)

      // One `Text` concatenation rather than two views, so truncation eats the
      // snippet before it touches the subject — which is the half that decides
      // whether the row is worth opening.
      //
      // It takes the priority, too. The name has a fixed column and cannot
      // grow into anything; everything left over belongs to what the message
      // is about.
      (subjectText + Text("  —  ").foregroundColor(Theme.Ink.tertiary) + snippetText)
        .lineLimit(1)
        .layoutPriority(1)

      Spacer(minLength: Theme.Space.tight)
      trailingCluster
    }
    .padding(.leading, Theme.Space.tight)
    .padding(.trailing, Theme.Space.loose)
  }

  /// Name row above subject above snippet, at one or two lines of preview.
  private var stackedContent: some View {
    VStack(alignment: .leading, spacing: Theme.Space.tight) {
      HStack(spacing: Theme.Space.base) {
        unreadDot
        Text(thread.displayName)
          .font(thread.isUnread ? Theme.Font.bodyStrong : Theme.Font.bodyEmphasis)
          .foregroundStyle(Theme.Ink.primary)
          .lineLimit(1)
        Spacer(minLength: Theme.Space.base)
        trailingCluster
      }

      VStack(alignment: .leading, spacing: Theme.Space.hair) {
        subjectText.lineLimit(1)
        snippetText.lineLimit(anatomy.snippetLines)
      }
      .padding(.leading, Theme.Space.wide)
    }
    .padding(.leading, Theme.Space.tight)
    .padding(.trailing, Theme.Space.loose)
    .padding(.vertical, Theme.Space.base)
  }

  private var subjectText: Text {
    Text(thread.subject)
      .font(thread.isUnread ? Theme.Font.smallEmphasis : Theme.Font.small)
      .foregroundColor(Theme.Ink.primary)
  }

  private var snippetText: Text {
    Text(thread.snippet)
      .font(Theme.Font.small)
      .foregroundColor(Theme.Ink.secondary)
  }

  /// 8pt unread dot, always occupying its slot so names stay aligned.
  private var unreadDot: some View {
    Circle()
      .fill(thread.isUnread ? Theme.Accent.blue : .clear)
      .frame(width: Theme.Size.unreadDot, height: Theme.Size.unreadDot)
      // Reading a conversation fades the dot rather than snapping it.
      // Deliberately NOT applied to the name and subject weights beside it:
      // interpolated font weight shimmers.
      .animation(Theme.Motion.fade, value: thread.isUnread)
  }

  /// The two facts the row already decoded and never showed, plus the time.
  ///
  /// `ThreadRow` has always carried `messageCount` and `hasAttachments`, on
  /// every row of every update, and neither reached a pixel — so a conversation
  /// with fourteen messages and one with a single notice were indistinguishable,
  /// and an attachment was invisible until the message was open. For a triage
  /// instrument those are first-order questions.
  ///
  /// Both markers are conditional, because absence carries meaning too: a
  /// count of 1 is the default state of mail and renders nothing, and a marker
  /// that appears on every row is noise. Both are trailing, so the left edge
  /// the row defends is untouched.
  private var trailingCluster: some View {
    HStack(spacing: Theme.Space.tight) {
      if thread.hasAttachments {
        // A glyph, not a colour: it has to survive every palette without
        // joining the accent budget.
        Image(systemName: "paperclip")
          .font(Theme.Icon.small)
          .foregroundStyle(Theme.Ink.tertiary)
          .accessibilityHidden(true)
      }
      if thread.messageCount > 1 {
        Text("·\u{2009}\(thread.messageCount > 99 ? "99+" : "\(thread.messageCount)")")
          .font(Theme.Font.caption)
          .fontWeight(.regular)
          .foregroundStyle(Theme.Ink.tertiary)
          .monospacedDigit()
      }
      Text(thread.displayTime)
        .font(Theme.Font.caption)
        .fontWeight(.regular)
        .foregroundStyle(Theme.Ink.secondary)
        .monospacedDigit()
    }
    .fixedSize()
  }

  /// One sentence per row, in the order a reader would want it.
  private var accessibilityDescription: String {
    var parts: [String] = []
    if thread.isUnread { parts.append("Unread") }
    parts.append("from \(thread.displayName)")
    parts.append(thread.subject)
    if thread.messageCount > 1 { parts.append("\(thread.messageCount) messages") }
    if thread.hasAttachments { parts.append("has attachments") }
    parts.append(thread.displayTime)
    if thread.isStarred { parts.append("flagged") }
    if isSelected { parts.append("selected") }
    return parts.joined(separator: ", ")
  }
}
