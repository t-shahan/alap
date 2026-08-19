import AppKit
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

  /// Shown by the switcher, which displays the theme it will move TO.
  ///
  /// Signature was an `envelope.fill`. An envelope glyph in a mail app's status
  /// corner reads as "mail", not "appearance" — the half-filled circle is the
  /// platform's own idiom for a light/dark choice and carries no other meaning
  /// here.
  var symbol: String {
    switch self {
    case .signature: "circle.lefthalf.filled"
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
///
/// ## Two floors, stated rather than implied
///
/// Every value here is governed by one of exactly two contrast floors, and
/// which one is part of the token's identity:
///
///   - **4.5:1 (WCAG 1.4.3)** for anything that renders as *text* under 18pt:
///     the ink levels, `accentBlueText`, `accentMutedInk`, `accentOk`.
///   - **3:1 (WCAG 1.4.11)** for graphical objects: `accentFlag`, the unread
///     dot, `borderStrong`, the focus ring.
///
/// The floor is measured against the **worst surface the token can land on**,
/// which is the *lightest* surface on a dark palette and the *darkest* on a
/// light one. Reasoning against `base` alone is the methodological error that
/// let six failures ship — see `tools/palette-audit/contrast.py`, which
/// recomputes every figure below, and `ThemeTests` which gates them.
///
/// Fill colours and foreground colours are separate tokens even where they are
/// the same hue: `accentBlue` is a fill with a white label on it, `accentBlueText`
/// is blue drawn AS text on a surface, and no value can do both jobs.
struct Palette: Sendable {
  let base: Color
  let sunken: Color
  let raised: Color
  let control: Color
  let selection: Color
  /// Decorative hairline between surfaces. Below 3:1 by design, and therefore
  /// never load-bearing — use `borderStrong` for an outline that means something.
  let border: Color
  /// Meaningful outlines: focus rings, hover borders, anything a reader has to
  /// SEE rather than merely be separated by. Clears the 3:1 graphical floor.
  let borderStrong: Color

  let inkPrimary: Color
  let inkSecondary: Color
  let inkTertiary: Color
  /// Inert but still legible, ~2.8-3.2:1. Replaces `tertiary.opacity(0.4)`,
  /// which measured 1.77:1 — below the point where a glyph's shape can be made
  /// out at all.
  let inkDisabled: Color

  /// Filled controls. A white label sits on this, so it is tuned to be written
  /// on rather than to be seen.
  let accentBlue: Color
  /// Blue used AS TEXT on a surface. Lighter on the dark palettes, darker on
  /// light — a fill colour and a text colour are not the same colour even when
  /// they are the same hue.
  let accentBlueText: Color
  let accentRed: Color
  /// Graphical only, 3:1 floor. No orange that still reads as orange clears
  /// 4.5:1 on a light surface, so the flag must never carry text and must stay
  /// distinguishable by shape.
  let accentFlag: Color
  /// Neutral fill.
  let accentMuted: Color
  /// Neutral AS TEXT — the avatar initials, which measured 2.93:1 against the
  /// fill token and were the worst text contrast in the app.
  let accentMutedInk: Color
  let accentMutedFill: Color
  let accentOk: Color

  /// Overlay tints for interaction, layered ON a control's own surface so they
  /// compose correctly against any of them.
  let stateHover: Color
  let statePressed: Color

  /// Shadows are tinted toward the palette rather than pure black: black at 30%
  /// is correct on a near-black ground and reads as grey smudge on white.
  let shadowColor: Color
  /// Multiplies every `Elevation` token's opacity. Light interfaces carry far
  /// less shadow for the same apparent lift.
  let shadowStrength: Double
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
    // 3.25:1 worst case, on the same cool axis as the surfaces.
    borderStrong: Color(hex: 0x737B83),
    // The icon's line work is #e0e0e8 — cool near-white, not pure white. Text
    // at #ffffff over a navy ground reads harsh and faintly blue-shifted;
    // matching the icon settles it at no cost to contrast.
    inkPrimary: Color(hex: 0xE9ECF3),
    inkSecondary: Color(hex: 0xEBEBF5, alpha: 0.60),
    // See the note on `Palette.dark.inkTertiary` for why this is 0.56.
    inkTertiary: Color(hex: 0xEBEBF5, alpha: 0.56),
    inkDisabled: Color(hex: 0xEBEBF5, alpha: 0.36),
    accentBlue: Color(hex: 0x0B62D6),
    accentBlueText: Color(hex: 0x4DA3FF),
    accentRed: Color(hex: 0xFF453A),
    accentFlag: Color(hex: 0xFF9F0A),
    accentMuted: Color(hex: 0x6B7280),
    accentMutedInk: Color(hex: 0x9AA3B2),
    accentMutedFill: Color(hex: 0x6B7280, alpha: 0.13),
    accentOk: Color(hex: 0x4CB06E),
    stateHover: Color(hex: 0xFFFFFF, alpha: 0.06),
    statePressed: Color(hex: 0xFFFFFF, alpha: 0.11),
    shadowColor: Color(hex: 0x03070B),
    shadowStrength: 1.0
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
    borderStrong: Color(hex: 0x7A7A7C),
    inkPrimary: Color(hex: 0xFFFFFF),
    inkSecondary: Color(hex: 0xEBEBF5, alpha: 0.60),
  /// Tertiary is 0.56, not the design's 0.30.
  ///
  /// At 0.30 it measures 2.46:1 against the surfaces below — under even the
  /// 3.0 floor for large text, and it is used for section headers, timestamps
  /// and placeholders at 11–12pt, which are not large text.
  ///
  /// It was 0.51, chosen as "the lowest value that clears 4.5:1 on the DARKEST
  /// surface this palette uses". That reasoning is inverted: on a dark palette
  /// the *lightest* surface is the worst case, and tertiary is drawn on
  /// `control` and `selection` — where 0.51 measured 4.24:1 and 4.25:1. 0.56
  /// is the lowest value that clears 4.5:1 on all five drawable surfaces.
  ///
  /// This costs a little of the design's quietness, and it is still visibly
  /// the third level: secondary sits at ~5.3:1 against tertiary's ~4.8:1.
    inkTertiary: Color(hex: 0xEBEBF5, alpha: 0.56),
    inkDisabled: Color(hex: 0xEBEBF5, alpha: 0.36),
    accentBlue: Color(hex: 0x0B62D6),
    accentBlueText: Color(hex: 0x4DA3FF),
    accentRed: Color(hex: 0xFF453A),
    accentFlag: Color(hex: 0xFF9F0A),
    accentMuted: Color(hex: 0x6B7280),
    accentMutedInk: Color(hex: 0x9AA3B2),
    accentMutedFill: Color(hex: 0x6B7280, alpha: 0.13),
    accentOk: Color(hex: 0x4CB06E),
    stateHover: Color(hex: 0xFFFFFF, alpha: 0.06),
    statePressed: Color(hex: 0xFFFFFF, alpha: 0.11),
    shadowColor: Color(hex: 0x000000),
    shadowStrength: 1.0
  )

  /// Light, with elevation running the way light interfaces actually use it.
  ///
  /// Carries a trace of the same cool axis so the app still relates to its
  /// icon, but far weaker: at high lightness a tint that reads as "considered"
  /// in the dark reads as "slightly dirty" instead.
  ///
  /// ## Why the ramp is inverted
  ///
  /// It used to copy the dark palettes' direction — `base` white, `raised`
  /// nearly white — which left the list and the reading pane **1.04:1** apart.
  /// The three-pane structure the whole layout depends on simply did not exist
  /// in this theme; the boundary was invisible except where row content
  /// happened to stop. In a light interface elevation runs the other way: the
  /// app background is a tinted grey and raised surfaces approach white. That
  /// takes list↔reading pane to 1.16:1 and sidebar↔reading pane to 1.28:1 —
  /// the same *relative* rhythm the dark palettes have.
  ///
  /// ## Why the accents moved with it
  ///
  /// They were tuned against a white `base` and do not survive it becoming
  /// grey: blue fell to 3.31:1, red to 3.78, and the flag orange to 1.73. Each
  /// is re-derived against the new surfaces here. `accentFlag` is the honest
  /// case — it reaches 3.49:1 as a graphical object and could not reach 4.5
  /// without ceasing to be orange, so it is graphical-only by declaration.
  static let light = Palette(
    base: Color(hex: 0xEAEEF4),
    sunken: Color(hex: 0xDEE4EC),
    raised: Color(hex: 0xFFFFFF),
    control: Color(hex: 0xD1D9E4),
    selection: Color(hex: 0xD3E4FB),
    border: Color(hex: 0xC2CBD8),
    borderStrong: Color(hex: 0x6E747A),
    inkPrimary: Color(hex: 0x0D141C),
    // 0.65/0.60 rather than the dark palettes' 0.60/0.56: black over white
    // gains contrast faster than white over near-black, so matching the alphas
    // would leave these two levels barely a point apart and the hierarchy flat.
    inkSecondary: Color(hex: 0x000000, alpha: 0.65),
    inkTertiary: Color(hex: 0x000000, alpha: 0.60),
    inkDisabled: Color(hex: 0x000000, alpha: 0.45),
    accentBlue: Color(hex: 0x0A6FE8),
    accentBlueText: Color(hex: 0x0B55B8),
    accentRed: Color(hex: 0xB00010),
    accentFlag: Color(hex: 0xA45F0F),
    accentMuted: Color(hex: 0x5F6772),
    accentMutedInk: Color(hex: 0x565D67),
    accentMutedFill: Color(hex: 0x6B7280, alpha: 0.13),
    accentOk: Color(hex: 0x24693C),
    stateHover: Color(hex: 0x000000, alpha: 0.05),
    statePressed: Color(hex: 0x000000, alpha: 0.09),
    shadowColor: Color(hex: 0x223046),
    shadowStrength: 0.42
  )

  static func `for`(_ theme: AppTheme) -> Palette {
    switch theme {
    case .signature: .signature
    case .dark: .dark
    case .light: .light
    }
  }

  /// Every surface ink can actually be drawn on.
  ///
  /// `border` is excluded because nothing writes on it. This is the list a
  /// contrast check has to sweep — checking `base` alone is what let §G2, §G3a,
  /// §G3b and §G3c ship.
  var drawableSurfaces: [Color] { [base, sunken, raised, control, selection] }
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

/// Design tokens.
///
/// ## Source of truth
///
/// Sizes and type began as a transcription of Figma node `3:4`; colours resolve
/// through the selected `AppTheme`. Nothing else in the app should contain a
/// raw colour, size, shadow or animation curve.
///
/// ## Numerals
///
/// Every count, size, duration and timestamp in this app renders
/// `.monospacedDigit()`, and numbers that update in place tick via
/// `.contentTransition(.numericText())`. A number that jiggles width as it
/// changes is decoration; one that ticks in place is a reading. This is a
/// convention rather than a token because SwiftUI expresses it as a modifier —
/// but it is not optional, and a proportional numeral in this app is a bug.
enum Theme {
  @MainActor
  private static var palette: Palette { ThemeController.shared.palette }

  // MARK: - Surfaces
  //
  // Four levels, deliberately close together. The separation between panes is
  // carried by these steps AND by a 1pt structural rule at each pane seam —
  // the steps alone are 1.08-1.16:1, which is why the light theme collapsed
  // without them.

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
    /// Decorative hairline. Never load-bearing — see `borderStrong`.
    static var border: Color { Theme.palette.border }
    /// Outlines that carry meaning: focus, hover, state. Clears 3:1.
    static var borderStrong: Color { Theme.palette.borderStrong }
  }

  // MARK: - Text
  //
  // Four levels, which is how the design keeps hierarchy without introducing
  // more hues. `disabled` is the fourth because opacity arithmetic on
  // `tertiary` produced 1.77:1 — a control nobody could see was inert or
  // otherwise.

  @MainActor
  enum Ink {
    static var primary: Color { Theme.palette.inkPrimary }
    static var secondary: Color { Theme.palette.inkSecondary }
    static var tertiary: Color { Theme.palette.inkTertiary }
    static var disabled: Color { Theme.palette.inkDisabled }
  }

  // MARK: - Accents
  //
  // Colour is scarce and each one means something. Blue means exactly two
  // things — UNREAD, and THE PRIMARY ACTION IN THIS CONTEXT — plus the
  // platform's own checked-state idiom on selection controls. It used to mean
  // six, which is the same as meaning nothing. Red is destructive only. Orange
  // is the flag and carries real state.
  //
  // Fill and foreground are separate tokens. `blue` is what a white label sits
  // on; `blueText` is blue drawn as a label itself.

  @MainActor
  enum Accent {
    /// Filled controls. White labels sit on this.
    static var blue: Color { Theme.palette.accentBlue }
    /// Blue as a LABEL on a surface — Undo, Load more, Load images.
    static var blueText: Color { Theme.palette.accentBlueText }
    static var red: Color { Theme.palette.accentRed }
    /// Graphical only. Never set text in this.
    static var flag: Color { Theme.palette.accentFlag }
    /// Neutral chip FILL used for badges, the avatar and secondary buttons.
    static var muted: Color { Theme.palette.accentMuted }
    /// Neutral as a FOREGROUND — avatar initials, unflagged glyphs.
    static var mutedInk: Color { Theme.palette.accentMutedInk }
    /// 13% muted — avatar and secondary button fills.
    static var mutedFill: Color { Theme.palette.accentMutedFill }
    static var ok: Color { Theme.palette.accentOk }
  }

  // MARK: - Interaction
  //
  // Hover, pressed and focus used to be invented per control: nine interactive
  // surfaces had nine different answers, and the sidebar row — the most-clicked
  // control in the app — had no hover feedback at all. These are overlay tints,
  // layered ON whatever surface the control already has, so one value composes
  // correctly against all five.

  @MainActor
  enum State {
    static var hover: Color { Theme.palette.stateHover }
    static var pressed: Color { Theme.palette.statePressed }
    /// The focus ring. `blueText` rather than the fill blue: a ring is a
    /// graphical object read against a surface, which is exactly the job the
    /// text token is tuned for.
    static var focus: Color { Theme.palette.accentBlueText }
  }

  // MARK: - Elevation
  //
  // Three shadows, palette-aware. They were three per-site literals in pure
  // black at 28-34%, which is correct on a near-black ground and muddy on
  // white — in the light theme the composer's shadow read as a grey smudge
  // rather than as lift.

  @MainActor
  enum Elevation {
    static let flush = ShadowToken(opacity: 0, radius: 0, y: 0)
    /// Resting cards and chips.
    static let raised = ShadowToken(opacity: 0.16, radius: 8, y: 2)
    /// Controls that float over content: the compose button, transient notices.
    static let lifted = ShadowToken(opacity: 0.26, radius: 13, y: 4)
    /// Panels that own the foreground: the composer.
    static let float = ShadowToken(opacity: 0.32, radius: 22, y: 10)
  }

  // MARK: - Type
  //
  // SF, deliberately and only.
  //
  // The design specified Inter, and the app never shipped it: Inter is not a
  // macOS system font and `app/Resources/` contains no font binary, so
  // `.custom("Inter", …)` fell through to SF for every user while the spacing
  // had been tuned in Figma against Inter's metrics. It was also a silent trap
  // — anyone who installed Inter would have shifted every string in the app
  // while the icons stayed on SF, with nothing in the codebase to explain why.
  //
  // SF is the right answer regardless: it is what a Mac app should be set in,
  // it is optically sized (Text below 20pt, Display above, switched
  // automatically), and it removes a dependency.
  //
  // Sizes are fixed rather than Dynamic Type-relative. That is a real
  // limitation and it is deliberate: the list's row anatomies are fixed heights
  // per density so `List` can use a constant row height, and a body font that
  // grows out from under a 44pt row would break the thing density exists for.
  // Whoever revisits this has to move both at once.

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
    /// Operational headlines — sheet titles, the bulk panel's count. SF,
    /// because those are the app operating rather than presenting.
    static let title = font(20, .bold)

    /// The one editorial moment: content headlines.
    ///
    /// SF Serif (New York) through the system, so this ships no binary and
    /// inherits optical sizing. The rule that keeps a pairing from spreading is
    /// not a site list — it is this: **serif where the app presents someone's
    /// words, SF where the app operates.** Today that means the reading pane's
    /// subject and the empty state addressing the reader, and nothing else. If
    /// this token appears in a toolbar, a row, or the status rail, that is a
    /// bug in taste.
    ///
    /// Semibold rather than the title's bold: New York at 20pt bold sits
    /// visually heavier than SF bold at the same size, and a subject should
    /// read as a headline rather than as a slab.
    static let display = SwiftUI.Font.system(size: 20, weight: .semibold, design: .serif)
    /// `display` at the empty state's smaller size.
    static let displaySmall = SwiftUI.Font.system(size: 17, weight: .semibold, design: .serif)

    private static func font(_ size: CGFloat, _ weight: SwiftUI.Font.Weight) -> SwiftUI.Font {
      .system(size: size, weight: weight, design: .default)
    }
  }

  // MARK: - Icons
  //
  // A real scale, because icon size used to be DERIVED BY SUBTRACTION from a
  // layout token — `.system(size: Theme.Size.icon - 3)` — at 24 sites, in six
  // distinct sizes with no relationship between them. SF Symbol weight tracks
  // the weight of the text each size sits beside.

  enum Icon {
    /// Chevrons, disclosure, dismiss. 9pt.
    static let micro = symbol(9, .semibold)
    /// Inline row affordances and small field glyphs. 12pt.
    static let small = symbol(12, .medium)
    /// Toolbar and sidebar. 14pt.
    static let medium = symbol(14, .medium)
    /// Attachment chips and other 18pt marks.
    static let large = symbol(18, .regular)
    /// Empty states. 28pt, light — it is a mark, not an alarm.
    static let display = symbol(28, .light)

    private static func symbol(_ size: CGFloat, _ weight: SwiftUI.Font.Weight) -> SwiftUI.Font {
      .system(size: size, weight: weight)
    }
  }

  // MARK: - Spacing
  //
  // Six steps on a 4pt grid, plus `hair` as a hairline constant.
  //
  // There were ten — 2, 4, 6, 8, 10, 12, 16, 20, 24, 30 — of which four were
  // off the grid the comment claimed. With ten choices there is no forcing
  // function: every layout picks whatever looks right, which is how the sidebar
  // ended up with mailbox rows at 32pt, account rows at 30 and a theme switcher
  // at 22. Six steps is a rhythm; ten is a menu.

  enum Space {
    /// Hairlines and 1-2pt optical nudges only. Not a spacing step.
    static let hair: CGFloat = 2
    static let tight: CGFloat = 4
    static let base: CGFloat = 8
    static let loose: CGFloat = 12
    static let wide: CGFloat = 16
    static let pane: CGFloat = 24
    static let section: CGFloat = 32
  }

  // MARK: - Radius
  //
  // Four steps that scale with the element. The old set had six values applied
  // without any size relationship — a 520pt composer at radius 8 while a 22pt
  // icon button used 6. Small controls get a small radius; a panel gets a
  // panel's.

  enum Radius {
    /// Checkboxes and other sub-24pt marks.
    static let tight: CGFloat = 4
    /// Buttons, pills, chips, fields — anything 22-40pt tall.
    static let control: CGFloat = 6
    /// Panels, banners, the composer.
    static let panel: CGFloat = 12
    /// The window itself.
    static let window: CGFloat = 16
  }

  enum Size {
    static let sidebar: CGFloat = 220
    static let list: CGFloat = 380
    static let unreadDot: CGFloat = 8
    static let flagIcon: CGFloat = 12
    static let avatar: CGFloat = 36
    /// Every navigation row in the sidebar, snapped to one value — mailbox,
    /// account, add-account and the theme switcher all used to differ.
    static let rowHeight: CGFloat = 32

    /// The smallest a pressable thing may be.
    ///
    /// WCAG 2.2 SC 2.5.8 (Target Size, Minimum) puts the floor at 24×24, and
    /// six controls here sat under it — the row gutter's checkbox at 20×22 and
    /// its flag at 18×22 being the ones struck most often by a wide margin,
    /// once per row on a list that runs to five hundred.
    ///
    /// The criterion has a spacing exception, and it does not rescue those two:
    /// their centres were 19pt apart, inside the 24 the exception requires. So
    /// the gutter genuinely widens, 44pt to 52pt, and the row content moves
    /// with it.
    ///
    /// This is a FLOOR on the hit target, not on the glyph. Icons keep their
    /// sizes from `Theme.Icon`; what grows is the region that responds.
    static let hitTarget: CGFloat = 24
    static let toolbar: CGFloat = 48
  }

  // MARK: - Motion
  //
  // Four tokens, in two families. Springs (`quick`/`standard`/`panel`) are for
  // things that MOVE — panels, rows, reveals — and are graded by the mass of
  // the thing moving. `fade` is for things that CHANGE — colour, opacity —
  // where a spring's overshoot would blow past a value that has no physical
  // reading. An overshooting colour interpolation visibly sails past the
  // destination palette and comes back.
  //
  // Reduce Motion is honoured HERE, not at call sites. Every token collapses to
  // a near-instant fade when the system setting is on, so no call site can
  // forget accessibility by construction — a wrapper each site has to remember
  // to apply is an accessibility behaviour that decays on the twelfth call
  // site. Computed properties, not `let`: the setting must be re-read at each
  // use, or it freezes at whatever it was when the process launched.

  @MainActor
  enum Motion {
    /// Hover feedback, gutter affordances, small opacity shifts.
    static var quick: Animation { respecting(.spring(response: 0.22, dampingFraction: 0.86)) }
    /// Row insertion/removal, banner entrance, in-panel reveals.
    static var standard: Animation { respecting(.spring(response: 0.32, dampingFraction: 0.84)) }
    /// The composer and other large surfaces. Heavier, so slightly slower.
    static var panel: Animation { respecting(.spring(response: 0.42, dampingFraction: 0.80)) }
    /// Colour-only and opacity-only changes: theme switch, arrival-flash decay,
    /// disabled-state transitions. Never use a spring for these.
    static var fade: Animation { respecting(.easeOut(duration: 0.20)) }

    /// True when the reader has asked the system for less movement.
    ///
    /// Exposed so the two places that build motion outside the token scale —
    /// the connecting-state pulse, and any inline curve — can gate themselves
    /// on the same answer.
    static var isReduced: Bool {
      NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private static func respecting(_ animation: Animation) -> Animation {
      isReduced ? .easeOut(duration: 0.08) : animation
    }
  }
}

// MARK: - Elevation

/// One shadow in the elevation scale.
///
/// Opacity rather than a colour, because the colour is the palette's business:
/// the same token has to read as lift on a near-black ground and on white.
struct ShadowToken: Sendable, Equatable {
  let opacity: Double
  let radius: CGFloat
  let y: CGFloat
}

extension View {
  /// Applies an elevation token in the current palette's shadow colour.
  @MainActor
  func elevation(_ token: ShadowToken) -> some View {
    let palette = ThemeController.shared.palette
    return shadow(
      color: palette.shadowColor.opacity(token.opacity * palette.shadowStrength),
      radius: token.radius,
      y: token.y
    )
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
