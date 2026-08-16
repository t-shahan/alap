import SwiftUI

/// Design tokens.
///
/// ## Direction
///
/// Quiet editorial. The product problem is visual clutter during triage, so
/// hierarchy comes from **type scale and whitespace**, not from borders, fills
/// and chrome. Almost everything is monochrome; colour is reserved for meaning
/// — unread, starred, account identity, sync failure — so that when something
/// is coloured, it is worth looking at.
///
/// ## Why this file exists
///
/// Previously every size and colour was an inline literal scattered across
/// three view structs, and the palette was whatever macOS happened to supply.
/// That is a default, not a decision. These tokens are chosen, defined for
/// both appearances, and referenced by name.
enum Theme {

  // MARK: - Type scale
  //
  // A 1.25 ratio anchored at 13pt, macOS's natural body size. The jump from
  // list (13) to reading pane (25) is deliberate and large: it is the single
  // strongest signal that you have moved from scanning to reading.

  enum Font {
    /// Sidebar section headers, timestamps, metadata.
    static let caption = SwiftUI.Font.system(size: 11, weight: .regular)
    /// Snippets and secondary lines.
    static let small = SwiftUI.Font.system(size: 12, weight: .regular)
    /// Default body size — list rows, sidebar labels.
    static let body = SwiftUI.Font.system(size: 13, weight: .regular)
    /// Sender names and other emphasised list content.
    static let bodyEmphasis = SwiftUI.Font.system(size: 13, weight: .semibold)
    /// Message body in the reading pane. Slightly larger, for sustained reading.
    static let reading = SwiftUI.Font.system(size: 14, weight: .regular)
    /// Reading-pane subject.
    static let title = SwiftUI.Font.system(size: 25, weight: .semibold)

    /// Message bodies that arrived as plain text keep their own wrapping and
    /// alignment, so they need a monospaced face to stay legible.
    static let monospacedBody = SwiftUI.Font.system(size: 13, design: .monospaced)
  }

  // MARK: - Spacing
  //
  // A 4pt grid. Rhythm is intentionally uneven: tight within a row, generous
  // between regions. Uniform padding everywhere reads as a template.

  enum Space {
    static let hair: CGFloat = 2
    static let tight: CGFloat = 4
    static let snug: CGFloat = 8
    static let base: CGFloat = 12
    static let loose: CGFloat = 16
    static let section: CGFloat = 24
    /// Reading-pane margins. Deliberately larger than anything else in the app.
    static let reading: CGFloat = 32
  }

  // MARK: - Colour
  //
  // Defined for both appearances rather than inherited. Each has a stated job;
  // anything decorative would undermine the ones that carry meaning.

  enum Palette {
    /// Unread, selection, primary action.
    static let accent = Color.accentColor
    /// Starred. The one warm colour in the app.
    static let star = Color(light: .init(hex: 0xE8912D), dark: .init(hex: 0xF0A94A))
    /// Sync failure, permanently failed outbox rows.
    static let alert = Color(light: .init(hex: 0xC5372C), dark: .init(hex: 0xE05A4E))
    /// Healthy sync.
    static let ok = Color(light: .init(hex: 0x2E8B4F), dark: .init(hex: 0x4CB06E))

    static let primaryText = Color.primary
    static let secondaryText = Color.secondary
    /// Hairlines. Barely visible on purpose — structure without weight.
    static let divider = Color(light: .init(white: 0, opacity: 0.08),
                               dark: .init(white: 1, opacity: 0.10))
  }

  // MARK: - Motion
  //
  // Motion clarifies where things went; it never decorates. Anything longer
  // than ~250ms during triage feels like latency.

  enum Motion {
    static let quick = Animation.easeOut(duration: 0.12)
    static let standard = Animation.easeOut(duration: 0.2)
  }

  /// Unread indicator dot. Small enough to stay quiet, present enough to scan.
  static let unreadDot: CGFloat = 6
}

// MARK: - Appearance-aware colour

extension Color {
  /// Builds a colour that differs by appearance.
  ///
  /// SwiftUI has no built-in light/dark literal on macOS, so this drops to
  /// `NSColor`'s dynamic provider. Defining both means neither appearance is
  /// an accident.
  init(light: NSColor, dark: NSColor) {
    self.init(nsColor: NSColor(name: nil) { appearance in
      appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
    })
  }
}

extension NSColor {
  /// `0xRRGGBB`.
  convenience init(hex: UInt32) {
    self.init(
      srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
      green: CGFloat((hex >> 8) & 0xFF) / 255,
      blue: CGFloat(hex & 0xFF) / 255,
      alpha: 1
    )
  }

  convenience init(white: CGFloat, opacity: CGFloat) {
    self.init(white: white, alpha: opacity)
  }
}
