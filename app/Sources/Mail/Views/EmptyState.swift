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
struct EmptyState: View {
  let title: String
  let message: String
  let symbol: String
  /// Optional call to action, for states the user can actually do something
  /// about.
  var actionTitle: String?
  var action: (() -> Void)?

  var body: some View {
    VStack(spacing: Theme.Space.loose) {
      Image(systemName: symbol)
        .font(.system(size: 28, weight: .light))
        .foregroundStyle(Theme.Ink.tertiary)

      VStack(spacing: Theme.Space.tight) {
        Text(title)
          .font(Theme.Font.bodyEmphasis)
          .foregroundStyle(Theme.Ink.secondary)
        Text(message)
          .font(Theme.Font.small)
          .foregroundStyle(Theme.Ink.tertiary)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
      }

      if let actionTitle, let action {
        Button(action: action) {
          Text(actionTitle)
            .font(Theme.Font.body)
            .foregroundStyle(Theme.Accent.blue)
            .padding(.horizontal, Theme.Space.wide)
            .padding(.vertical, Theme.Space.snug)
            .background(Theme.Accent.blue.opacity(0.12),
                        in: .rect(cornerRadius: Theme.Radius.control))
        }
        .buttonStyle(.plain)
        .padding(.top, Theme.Space.tight)
      }
    }
    .padding(Theme.Space.pane)
    // Filling the container is what keeps surrounding chrome — the search
    // field, the toolbar — pinned where it belongs.
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
