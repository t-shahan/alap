import SwiftUI

/// Design tokens, taken from the `email-app-dark` Figma frame.
///
/// ## Source of truth
///
/// Values here are transcribed from Figma node `3:4`. When the design changes,
/// change them here — nothing else in the app should contain a raw colour or
/// size.
///
/// ## Dark-first
///
/// The design is dark-only, and its palette is specific: four near-black
/// surfaces separated by a few points of lightness, which is what gives the
/// panes their sense of depth without any borders. Light values are derived
/// counterparts so the app does not break in a light appearance, but dark is
/// the designed one.
enum Theme {

  // MARK: - Surfaces
  //
  // Four levels, deliberately close together. The separation between panes is
  // carried by these steps rather than by dividers, which is what keeps the
  // interface quiet.

  enum Surface {
    /// App background and the message list. Figma #161617.
    static let base = Color(light: .init(hex: 0xFFFFFF), dark: .init(hex: 0x161617))
    /// Sidebar and quick-reply pane. Figma #1e1e20.
    static let sunken = Color(light: .init(hex: 0xF2F2F4), dark: .init(hex: 0x1E1E20))
    /// Reading pane. Figma #212124.
    static let raised = Color(light: .init(hex: 0xFAFAFB), dark: .init(hex: 0x212124))
    /// Controls: New Message, selected sidebar item, attachment chips. #2c2c2e.
    static let control = Color(light: .init(hex: 0xE8E8EA), dark: .init(hex: 0x2C2C2E))
    /// Selected message row. Figma #1f2c3f — a desaturated blue, not the accent.
    static let selection = Color(light: .init(hex: 0xD8E6FA), dark: .init(hex: 0x1F2C3F))
    /// Control border. Figma #3a3a3c.
    static let border = Color(light: .init(hex: 0xD4D4D8), dark: .init(hex: 0x3A3A3C))
  }

  // MARK: - Text
  //
  // Three levels via opacity on a single near-white, which is how the design
  // keeps hierarchy without introducing more hues.

  enum Ink {
    static let primary = Color(light: .init(hex: 0x111114), dark: .init(hex: 0xFFFFFF))
    /// Figma rgba(235,235,245,0.6).
    static let secondary = Color(
      light: .init(white: 0, opacity: 0.55), dark: .init(hex: 0xEBEBF5, alpha: 0.6))
    /// Figma rgba(235,235,245,0.3) — section headers, timestamps in the pane.
    static let tertiary = Color(
      light: .init(white: 0, opacity: 0.35), dark: .init(hex: 0xEBEBF5, alpha: 0.3))
  }

  // MARK: - Accents
  //
  // Colour is scarce and each one means something.

  enum Accent {
    /// Primary action and selection. Figma #0a84ff.
    static let blue = Color(light: .init(hex: 0x0A6FE8), dark: .init(hex: 0x0A84FF))
    /// Destructive. Figma #ff453a.
    static let red = Color(light: .init(hex: 0xD70015), dark: .init(hex: 0xFF453A))
    /// Flag / starred. Figma uses orange for the row flag.
    static let flag = Color(light: .init(hex: 0xE8912D), dark: .init(hex: 0xFF9F0A))
    /// Neutral chip colour used for badges, the avatar and secondary buttons.
    /// Figma #6b7280.
    static let muted = Color(light: .init(hex: 0x6B7280), dark: .init(hex: 0x6B7280))
    /// 13% muted — avatar and secondary button fills.
    static let mutedFill = Color(light: .init(hex: 0x6B7280, alpha: 0.13),
                                 dark: .init(hex: 0x6B7280, alpha: 0.13))
    static let ok = Color(light: .init(hex: 0x2E8B4F), dark: .init(hex: 0x4CB06E))
  }

  // MARK: - Type
  //
  // The design specifies Inter. Inter is not a system font on macOS, so this
  // resolves to it when installed and falls back to the system face otherwise —
  // which is very close at these sizes and avoids shipping a font binary.

  enum Font {
    /// Badges and attachment sizes. 10pt.
    static let micro = font(10, .semibold)
    /// Section headers (MAILBOXES), timestamps, "Select All". 11pt.
    static let caption = font(11, .semibold)
    /// Row subject and snippet. 12pt.
    static let small = font(12, .regular)
    static let smallEmphasis = font(12, .semibold)
    /// Default UI: sidebar items, sender names, buttons. 13pt.
    static let body = font(13, .medium)
    static let bodyEmphasis = font(13, .semibold)
    static let bodyStrong = font(13, .bold)
    /// Message body and avatar initials. 14pt.
    static let reading = font(14, .regular)
    /// Reading-pane subject. 20pt.
    static let title = font(20, .bold)

    private static func font(_ size: CGFloat, _ weight: SwiftUI.Font.Weight) -> SwiftUI.Font {
      .custom("Inter", size: size).weight(weight)
    }
  }

  // MARK: - Spacing
  //
  // The design sits on a 4pt grid, with pane padding at 12/16/24.

  enum Space {
    static let hair: CGFloat = 2
    static let tight: CGFloat = 4
    static let snug: CGFloat = 6
    static let base: CGFloat = 8
    static let cosy: CGFloat = 10
    static let loose: CGFloat = 12
    static let wide: CGFloat = 16
    static let section: CGFloat = 20
    static let pane: CGFloat = 24
    /// Row text is indented past the dot and checkbox. Figma pl-[30px].
    static let rowIndent: CGFloat = 30
  }

  enum Radius {
    static let checkbox: CGFloat = 3
    static let control: CGFloat = 6
    static let panel: CGFloat = 8
    static let badge: CGFloat = 10
    static let window: CGFloat = 12
    static let avatar: CGFloat = 18
  }

  enum Size {
    static let sidebar: CGFloat = 220
    static let list: CGFloat = 380
    static let icon: CGFloat = 16
    static let smallIcon: CGFloat = 14
    static let unreadDot: CGFloat = 8
    static let flagIcon: CGFloat = 12
    static let avatar: CGFloat = 36
    static let rowHeight: CGFloat = 32
    static let toolbar: CGFloat = 48
  }

  enum Motion {
    static let quick = Animation.easeOut(duration: 0.12)
    static let standard = Animation.easeOut(duration: 0.2)
  }
}

// MARK: - Appearance-aware colour

extension Color {
  /// Builds a colour that differs by appearance.
  ///
  /// SwiftUI has no light/dark literal on macOS, so this drops to `NSColor`'s
  /// dynamic provider. Defining both means neither appearance is an accident.
  init(light: NSColor, dark: NSColor) {
    self.init(nsColor: NSColor(name: nil) { appearance in
      appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
    })
  }
}

extension NSColor {
  /// `0xRRGGBB`, with optional alpha.
  convenience init(hex: UInt32, alpha: CGFloat = 1) {
    self.init(
      srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
      green: CGFloat((hex >> 8) & 0xFF) / 255,
      blue: CGFloat(hex & 0xFF) / 255,
      alpha: alpha
    )
  }

  convenience init(white: CGFloat, opacity: CGFloat) {
    self.init(white: white, alpha: opacity)
  }
}
