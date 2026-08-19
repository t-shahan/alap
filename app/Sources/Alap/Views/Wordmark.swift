import SwiftUI

/// The app's name, set as a mark rather than as a label.
///
/// ## The space it fills
///
/// The sidebar reserved a 28pt band at its top and put nothing in it. The
/// reservation was for the traffic lights, and it was already redundant: the
/// window hides its title bar, so AppKit insets the whole content view past
/// the lights on its own and the band sat entirely BELOW them — 28pt of
/// sunken surface, the full width of the pane, holding nothing. The band is
/// kept at exactly its old height so nothing below it moves; only its content
/// changes.
///
/// ## Why it reads as a mark
///
/// Every other string in this window is SF, and the one exception —
/// `Theme.Font.display` — is New York on the reading pane's subject. So a
/// serif in the navigation pane is already unlike anything around it, which
/// is most of the work. The rest is done by three things that a label would
/// not have: primary ink where the neighbouring section headers are tertiary,
/// a little positive tracking, and the rule.
///
/// The rule is the masthead device — the name sits on a line that runs out
/// toward the pane edge and fades. It fades on purpose: a hairline at constant
/// weight running to the trailing edge would read as a divider, and this pane
/// already has one down its trailing seam doing a structural job. A rule that
/// dissolves cannot be mistaken for structure.
///
/// ## One site
///
/// `AppIdentity.name` rather than the literal, because the identity's whole
/// reason for existing is that a rename must not half-land. If the wordmark
/// ever appears somewhere else, the app has two mastheads.
struct Wordmark: View {
  var body: some View {
    // Baseline alignment, so the rule leaves the name at the feet of the
    // letters rather than crossing them. A shape has no text baseline, so
    // SwiftUI aligns the rule's bottom edge — which is what is wanted here and
    // is why the rule is 1pt of gradient rather than a `Divider`.
    HStack(alignment: .firstTextBaseline, spacing: Theme.Space.base) {
      Text(AppIdentity.name)
        .font(Theme.Font.wordmark)
        .tracking(0.6)
        .foregroundStyle(Theme.Ink.primary)
        // The one string in the app that must never be shortened.
        .fixedSize()

      rule
    }
    // Aligns with the section headers and every row label below it: the
    // sidebar's own 8pt inset plus a row's 12pt.
    .padding(.horizontal, Theme.Space.loose)
    .frame(height: Theme.Size.masthead)
    // One VoiceOver stop, and a heading — it is what a reader lands on first
    // in this pane, and "Alap, heading" orients them before the controls.
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isHeader)
  }

  private var rule: some View {
    LinearGradient(
      colors: [Theme.Surface.border.opacity(0.6), Theme.Surface.border.opacity(0)],
      startPoint: .leading,
      endPoint: .trailing
    )
    .frame(height: 1)
  }
}

extension View {
  /// Puts the wordmark in the band above a pane's content.
  ///
  /// A `safeAreaInset` rather than a first child of the pane's stack: the
  /// masthead has to stay put while everything under it scrolls, and it
  /// replaces a reservation that was already an inset, so the pane's content
  /// keeps the exact vertical position it had.
  ///
  /// Applied by the sidebar, which is the leftmost pane whenever it exists.
  /// Below 780pt it does not, and the app's name is then carried by the Dock
  /// and the menu bar rather than by a pane with no room for it.
  @MainActor
  func masthead() -> some View {
    safeAreaInset(edge: .top, spacing: 0) { Wordmark() }
  }
}
