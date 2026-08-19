import AppKit
import Observation
import SwiftUI

/// The appearances the app ships with.
///
/// `signature` is the default and the designed one. The rest exist because a
/// mail client is something people keep open all day, and "match my system",
/// "match my room" and "I need more contrast than your taste wants to give me"
/// are all legitimate reasons to want something else.
///
/// ## Order
///
/// Dark first, then light, so the chooser reads as a gradient rather than as an
/// alternation. `signature` must stay at index 0 — `ThemeTests` asserts it, and
/// the default is the app's identity rather than a position in a list.
enum AppTheme: String, CaseIterable, Identifiable, Sendable {
  /// Deep navy on the icon's axis, with its own accent family. The default.
  case signature
  /// Neutral dark — the original Figma greys, with no hue at all.
  case dark
  /// Warm dark.
  case umber
  /// Cool light.
  case light
  /// Warm light.
  case vellum
  /// Light, at maximum contrast.
  case noon

  var id: String { rawValue }

  var title: String {
    switch self {
    case .signature: "Signature"
    case .dark: "Dark"
    case .umber: "Umber"
    case .light: "Light"
    case .vellum: "Vellum"
    case .noon: "Noon"
    }
  }

  /// The line that actually distinguishes these in the chooser.
  ///
  /// With six appearances — three of them dark — the titles stop carrying the
  /// difference on their own. `ThemeTests` gates these for uniqueness and for
  /// not merely restating the title.
  var subtitle: String {
    switch self {
    case .signature: "Deep navy, matched to the app icon"
    case .dark: "Neutral dark"
    case .umber: "Warm dark, for the late shift"
    // Was "Light", which is the title again. It went unnoticed for as long as
    // nothing rendered it; the switcher's list gives every subtitle a row, and
    // a row that repeats the word beside it is worse than no row.
    case .light: "Cool greys, reading pane near white"
    case .vellum: "Warm paper, for the long read"
    case .noon: "Maximum contrast, for glare and tired eyes"
    }
  }

  /// Written out per case rather than computed by exclusion.
  ///
  /// This was `self != .light`, which is correct for exactly as long as there
  /// is one light appearance. Adding `vellum` and `noon` under that definition
  /// would have made both of them *dark* themes with light surfaces — every
  /// AppKit scrollbar, caret, focus ring and `ProgressView` drawn for the wrong
  /// polarity — and nothing would have caught it, because the test that checks
  /// this enumerates cases by hand too. An exhaustive `switch` makes the
  /// compiler ask the question for every case added after this one.
  var isDark: Bool {
    switch self {
    case .signature, .dark, .umber: true
    case .light, .vellum, .noon: false
    }
  }

  /// Drives `preferredColorScheme`, so AppKit's own chrome — scrollbars, the
  /// text cursor, focus rings, `ProgressView` — matches the palette. Without
  /// this the app's surfaces go dark while its scrollbars stay light.
  var colorScheme: ColorScheme { isDark ? .dark : .light }

