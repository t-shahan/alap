import SwiftUI

/// What the reading pane shows while several conversations are selected.
///
/// ## Why here and not in the list
///
/// The first attempt put a bulk bar above the message list. That column is
/// 380pt wide, and a count plus four labelled buttons plus a close control is
/// roughly 500pt of content — so the labels wrapped character by character into
/// "Ar/chi/ve" and "Tra/sh".
///
/// Meanwhile the reading pane, over a thousand points of it, was showing "No
/// message selected" during precisely the operation that needed room. The space
/// was already there; it was being used to say that nothing was happening while
/// something was.
///
/// ## Why it previews what is selected
///
/// A bulk action is the one place in a mail client where a mistake is
/// multiplied. Confirming "2 selected" tells you a number; showing you that it
/// is HelloFresh and iCloud tells you whether it is the right two. That is the
/// difference between a count and a confirmation.
struct BulkActionPanel: View {
  @Bindable var store: MailStore

  /// Rows listed individually before collapsing to a summary line.
  ///
  /// Past a dozen the list stops being a check and starts being a wall — at
  /// that point the count is the more honest summary.
  private static let previewLimit = 12

  private var selected: [ThreadRow] { store.selectedThreads }

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Space.pane) {
      header
      preview
      actions
      Spacer(minLength: 0)
    }
    .padding(Theme.Space.pane)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: Theme.Space.base) {
      // Stays SF, deliberately. This is a *reading*, not the app presenting
      // someone's words — and serif digits would lose tabular figures, which
      // is the one thing a count in this app must keep.
      Text("\(store.selectionCount) conversations selected")
        .font(Theme.Font.title)
        .foregroundStyle(Theme.Ink.primary)
        .monospacedDigit()
        .contentTransition(.numericText(value: Double(store.selectionCount)))
        .animation(Theme.Motion.fade, value: store.selectionCount)

      Text(unreadSummary)
        .font(Theme.Font.body)
        .fontWeight(.regular)
        .foregroundStyle(Theme.Ink.secondary)
        .monospacedDigit()
    }
  }

  /// States what an action would actually change, not just how many rows there
  /// are — "mark read" over an already-read selection does nothing, and it is
  /// better to know that before clicking than after.
  private var unreadSummary: String {
    let unread = selected.filter(\.isUnread).count
    let flagged = selected.filter(\.isStarred).count

    var parts: [String] = []
    parts.append(unread == 0 ? "all read" : "\(unread) unread")
    if flagged > 0 { parts.append("\(flagged) flagged") }
    return parts.joined(separator: " · ")
  }

  private var preview: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(selected.prefix(Self.previewLimit)) { thread in
        HStack(spacing: Theme.Space.loose) {
          Circle()
            .fill(store.tint(forAccount: thread.accountId) ?? Theme.Accent.muted)
            .frame(width: 6, height: 6)

          Text(thread.displayName)
            .font(Theme.Font.body)
            .foregroundStyle(Theme.Ink.primary)
            .lineLimit(1)
            .frame(width: 160, alignment: .leading)

          Text(thread.subject)
            .font(Theme.Font.small)
            .foregroundStyle(Theme.Ink.secondary)
            .lineLimit(1)

          Spacer(minLength: Theme.Space.base)

          Text(thread.displayTime)
            .font(Theme.Font.micro)
            .fontWeight(.regular)
            .foregroundStyle(Theme.Ink.tertiary)
            .monospacedDigit()
        }
        .padding(.vertical, Theme.Space.tight)
        .padding(.horizontal, Theme.Space.loose)
      }

      if selected.count > Self.previewLimit {
        Text("and \(selected.count - Self.previewLimit) more")
          .font(Theme.Font.small)
          .foregroundStyle(Theme.Ink.tertiary)
          .padding(.vertical, Theme.Space.tight)
          .padding(.horizontal, Theme.Space.loose)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Theme.Surface.base, in: .rect(cornerRadius: Theme.Radius.panel))
    .overlay {
      RoundedRectangle(cornerRadius: Theme.Radius.panel)
        .strokeBorder(Theme.Surface.border, lineWidth: 1)
    }
  }

  private var actions: some View {
    // Wraps to a second row rather than compressing when the pane is narrow.
    // The previous bulk bar was an HStack that could not wrap, which is how its
    // labels ended up broken across lines.
    ViewThatFits(in: .horizontal) {
      actionRow
      VStack(alignment: .leading, spacing: Theme.Space.base) { actionRow }
    }
  }

  private var actionRow: some View {
    HStack(spacing: Theme.Space.loose) {
      BulkButton(title: "Archive", symbol: "archivebox", isProminent: true) {
        Task { await store.archiveSelection() }
      }
      BulkButton(title: markReadTitle, symbol: "envelope.open") {
        Task { await store.markSelectionRead() }
      }
      BulkButton(title: flagTitle, symbol: "flag") {
        Task { await store.toggleFlagOnSelection() }
      }

      Spacer()

      // Set apart from the others by distance as well as colour. It is the one
      // action here that is not trivially reversible from inside the app, and
      // it is about to happen to everything above.
      BulkButton(title: "Trash", symbol: "trash", tint: Theme.Accent.red) {
        Task { await store.trashSelection() }
      }

      Button("Deselect") { store.clearSelection() }
        .buttonStyle(.plain)
        .font(Theme.Font.body)
        .foregroundStyle(Theme.Ink.secondary)
    }
  }

  /// The label states the direction the action will actually take, since a
  /// mixed selection resolves to one of them rather than toggling each row.
  private var markReadTitle: String {
    selected.contains(where: \.isUnread) ? "Mark read" : "Mark unread"
  }

  private var flagTitle: String {
    selected.contains(where: { !$0.isStarred }) ? "Flag" : "Unflag"
  }
}

private struct BulkButton: View {
  let title: String
  let symbol: String
  var tint: Color = Theme.Ink.primary
  var isProminent: Bool = false
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: Theme.Space.base) {
        Image(systemName: symbol).font(Theme.Icon.medium)
        // Never wraps. The previous version wrapped mid-word because it was
        // laid out in a column too narrow to hold it.
        Text(title).font(Theme.Font.bodyEmphasis).fixedSize()
      }
      // A tint only where the role does not already decide one: prominent gets
      // white from the style, and the two neutral buttons keep their ink.
      .foregroundStyle(isProminent ? AnyShapeStyle(Color.white) : AnyShapeStyle(tint))
      .padding(.horizontal, Theme.Space.wide)
      .frame(height: 34)
    }
    // Hover used to be `blue.opacity(0.85)` here and `control.opacity(0.6)`
    // there — two more of the nine different answers the app had for the same
    // question. Both are the shared overlay tints now.
    .buttonStyle(.alap(isProminent ? .primary : .secondary))
  }
}
