import Observation
import SwiftUI

/// The three appearances the app ships with.
///
/// `signature` is the default and the designed one. The other two exist because
/// a mail client is something people keep open all day, and "match my system"
/// and "match my room" are both legitimate reasons to want something else.
enum AppTheme: String, CaseIterable, Identifiable, Sendable {
  /// Cool navy, derived from the app icon. The default.
  case signature
  /// Neutral dark — the original Figma greys, with no hue at all.
  case dark
  /// Light.
  case light

  var id: String { rawValue }

  var title: String {
    switch self {
    case .signature: "Signature"
    case .dark: "Dark"
    case .light: "Light"
    }
  }

  var subtitle: String {
    switch self {
    case .signature: "Cool navy, matched to the app icon"
    case .dark: "Neutral dark"
    case .light: "Light"
    }
  }

  var isDark: Bool { self != .light }

  /// Drives `preferredColorScheme`, so AppKit's own chrome — scrollbars, the
  /// text cursor, focus rings, `ProgressView` — matches the palette. Without
  /// this the app's surfaces go dark while its scrollbars stay light.
  var colorScheme: ColorScheme { isDark ? .dark : .light }

  var symbol: String {
    switch self {
    case .signature: "envelope.fill"
    case .dark: "moon.fill"
    case .light: "sun.max.fill"
    }
  }
}

/// Every colour token, for one appearance.
///
/// A flat struct rather than nested types so a palette is a single value that
/// can be swapped atomically — the alternative, scattering `if theme ==` across
/// the tokens, is how one surface ends up left behind on a rename.
struct Palette: Sendable {
  let base: Color
  let sunken: Color
  let raised: Color
  let control: Color
  let selection: Color
  let border: Color

  let inkPrimary: Color
  let inkSecondary: Color
  let inkTertiary: Color

  let accentBlue: Color
  let accentRed: Color
  let accentFlag: Color
  let accentMuted: Color
  let accentMutedFill: Color
  let accentOk: Color
}

extension Palette {
  /// Cool navy, derived from the app icon.
  ///
  /// Sampling the icon gives one unambiguous signature: every colour sits on a
  /// cool axis, blue above green above red by a consistent step — ground at
  /// #101820, line work at #e0e0e8. The Figma surfaces were true neutrals
  /// (#161617, R=G=B), so icon and window read as two different products
  /// sitting next to each other in the Dock.
  ///
  /// These are those same Figma values rotated onto the icon's axis: for grey
  /// level `g`, the channels become `(g-8, g, g+8)`. LUMINANCE IS PRESERVED,
  /// which is the whole point — the steps between base, sunken, raised and
  /// control keep their exact relationships, so no pane changes apparent weight
  /// and the design's sense of depth is untouched. Only the hue moves.
  static let signature = Palette(
    // #0e161e lands within two points of the icon's dominant ground.
    base: Color(hex: 0x0E161E),
    sunken: Color(hex: 0x161E26),
    raised: Color(hex: 0x192129),
    control: Color(hex: 0x252D35),
    // The one place the design already let blue into a surface, so it is kept
    // exactly rather than recomputed.
    selection: Color(hex: 0x1F2C3F),
    border: Color(hex: 0x323A42),
    // The icon's line work is #e0e0e8 — cool near-white, not pure white. Text
    // at #ffffff over a navy ground reads harsh and faintly blue-shifted;
    // matching the icon settles it at no cost to contrast.
    inkPrimary: Color(hex: 0xE9ECF3),
    inkSecondary: Color(hex: 0xEBEBF5, alpha: 0.60),
    // See the note on `Palette.dark.inkTertiary` for why this is not 0.30.
    inkTertiary: Color(hex: 0xEBEBF5, alpha: 0.51),
    accentBlue: Color(hex: 0x0A84FF),
    accentRed: Color(hex: 0xFF453A),
    accentFlag: Color(hex: 0xFF9F0A),
    accentMuted: Color(hex: 0x6B7280),
    accentMutedFill: Color(hex: 0x6B7280, alpha: 0.13),
    accentOk: Color(hex: 0x4CB06E)
  )

  /// Neutral dark — the original Figma values, unrotated.
  ///
  /// Kept as a real option rather than deleted: the signature palette is a
  /// deliberate tint, and some people simply do not want one.
  static let dark = Palette(
    base: Color(hex: 0x161617),
    sunken: Color(hex: 0x1E1E20),
    raised: Color(hex: 0x212124),
    control: Color(hex: 0x2C2C2E),
    selection: Color(hex: 0x2A2A2D),
    border: Color(hex: 0x3A3A3C),
    inkPrimary: Color(hex: 0xFFFFFF),
    inkSecondary: Color(hex: 0xEBEBF5, alpha: 0.60),
  /// Tertiary is 0.51, not the design's 0.30.
  ///
  /// At 0.30 it measures 2.46:1 against the surfaces below — under even the
  /// 3.0 floor for large text, and it is used for section headers, timestamps
  /// and placeholders at 11–12pt, which are not large text. 0.51 is the lowest
  /// value that clears 4.5:1 on the darkest surface this palette uses.
  ///
  /// This costs a little of the design's quietness, and it is still visibly
  /// the third level: secondary sits at ~6:1 against tertiary's ~4.6:1.
    inkTertiary: Color(hex: 0xEBEBF5, alpha: 0.51),
    accentBlue: Color(hex: 0x0A84FF),
    accentRed: Color(hex: 0xFF453A),
    accentFlag: Color(hex: 0xFF9F0A),
    accentMuted: Color(hex: 0x6B7280),
    accentMutedFill: Color(hex: 0x6B7280, alpha: 0.13),
    accentOk: Color(hex: 0x4CB06E)
  )