  /// Identifies the theme in the switcher's list, the menu picker, and — for
  /// whichever theme is selected — on the switcher's own button.
  ///
  /// It used to be read as "the theme this button will move TO", back when the
  /// switcher cycled. It now names the theme it belongs to in all three places,
  /// which is the reading the symbol always had on its own.
  ///
  /// Signature was an `envelope.fill`. An envelope glyph in a mail app's status
  /// corner reads as "mail", not "appearance" — the half-filled circle is the
  /// platform's own idiom for a light/dark choice and carries no other meaning
  /// here.
  var symbol: String {
    switch self {
    case .signature: "circle.lefthalf.filled"
    case .dark: "moon.fill"
    // A desk lamp, not a second moon: umber is the late-shift palette, and the
    // distinction it has to carry in the list is warm-vs-cool rather than
    // dark-vs-light, which `moon.fill` beside it already says.
    case .umber: "lamp.desk.fill"
    case .light: "sun.max.fill"
    case .vellum: "book.closed.fill"
    // Contrast itself, rather than `eyeglasses` — which reads as a reading
    // mode you toggle per message rather than as an appearance.
    case .noon: "checkerboard.rectangle"
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
  /// Deep navy on the app icon's axis, with an accent family of its own.
  ///
  /// Sampling the icon gives one unambiguous signature: every colour sits on a
  /// cool axis, blue above green above red by a consistent step — ground at
  /// #101820, line work at #e0e0e8. The Figma surfaces were true neutrals
  /// (#161617, R=G=B), so icon and window read as two different products
  /// sitting next to each other in the Dock.
  ///
  /// ## Why this stopped being a rotation of `dark`
  ///
  /// It used to be exactly that: the Figma greys with `(g-8, g, g+8)` applied,
  /// luminance preserved to the third decimal, and a test — since deleted —
  /// pinning it there. The result was a theme nobody could tell from `dark`,
  /// for three measurable reasons:
  ///
  ///   1. **16 of the 24 tokens were byte-identical.** All eight accents, three
  ///      of the four ink levels, both state overlays. On a mail screen the
  ///      coloured pixels — unread dots, flags, New Message, avatar chips — are
  ///      what the eye indexes on, and they were the same colour in both.
  ///   2. **A constant additive offset decays as the surface lightens.** At
  ///      `(g±8)` the chroma ran 0.020 at `base` down to 0.018 at `control`,
  ///      putting it in the *lower* half of the palettes people call "tinted" —
  ///      about Nord's tint, half of Solarized's. OKLab ΔE against `dark` was
  ///      1.6–1.9, which is near the threshold for two large flat fields seen
  ///      SIDE BY SIDE, and these are seen minutes apart.
  ///   3. **The ramp was flat and shared.** `sunken → raised` — the sidebar
  ///      against the reading pane, the app's central seam — measured 1.035:1.
  ///      Four surfaces that read as three, in the same rhythm as `dark`.
  ///
  /// So this is now its own design rather than a filter over another one.
  /// Chroma roughly doubles to ~0.036 and is held up the ramp instead of
  /// decaying. **The ceiling is ~0.050**, where Solarized sits and where the
  /// surfaces start competing with `accentBlue` for the word "blue".
  ///
  /// ## Judge the ramp on ΔL, not on the ratio
  ///
  /// `sunken → raised` goes from ΔL 0.0127 to 0.0417 — 3.3× the perceptual
  /// step — and buys only 1.035 → 1.116 of WCAG ratio, because the `+0.05`
  /// flare term compresses everything below Y≈0.02. The ratio is the wrong
  /// instrument at this end of the range; `ThemeTests` gates these in ΔL.
  ///
  /// ## Why the accents are not the system palette
  ///
  /// The typographic rule in this file is *serif where the app presents
  /// someone's words, SF where the app operates*. The colour rule that rhymes
  /// with it: **the accents belong to the icon's drafting vocabulary, not to
  /// iOS.** `accentBlueText` was #4DA3FF — Apple's system blue, a colour in ten
  /// thousand other apps that says nothing about this one. It is now the
  /// ground's own hue lit from within (h=247 against the surfaces' h=249, at
  /// lower chroma than the system value), so it reads as the navy raised to
  /// incandescence rather than as a link dropped onto navy. The flag is brass
  /// rather than iOS orange, the red a vermilion with the plastic taken out,
  /// and `accentOk` a jade on the cool side of green so it belongs to the
  /// family. None is a hue reassignment — blue is still blue.
  static let signature = Palette(
    // R=3 puts this near the sRGB gamut edge at this hue and lightness, so the
    // red channel has no room left: a future request to go deeper will clip and
    // drift the hue rather than darken. Solarized's #002b36 has R=0 and ships
    // happily, so this is a limit rather than a defect — but it is a limit.
    base: Color(hex: 0x03111F),
    sunken: Color(hex: 0x0B1A29),
    raised: Color(hex: 0x152433),
    control: Color(hex: 0x243241),
    // The one surface allowed to be *lit* rather than merely tinted: chroma
    // 0.078, twice the surfaces around it. A selected row should look like the
    // light in this app is blue and everything else like the room it is in.
    selection: Color(hex: 0x0F3056),
    border: Color(hex: 0x364351),
    // 3.28:1 worst case. Carries the icon's silver line work — same hue as the
    // surfaces, so a focus ring reads as drawn ON the ground rather than
    // applied to it.
    borderStrong: Color(hex: 0x74818F),
    // The icon's line work is #e0e0e8 — cool near-white, not pure white. It
    // stays off #FFFFFF for a second reason now that `base` is deeper: white
    // would measure 18.4:1 here, high enough that halation is a real cost for
    // astigmatic readers. At #E0E7EF it is 15.3:1, which is plenty.
    inkPrimary: Color(hex: 0xE0E7EF),
    inkSecondary: Color(hex: 0xE3ECF6, alpha: 0.62),
    // See the note on `Palette.dark.inkTertiary` for the floor this clears, and
    // `statePressed` below for why it is 0.58 rather than 0.56.
    inkTertiary: Color(hex: 0xE3ECF6, alpha: 0.58),
    inkDisabled: Color(hex: 0xE3ECF6, alpha: 0.33),
    accentBlue: Color(hex: 0x0059BB),
    accentBlueText: Color(hex: 0x59A8ED),
    accentRed: Color(hex: 0xEF4C48),
    accentFlag: Color(hex: 0xECAA2E),
    accentMuted: Color(hex: 0x647587),
    accentMutedInk: Color(hex: 0x92A6BB),
    accentMutedFill: Color(hex: 0x647587, alpha: 0.13),
    accentOk: Color(hex: 0x48B487),
    // Not white. A cool overlay on a cool ground reads as light falling on the
    // surface; white reads as a grey wash laid over it. Free — nothing gates
    // the hue of these — and felt on every row in the app.
    stateHover: Color(hex: 0xCFE0F5, alpha: 0.06),
    statePressed: Color(hex: 0xCFE0F5, alpha: 0.09),
    shadowColor: Color(hex: 0x01070E),
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
    inkSecondary: Color(hex: 0xEBEBF5, alpha: 0.62),
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
  ///
  /// 0.58, not 0.56, for a reason the old figure missed: those ratios are
  /// measured against a surface AT REST. Three of the app's tertiary-inked
  /// controls are `.alap()` buttons, which lay a lightening overlay on the
  /// surface underneath them when hovered or pressed — and a lighter surface
  /// under an unchanged ink is a LOWER ratio. At 0.56 under the old 0.11
  /// pressed tint, tertiary fell to 4.31:1 on `raised` and 4.39:1 on `sunken`,
  /// which are exactly the two surfaces those buttons sit on. See
  /// `statePressed`; the fix is split between both tokens because neither
  /// could carry it alone without inverting the ink hierarchy.
    inkTertiary: Color(hex: 0xEBEBF5, alpha: 0.58),
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
    /// 0.09, down from 0.11.
    ///
    /// An overlay is not free of the contrast budget just because it is
    /// interaction feedback: it changes the surface an ink is being read on,
    /// and on a dark palette it changes it in the direction that costs ratio.
    /// Nothing measured this until now — `ThemeTests` swept tokens against
    /// surfaces AT REST, so a control that only fails while you are pressing it
    /// was outside what the arithmetic could see, and the six-failure lesson
    /// this file already records is exactly that unmeasured cases are the ones
    /// that ship.
    ///
    /// 0.11 could not be salvaged by moving `inkTertiary` alone: clearing 4.5
    /// that way needed alpha 0.64, which put tertiary ABOVE secondary and
    /// turned three ink levels into two. Splitting the correction — tertiary up
    /// to 0.58, pressed down to 0.09 — clears the floor on every surface a
    /// quiet button can sit on while leaving the hierarchy intact.
    statePressed: Color(hex: 0xFFFFFF, alpha: 0.09),
    shadowColor: Color(hex: 0x000000),
    shadowStrength: 1.0
  )

  /// Warm dark, on a coffee-and-leather axis rather than a sepia one.
  ///
  /// The app had two dark palettes and both were cool — `dark` at essentially
  /// no chroma, `signature` at h=249. Warm dark is not a stylistic duplicate of
  /// either: at night a cool screen reads as a light source and a warm one
  /// reads as a lit surface, which is the whole argument for this palette
  /// existing.
  ///
  /// The hue is h≈52. Past about h=75 it stops being warm and starts being an
  /// old photograph. Chroma is DELIBERATELY LOWER than `signature`'s (0.029
  /// against 0.037): warm hues gain apparent saturation faster than cool ones
  /// as lightness falls, and h=52 at signature's chroma looks like a filter
  /// over the screen rather than a palette.
  ///
  /// ## The accent problem a warm ground creates, and how it is solved
  ///
  /// Orange is the flag colour and orange is also, roughly, the ground. Two
  /// moves separate them: the flag goes hotter AND lighter — a gold at L=0.83
  /// measuring 7.58:1 on `control`, where a ground-adjacent orange would sit
  /// near 4 — and the red rotates *cooler*, to h=22, away from the ground
  /// rather than into it. Blue needs no defending and gains for free: a cool
  /// accent on a warm ground is the widest hue separation in any palette here.
  static let umber = Palette(
    base: Color(hex: 0x1A0C05),
    sunken: Color(hex: 0x24150D),
    raised: Color(hex: 0x2D1F17),
    control: Color(hex: 0x3D2F27),
    selection: Color(hex: 0x452A10),
    border: Color(hex: 0x4D4038),
    borderStrong: Color(hex: 0x8A7D75),
    inkPrimary: Color(hex: 0xEDE6DD),
    inkSecondary: Color(hex: 0xF4EBE1, alpha: 0.62),
    inkTertiary: Color(hex: 0xF4EBE1, alpha: 0.58),
    inkDisabled: Color(hex: 0xF4EBE1, alpha: 0.33),
    accentBlue: Color(hex: 0x005EB9),
    accentBlueText: Color(hex: 0x64A8ED),
    accentRed: Color(hex: 0xEB5056),
    accentFlag: Color(hex: 0xEBC336),
    accentMuted: Color(hex: 0x807063),
    accentMutedInk: Color(hex: 0xB2A091),
    accentMutedFill: Color(hex: 0x807063, alpha: 0.13),
    accentOk: Color(hex: 0x6AB275),
    // Warm white, for the same reason signature's is cool: an overlay should
    // read as light falling on this surface, not as a wash from another room.
    stateHover: Color(hex: 0xF5E9DA, alpha: 0.06),
    statePressed: Color(hex: 0xF5E9DA, alpha: 0.09),
    shadowColor: Color(hex: 0x0D0400),
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
    // A light palette's overlays DARKEN the surface, which moves ink contrast
    // the safe way — tertiary under the pressed tint measures 4.93:1 here
    // against the dark palettes' 4.27 before they were corrected. Nothing to
    // fix on this palette; the gate that catches it sweeps all six anyway,
    // because which direction is safe is a property of the palette rather than
    // something a future one can be assumed to inherit.
    stateHover: Color(hex: 0x000000, alpha: 0.05),
    statePressed: Color(hex: 0x000000, alpha: 0.09),
    shadowColor: Color(hex: 0x223046),
    shadowStrength: 0.42
  )

  /// Warm paper.
  ///
  /// `light` is a cool grey office. This is the other reader: someone who keeps
  /// mail open beside their writing, who finds blue-grey clinical, and who
  /// reads long messages rather than scanning short ones. It is also the one
  /// ground that agrees with the New York subject line already in this file —
  /// the single place where the type choice and the colour choice are making
  /// the same argument.
  ///
  /// ## Answering this file's own warning about warmth
  ///
  /// `light` carries only a trace of tint because, as its comment says, "at
  /// high lightness a tint that reads as 'considered' in the dark reads as
  /// 'slightly dirty' instead." That is true of *timid* warmth — a two-point
  /// cast on grey does look like a dirty screen. The answer is to commit
  /// rather than to abstain: `raised` at chroma 0.010 is near-white paper,
  /// `base` 0.022, `control` 0.031, monotonic at h≈86-92. Solarized light's
  /// base3 sits at 0.026 and has never been called dirty. The failure mode is
  /// the half-measure, not the warmth.
  ///
  /// Elevation runs the way `light` fought to establish, and further:
  /// `raised/control` is 1.50 against `light`'s 1.42. The reading pane is the
  /// whitest thing on screen and everything else is paper stock.
  static let vellum = Palette(
    base: Color(hex: 0xEDE8D8),
    sunken: Color(hex: 0xE1DAC7),
    raised: Color(hex: 0xFCFAF3),
    control: Color(hex: 0xD8CEB9),
    selection: Color(hex: 0xE7D3AA),
    border: Color(hex: 0xCCC3AF),
    borderStrong: Color(hex: 0x63594B),
    inkPrimary: Color(hex: 0x181007),
    // A warm near-black, not pure black. Black at alpha over warm paper turns
    // grey-violet through the midtones — the translucent levels are where that
    // shows, which is why the opaque primary can afford to be nearly neutral
    // and these cannot.
    inkSecondary: Color(hex: 0x110904, alpha: 0.66),
    inkTertiary: Color(hex: 0x110904, alpha: 0.62),
    inkDisabled: Color(hex: 0x110904, alpha: 0.40),
    accentBlue: Color(hex: 0x005BA7),
    accentBlueText: Color(hex: 0x005698),
    accentRed: Color(hex: 0x901818),
    /// Graphical only, exactly as `light` declares it: 3.69:1, and no orange
    /// that still reads as orange clears 4.5 on a light ground. Never set text
    /// in this.
    accentFlag: Color(hex: 0x905A00),
    accentMuted: Color(hex: 0x645B4F),
    accentMutedInk: Color(hex: 0x5C5245),
    accentMutedFill: Color(hex: 0x645B4F, alpha: 0.13),
    accentOk: Color(hex: 0x275E2B),
    stateHover: Color(hex: 0x1E1409, alpha: 0.05),
    statePressed: Color(hex: 0x1E1409, alpha: 0.09),
    // Warm brown rather than the blue-grey `light` uses, on the same principle
    // that file already states: a shadow tinted away from its palette reads as
    // a smudge rather than as lift.
    shadowColor: Color(hex: 0x4A3B22),
    shadowStrength: 0.40
  )

  /// Light, at maximum contrast.
  ///
  /// Every other palette here is built to CLEAR 4.5:1, which means its text
  /// lands in the 4.6-5.4 band by design, because that is where quiet lives.
  /// That is right for most readers and wrong for two: someone at a window in
  /// afternoon sun, and someone whose vision needs headroom. This is the
  /// palette that spends the contrast budget instead of conserving it. It is an
  /// accessibility position with a look that follows from it, not a fourth
  /// aesthetic.
  ///
  /// ## What it delivers, stated honestly
  ///
  /// Primary and secondary clear **AAA (7:1) on every surface that carries
  /// running text** — 20.2 and 10.4 on the reading pane, 14.8 and 8.6 on the
  /// sidebar. Tertiary does NOT, and this comment will not pretend otherwise:
  /// forcing it to 7:1 on `control` collapses it into secondary, and three ink
  /// levels that read as two is a worse accessibility outcome than a legible
  /// third level at 6:1. The defensible claim is: nothing here is below 4.65:1,
  /// and the two levels that carry sentences are above 8.6:1 everywhere a
  /// sentence appears.
  ///
  /// Structure is the other half, and it is the half people actually complain
  /// about in sunlight: `raised/control` is 1.93:1 against `light`'s 1.42, and
  /// `borderStrong` measures 8.84:1 on `base` against `light`'s 3.32. Pane
  /// edges here are visible across a room rather than at reading distance.
  ///
  /// ## Why `control` is so much darker than any other light palette's
  ///
  /// Not only for structure — **the self-tinted chip tripwire forces it.** A
  /// dark `accentBlueText`, which the AAA target requires, drives the chip
  /// composite's ratio UP, and the only lever that pulls it back under 4.5 is
  /// bringing `control` closer to the accent. So the tripwire and the
  /// accessibility goal happen to want the same thing here — but they are in
  /// tension, and anyone who later lightens this to soften it will find
  /// `selfTintedChipsAreLegible` failing on `control`, which would make the
  /// remote-image banner eligible for a fill again. That coupling is not
  /// guessable from the value, which is why it is written down.
  static let noon = Palette(
    base: Color(hex: 0xE9EDF2),
    sunken: Color(hex: 0xD7DDE4),
    raised: Color(hex: 0xFFFFFF),
    control: Color(hex: 0xB2BCC6),
    // A real blue rather than a pale wash. On a palette this contrasty a faint
    // selection simply disappears; and its depth is also what keeps the chip
    // treatment failing on `selection` (4.07) rather than passing.
    selection: Color(hex: 0x8CBAEE),
    border: Color(hex: 0xA5AEB9),
    borderStrong: Color(hex: 0x37414B),
    inkPrimary: Color(hex: 0x04070A),
    inkSecondary: Color(hex: 0x060A0E, alpha: 0.78),
    inkTertiary: Color(hex: 0x060A0E, alpha: 0.65),
    inkDisabled: Color(hex: 0x060A0E, alpha: 0.42),
    accentBlue: Color(hex: 0x00468D),
    accentBlueText: Color(hex: 0x004581),
    accentRed: Color(hex: 0x820004),
    /// Graphical only — 3.57:1, and this palette cannot buy an exception to the
    /// fact that orange does not reach 4.5 on a light ground either.
    accentFlag: Color(hex: 0x7D4C00),
    accentMuted: Color(hex: 0x444D56),
    accentMutedInk: Color(hex: 0x3C4651),
    accentMutedFill: Color(hex: 0x444D56, alpha: 0.13),
    accentOk: Color(hex: 0x004F20),
    stateHover: Color(hex: 0x0B1017, alpha: 0.06),
    statePressed: Color(hex: 0x0B1017, alpha: 0.10),
    shadowColor: Color(hex: 0x1B2733),
    // 0.55 against `light`'s 0.42: a palette whose whole argument is visible
    // structure should not carry its lift as a whisper.
    shadowStrength: 0.55
  )

  static func `for`(_ theme: AppTheme) -> Palette {
    switch theme {
    case .signature: .signature
    case .dark: .dark
    case .umber: .umber
    case .light: .light
    case .vellum: .vellum
    case .noon: .noon
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
