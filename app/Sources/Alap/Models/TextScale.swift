import SwiftUI

/// How much the reader has asked text to grow.
///
/// ## Why only the message body scales
///
/// A2 called the app's fixed type sizes a Dynamic Type failure, which is the
/// right diagnosis on iOS and the wrong frame for this platform. macOS does not
/// broadcast a text size to every app: `com.apple.universalaccess`'s
/// `FontSizeCategory` is an **opt-in allowlist keyed by bundle id** — Mail,
/// Messages, Notes, Finder, Calendar and a handful of others, each `UseGlobal`,
/// against a `global` default. An app participates by adopting scalable type
/// and then appearing in System Settings › Accessibility › Display › Text size.
/// A reader who needs everything bigger reaches for Zoom, which is pixel
/// scaling and works no matter how an app specifies its fonts.
///
/// So the honest scope is the surface where the preference actually earns its
/// keep: **the message**. That is the text someone sits and reads, it is
/// already laid out by WebKit rather than by our own fixed-height chrome, and
/// scaling it collides with nothing.
///
/// The chrome deliberately does NOT scale. `RowAnatomy` fixes row heights per
/// density so `List` gets a constant row height, and every toolbar and field in
/// the app is a fixed height chosen against those. Growing the type inside them
/// without growing them is how a label ends up clipped by its own button; doing
/// both is a different change, and a large one — see the note in `RowAnatomy`.
enum TextScale {
  /// The design size. Everything is authored against this.
  static let reference: Double = 1

  /// A multiplier for the message document's own type.
  ///
  /// Deliberately gentler than the type-size steps themselves. The message is
  /// a sender's layout, frequently a table with pixel widths, and scaling it
  /// aggressively does not enlarge the reading — it pushes the document past
  /// the pane and hands it to the fit pass, which scales the whole thing back
  /// down. Growing type into a fixed-width canvas has a ceiling, and going
  /// past it makes the text SMALLER.
  static func multiplier(for size: DynamicTypeSize) -> Double {
    switch size {
    case .xSmall: 0.85
    case .small: 0.92
    case .medium: 0.96
    case .large: 1.00          // the default
    case .xLarge: 1.08
    case .xxLarge: 1.16
    case .xxxLarge: 1.24
    // The five accessibility sizes share a ceiling for the reason above: past
    // roughly 1.4 the fit pass claws back more than the scale adds.
    default: 1.40
    }
  }
}