  /// Light.
  ///
  /// Carries a trace of the same cool axis so the app still relates to its
  /// icon, but far weaker: at high lightness a tint that reads as "considered"
  /// in the dark reads as "slightly dirty" instead.
  ///
  /// Accents are darkened rather than reused. #0a84ff on white is a
  /// well-known legibility failure — it passes for large text and fails for
  /// the 12–13pt this interface is mostly made of.
  static let light = Palette(
    base: Color(hex: 0xFFFFFF),
    sunken: Color(hex: 0xF1F4F8),
    raised: Color(hex: 0xFAFBFD),
    control: Color(hex: 0xE6EAF0),
    selection: Color(hex: 0xD8E6FA),
    border: Color(hex: 0xD3DAE3),
    inkPrimary: Color(hex: 0x0D141C),
    // 0.65/0.55 rather than the dark palettes' 0.60/0.51: black over white
    // gains contrast faster than white over near-black, so matching the alphas
    // would leave these two levels barely a point apart and the hierarchy flat.
    inkSecondary: Color(hex: 0x000000, alpha: 0.65),
    inkTertiary: Color(hex: 0x000000, alpha: 0.55),
    accentBlue: Color(hex: 0x0A6FE8),
    accentRed: Color(hex: 0xD70015),
    accentFlag: Color(hex: 0xE8912D),
    accentMuted: Color(hex: 0x5F6772),
    accentMutedFill: Color(hex: 0x6B7280, alpha: 0.13),
    accentOk: Color(hex: 0x2E8B4F)
  )

  static func `for`(_ theme: AppTheme) -> Palette {
    switch theme {
    case .signature: .signature
    case .dark: .dark
    case .light: .light
    }
  }
}

/// Holds the selected appearance.
///
/// A singleton rather than an environment value on purpose. Every token below
/// is reached as `Theme.Surface.base` from roughly two hundred call sites;
/// threading an environment value through all of them would be a large,
/// entirely mechanical change with real risk of missing one and leaving a
/// stranded colour.
///
/// This works because `@Observable` tracks property *access*. SwiftUI evaluates
/// a view's `body` inside an observation scope, so reading `Theme.Surface.base`
/// — even through a static property — registers the dependency and the view
/// re-renders when the theme changes.
@MainActor
@Observable
final class ThemeController {
  static let shared = ThemeController()

  private static let defaultsKey = "app.theme"

  var theme: AppTheme {
    didSet {
      guard theme != oldValue else { return }
      UserDefaults.standard.set(theme.rawValue, forKey: Self.defaultsKey)
    }
  }

  var palette: Palette { Palette.for(theme) }

  private init() {
    let stored = UserDefaults.standard.string(forKey: Self.defaultsKey)
    // Unknown or absent falls back to the designed default rather than to the
    // system appearance: `signature` is the app's identity, not a preference.
    theme = stored.flatMap(AppTheme.init(rawValue:)) ?? .signature
  }
}

/// Design tokens, taken from the `email-app-dark` Figma frame.
///
/// ## Source of truth
///
/// Sizes and type are transcribed from Figma node `3:4`; colours resolve
/// through the selected `AppTheme`. Nothing else in the app should contain a
/// raw colour or size.
enum Theme {
  @MainActor
  private static var palette: Palette { ThemeController.shared.palette }

  // MARK: - Surfaces
  //
  // Four levels, deliberately close together. The separation between panes is
  // carried by these steps rather than by dividers, which is what keeps the
  // interface quiet.

  @MainActor
  enum Surface {
    /// App background and the message list.
    static var base: Color { Theme.palette.base }
    /// Sidebar and quick-reply pane.
    static var sunken: Color { Theme.palette.sunken }
    /// Reading pane.
    static var raised: Color { Theme.palette.raised }
    /// Controls: New Message, selected sidebar item, attachment chips.
    static var control: Color { Theme.palette.control }
    /// Selected message row.
    static var selection: Color { Theme.palette.selection }
    /// Control border.
    static var border: Color { Theme.palette.border }
  }

  // MARK: - Text
  //
  // Three levels, which is how the design keeps hierarchy without introducing
  // more hues.

  @MainActor
  enum Ink {
    static var primary: Color { Theme.palette.inkPrimary }
    static var secondary: Color { Theme.palette.inkSecondary }
    static var tertiary: Color { Theme.palette.inkTertiary }
  }

  // MARK: - Accents
  //
  // Colour is scarce and each one means something. These are NOT tinted toward
  // the icon: blue means "action", red means "destructive", orange means
  // "flagged". Those carry meaning rather than identity, and shifting them
  // would cost legibility to buy nothing.

  @MainActor
  enum Accent {
    static var blue: Color { Theme.palette.accentBlue }
    static var red: Color { Theme.palette.accentRed }
    static var flag: Color { Theme.palette.accentFlag }
    /// Neutral chip colour used for badges, the avatar and secondary buttons.
    static var muted: Color { Theme.palette.accentMuted }
    /// 13% muted — avatar and secondary button fills.
    static var mutedFill: Color { Theme.palette.accentMutedFill }
    static var ok: Color { Theme.palette.accentOk }
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

// MARK: - Colour literals

extension Color {
  /// `0xRRGGBB`, with optional alpha.
  init(hex: UInt32, alpha: Double = 1) {
    self.init(
      .sRGB,
      red: Double((hex >> 16) & 0xFF) / 255,
      green: Double((hex >> 8) & 0xFF) / 255,
      blue: Double(hex & 0xFF) / 255,
      opacity: alpha
    )
  }
}
