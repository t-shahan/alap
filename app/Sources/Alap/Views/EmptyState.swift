import SwiftUI

/// A themed empty state.
///
/// Replaces `ContentUnavailableView`, which renders in SF Pro at roughly 34pt
/// bold with system colours — so it arrived louder than the reading-pane
/// subject it sat beside, in the wrong typeface, ignoring the palette. An empty
/// mailbox is the quietest thing in the app and was being announced like an
/// error.
///
/// It also always fills its container. `ContentUnavailableView` has an
/// intrinsic size, and in a `VStack` where nothing else expands the stack
/// shrinks to fit and SwiftUI centres the whole thing — which is what dragged
/// the message list's search field into the middle of the window whenever a
/// mailbox was empty.
///
/// ## Why it can teach the keyboard model
///
/// The reading pane's empty state is the largest region of the window and the
/// state a reader sees on every launch and after every archive-to-empty. A 28pt
/// glyph and two lines of text in a 1150×1500pt void is the app's best
/// available canvas saying nothing. `shortcuts` fills it with the one thing
/// that is useful in the exact moment there is nothing else to do: the
/// interaction model, which is otherwise discoverable only through the menu bar.
struct EmptyState: View {
  let title: String
  let message: String
  let symbol: String
  /// Optional call to action, for states the user can actually do something
  /// about.
  var actionTitle: String?
  var action: (() -> Void)?
  /// The keyboard model, shown where there is room for it. Empty by default —
  /// a 300pt message list is not the place to teach anything.
  var shortcuts: [KeyboardHint] = []

  var body: some View {
    VStack(spacing: Theme.Space.loose) {
      Image(systemName: symbol)
        .font(Theme.Icon.display)
        .foregroundStyle(Theme.Ink.tertiary)

      VStack(spacing: Theme.Space.tight) {
        // Serif: this is the app addressing the reader in a sentence, which is
        // the one thing the contrasting face is for. Everything operational
        // around it stays on SF.
        Text(title)
          .font(Theme.Font.displaySmall)
          .foregroundStyle(Theme.Ink.secondary)
        Text(message)
          .font(Theme.Font.small)
          .foregroundStyle(Theme.Ink.tertiary)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
      }

      if !shortcuts.isEmpty {
        KeyboardModel(hints: shortcuts)
          .padding(.top, Theme.Space.base)
      }

      if let actionTitle, let action {
        Button(action: action) {
          Text(actionTitle)
            .font(Theme.Font.body)
            .foregroundStyle(Theme.Accent.blueText)
            .padding(.horizontal, Theme.Space.wide)
            .padding(.vertical, Theme.Space.tight)
            .background(Theme.Accent.blueText.opacity(0.12),
                        in: .rect(cornerRadius: Theme.Radius.control))
        }
        .buttonStyle(.alap())
        .padding(.top, Theme.Space.tight)
      }
    }
    .padding(Theme.Space.pane)
    // Filling the container is what keeps surrounding chrome — the search
    // field, the toolbar — pinned where it belongs.
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    // The void arriving at full strength reads as a glitch when the last row is
    // archived. A beat of settle, not a celebration.
    .transition(.opacity)
  }
}

/// One line of the keyboard model.
struct KeyboardHint: Identifiable {
  var id: String { keys }
  let keys: String
  let action: String

  /// The triage loop, in the order a reader actually performs it.
  ///
  /// Deliberately not every binding in the app — a cheatsheet that lists
  /// twenty shortcuts teaches none of them. These five are the interaction
  /// model; the menu bar carries the rest.
  static let triage: [KeyboardHint] = [
    KeyboardHint(keys: "J K", action: "Next / previous conversation"),
    KeyboardHint(keys: "E", action: "Archive and move on"),
    KeyboardHint(keys: "S", action: "Flag"),
    KeyboardHint(keys: "U", action: "Mark unread"),
    KeyboardHint(keys: "/", action: "Search"),
  ]
}

/// The keyboard model, set as a two-column reading.
///
/// Keys on the left in a monospaced face because they are things you press, not
/// words you read; actions on the right in prose. Aligned as a table rather
/// than a list, which is what makes it scannable rather than merely present.
private struct KeyboardModel: View {
  let hints: [KeyboardHint]

  var body: some View {
    Grid(alignment: .leading, horizontalSpacing: Theme.Space.wide,
         verticalSpacing: Theme.Space.tight) {
      ForEach(hints) { hint in
        GridRow {
          Text(hint.keys)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(Theme.Ink.secondary)
            .padding(.horizontal, Theme.Space.base)
            .padding(.vertical, Theme.Space.hair)
            .background(Theme.Surface.control, in: .rect(cornerRadius: Theme.Radius.tight))
            .gridColumnAlignment(.trailing)
          Text(hint.action)
            .font(Theme.Font.small)
            .foregroundStyle(Theme.Ink.tertiary)
        }
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Keyboard shortcuts: "
      + hints.map { "\($0.keys), \($0.action)" }.joined(separator: ". "))
  }
}
