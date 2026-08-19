import Foundation
import SwiftUI
import Testing
@testable import Alap

/// Palettes and appearance switching.
///
/// The contrast checks are the reason this file exists. Colour regressions are
/// invisible in review — a token nudged two points still "looks fine" in a
/// screenshot — and the cost lands on whoever cannot read the result. Measuring
/// is the only way to know.
@MainActor
struct ThemeTests {
  // MARK: - Contrast
  //
  // WCAG 2.2 relative luminance. Normal text needs 4.5:1, large text 3.0:1.
  // Everything measured here is 11–14pt, so 4.5 is the bar.

  private func channel(_ value: Double) -> Double {
    value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
  }

  private func luminance(_ color: Color) -> Double {
    let rgba = NSColor(color).usingColorSpace(.sRGB)!
    return 0.2126 * channel(rgba.redComponent)
      + 0.7152 * channel(rgba.greenComponent)
      + 0.0722 * channel(rgba.blueComponent)
  }

  /// Contrast of `ink` composited over `surface`.
  ///
  /// Compositing matters: the ink levels are translucent, so comparing their
  /// declared colour against the surface would report a ratio no user ever
  /// sees.
  private func contrast(_ ink: Color, on surface: Color) -> Double {
    let a = luminance(flatten(ink, on: surface))
    let b = luminance(surface)
    return (max(a, b) + 0.05) / (min(a, b) + 0.05)
  }

  /// Alpha-composites a translucent colour onto an opaque one.
  ///
  /// Split out because contrast is not the only thing that needs it: the
  /// avatar's initials sit on a 13% tint which itself sits on a surface, and
  /// measuring against the declared tint would report a ratio no reader sees.
  private func flatten(_ front: Color, on back: Color) -> Color {
    let f = NSColor(front).usingColorSpace(.sRGB)!
    let b = NSColor(back).usingColorSpace(.sRGB)!
    let alpha = f.alphaComponent
    return Color(nsColor: NSColor(
      srgbRed: f.redComponent * alpha + b.redComponent * (1 - alpha),
      green: f.greenComponent * alpha + b.greenComponent * (1 - alpha),
      blue: f.blueComponent * alpha + b.blueComponent * (1 - alpha),
      alpha: 1
    ))
  }

  // MARK: - Perceptual colour
  //
  // OKLab, alongside the WCAG arithmetic above, because the two answer
  // different questions and this file needs both.
  //
  // WCAG relative luminance answers "can this be READ", and it is the right
  // instrument for every contrast floor here. It is the wrong instrument for
  // "do these two panes look like two panes": the +0.05 flare term compresses
  // the dark end so hard that tripling the perceptual step between two near-
  // black surfaces moves the ratio by less than 0.1. Signature's ramp was flat
  // for exactly that reason and the ratio never complained.
  //
  // OKLab is perceptually uniform, so ΔL means the same thing at both ends of
  // the range, and it separates lightness from chroma — which is what lets the
  // signature tests assert "more colour, same weight" as two independent
  // claims rather than one vague one.

  private func oklab(_ color: Color) -> (l: Double, a: Double, b: Double) {
    let rgba = NSColor(color).usingColorSpace(.sRGB)!
    let r = channel(rgba.redComponent)
    let g = channel(rgba.greenComponent)
    let b = channel(rgba.blueComponent)

    let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
    let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
    let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)

    return (
      0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
      1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
      0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
    )
  }

  /// Perceptual lightness, 0-1.
  private func lightness(_ color: Color) -> Double { oklab(color).l }

  /// Perceptual colourfulness. 0 is a true grey.
  private func chroma(_ color: Color) -> Double {
    let c = oklab(color)
    return (c.a * c.a + c.b * c.b).squareRoot()
  }

  /// Hue angle in degrees, 0-360.
  private func hue(_ color: Color) -> Double {
    let c = oklab(color)
    let degrees = atan2(c.b, c.a) * 180 / .pi
    return degrees < 0 ? degrees + 360 : degrees
  }

  /// Every surface a token can actually land on.
  ///
  /// This array is the whole point. The shipped version was
  /// `[base, sunken, raised]`, which encodes the belief that the worst case on
  /// a dark palette is the DARKEST surface. It is the lightest — and
  /// `control` and `selection` are where the six shipped contrast failures
  /// lived, invisible to review and visible only to arithmetic. `border` stays
  /// out because nothing is ever written on it.
  private func drawableSurfaces(_ palette: Palette) -> [(String, Color)] {
    [
      ("base", palette.base), ("sunken", palette.sunken), ("raised", palette.raised),
      ("control", palette.control), ("selection", palette.selection),
    ]
  }

  @Test("Every ink level clears 4.5:1 on every surface it can be drawn on",
        arguments: AppTheme.allCases)
  func inkMeetsWCAGAA(theme: AppTheme) {
    let palette = Palette.for(theme)
    let inks = [
      ("primary", palette.inkPrimary),
      ("secondary", palette.inkSecondary),
      ("tertiary", palette.inkTertiary),
    ]

    for (surfaceName, surface) in drawableSurfaces(palette) {
      for (inkName, ink) in inks {
        let ratio = contrast(ink, on: surface)
        #expect(
          ratio >= 4.5,
          "\(theme.title): \(inkName) on \(surfaceName) is \(String(format: "%.2f", ratio)):1"
        )
      }
    }
  }

  @Test("Disabled ink is inert but still legible", arguments: AppTheme.allCases)
  func disabledInkIsDiscernible(theme: AppTheme) {
    // Disabled is exempt from the text floor, and that exemption is not a
    // licence: `tertiary.opacity(0.4)` measured 1.77:1, which is below the
    // point where a glyph's SHAPE can be made out — and the list toolbar's
    // buttons spend most of their life in that state. The band is
    // "clearly inert, still identifiable".
    let palette = Palette.for(theme)
    for (name, surface) in drawableSurfaces(palette) {
      let ratio = contrast(palette.inkDisabled, on: surface)
      #expect(ratio >= 2.2, "\(theme.title): disabled on \(name) is \(ratio):1")
      #expect(ratio <= 4.0, "\(theme.title): disabled on \(name) is \(ratio):1 — too active")
    }
  }

  @Test("Accents used AS TEXT clear the text floor", arguments: AppTheme.allCases)
  func accentTextMeetsWCAGAA(theme: AppTheme) {
    // The palette comment used to say of the accents that "shifting them would
    // cost legibility to buy nothing." That claim was never measured. Five of
    // the six places blue appeared as text were under 4.5:1, because
    // `accentBlue` is a FILL colour — Apple ships #0A84FF for tinted controls
    // on dark, not for label text on raised surfaces.
    let palette = Palette.for(theme)
    let textAccents = [
      ("blueText", palette.accentBlueText),
      ("mutedInk", palette.accentMutedInk),
      ("ok", palette.accentOk),
    ]

    for (surfaceName, surface) in drawableSurfaces(palette) {
      for (name, accent) in textAccents {
        let ratio = contrast(accent, on: surface)
        #expect(
          ratio >= 4.5,
          "\(theme.title): \(name) on \(surfaceName) is \(String(format: "%.2f", ratio)):1"
        )
      }
    }
  }

  @Test("A white label on a filled accent clears 4.5:1", arguments: AppTheme.allCases)
  func filledButtonLabels(theme: AppTheme) {
    // The most prominent control in the application — New Message, Send, the
    // bulk panel's Archive — set its label in white on #0A84FF, which measures
    // 3.65:1 at the 13pt semibold it is drawn in.
    let palette = Palette.for(theme)
    let ratio = contrast(.white, on: palette.accentBlue)
    #expect(ratio >= 4.5,
            "\(theme.title): white on accentBlue is \(String(format: "%.2f", ratio)):1")
  }

  @Test("Avatar initials clear the text floor", arguments: AppTheme.allCases)
  func avatarInitials(theme: AppTheme) {
    // The worst text contrast in the app at 2.93:1, on one of the largest and
    // most persistent elements in the reading pane. The tinted fill sits on
    // `raised`, and the initials sit on the tinted fill.
    let palette = Palette.for(theme)
    let bubble = flatten(palette.accentMutedFill, on: palette.raised)
    let ratio = contrast(palette.accentMutedInk, on: bubble)
    #expect(ratio >= 4.5,
            "\(theme.title): initials are \(String(format: "%.2f", ratio)):1")
  }

  @Test("Graphical accents clear the 3:1 non-text floor", arguments: AppTheme.allCases)
  func graphicalAccents(theme: AppTheme) {
    // A different floor, stated rather than assumed. `accentFlag` is a 12pt
    // `flag.fill` glyph and therefore a graphical object under WCAG 1.4.11 —
    // which matters, because no orange that still reads as orange clears 4.5:1
    // on a light surface. #A45F0F reaches 3.49 and is already brown.
    //
    // `accentRed` is here rather than in the text test for the same reason:
    // it marks destructive actions and failures graphically. Any label set in
    // it needs auditing against this floor's larger sibling separately.
    let palette = Palette.for(theme)
    let graphical = [
      ("flag", palette.accentFlag),
      ("red", palette.accentRed),
      ("borderStrong", palette.borderStrong),
    ]

    for (surfaceName, surface) in drawableSurfaces(palette) {
      for (name, accent) in graphical {
        let ratio = contrast(accent, on: surface)
        #expect(
          ratio >= 3.0,
          "\(theme.title): \(name) on \(surfaceName) is \(String(format: "%.2f", ratio)):1"
        )
      }
    }
  }

  @Test("The decorative hairline is never asked to do a meaningful job")
  func borderIsWeakerThanBorderStrong() {
    // `border` sits at about 1.4:1 against its neighbours, which is fine for a
    // seam between surfaces that already separate and is NOT fine for a focus
    // ring or a hover outline. Keeping the two tokens distinct is what stops
    // the second use quietly reaching for the first value.
    for theme in AppTheme.allCases {
      let palette = Palette.for(theme)
      #expect(contrast(palette.borderStrong, on: palette.base)
              > contrast(palette.border, on: palette.base))
    }
  }

  @Test("Adjacent panes are separable in every palette", arguments: AppTheme.allCases)
  func surfacesSeparate(theme: AppTheme) {
    // The light theme used to put the message list and the reading pane
    // 1.04:1 apart — visually the same colour, so the three-pane structure the
    // whole layout depends on simply did not exist. It was discoverable only
    // by screenshot, which is why it shipped.
    let palette = Palette.for(theme)
    #expect(contrast(palette.base, on: palette.raised) >= 1.10)
    #expect(contrast(palette.sunken, on: palette.base) >= 1.06)
  }

  @Test("Ink levels stay distinguishable from each other", arguments: AppTheme.allCases)
  func hierarchyIsPreserved(theme: AppTheme) {
    // Raising tertiary for contrast must not collapse it into secondary —
    // three levels that look like two is a hierarchy that has stopped working.
    let palette = Palette.for(theme)
    let primary = contrast(palette.inkPrimary, on: palette.base)
    let secondary = contrast(palette.inkSecondary, on: palette.base)
    let tertiary = contrast(palette.inkTertiary, on: palette.base)
    let disabled = contrast(palette.inkDisabled, on: palette.base)

    #expect(primary > secondary)
    #expect(secondary > tertiary)
    #expect(tertiary > disabled)
  }

  // MARK: - Surface depth

  @Test("Surfaces stay ordered by lightness",
        arguments: AppTheme.allCases.filter(\.isDark))
  func darkSurfacesAreOrdered(theme: AppTheme) {
    // The design carries pane separation through lightness steps rather than
    // dividers. If two surfaces cross over, the depth reads inverted and the
    // reading pane appears to sink behind the list.
    let palette = Palette.for(theme)
    #expect(luminance(palette.base) < luminance(palette.sunken))
    #expect(luminance(palette.sunken) < luminance(palette.raised))
    #expect(luminance(palette.raised) < luminance(palette.control))
    #expect(luminance(palette.control) < luminance(palette.border))
  }

  @Test("Light elevation runs the way light interfaces actually use it",
        arguments: AppTheme.allCases.filter { !$0.isDark })
  func lightSurfacesAreOrdered(theme: AppTheme) {
    // The light palette used to copy the dark palettes' DIRECTION — building
    // upward from `base` — with `base` at #FFFFFF, the lightest possible
    // value, which left `raised` nowhere to go. In a light interface the app
    // background is a tinted grey and raised surfaces approach white.
    //
    // Parameterised now rather than hardcoded to `Palette.light`: a test that
    // names one palette stops covering the rule the moment a second palette
    // obeys it, which is the same shape of gap `isDark` had.
    let palette = Palette.for(theme)
    #expect(luminance(palette.raised) > luminance(palette.base))
    #expect(luminance(palette.base) > luminance(palette.sunken))
    #expect(luminance(palette.control) > luminance(palette.border))
  }

  // The luminance-lock test used to live here.
  //
  // It asserted that signature's four surfaces stayed within 0.01 luminance of
  // `dark`'s, on the reasoning that signature was a hue rotation and should not
  // change any pane's apparent weight. That test is gone, and its removal is
  // the point rather than a casualty: **it was what enforced the bug.** A
  // palette pinned to another palette's lightness, sharing all eight accents
  // with it, cannot be told apart from it — and the test guaranteed the pin
  // while nothing guaranteed the difference. It also coupled the two designs
  // permanently: any later adjustment to `dark` would have dragged signature
  // along or failed for reasons that had nothing to do with signature.
  //
  // Its CONCERN was legitimate — "no pane changes apparent weight, the design's
  // sense of depth is untouched" — so the two tests below state that concern
  // about signature directly instead of by proxy through another palette.

  @Test("Signature carries real chroma, on the icon's axis")
  func signatureIsTinted() {
    // A floor AND a ceiling, because both directions are failure modes.
    //
    // The floor is why this test exists. The palette shipped at chroma ≈0.020,
    // which is about Nord's tint and half of Solarized's — measurably in the
    // lower half of the palettes people call "tinted", and indistinguishable
    // from the neutral it was derived from.
    //
    // The ceiling is the other half of the judgement. Around 0.050 — where
    // Solarized dark sits — the surfaces start competing with `accentBlue` for
    // the word "blue", and an app whose accent means UNREAD and PRIMARY ACTION
    // cannot afford its own background making the same claim.
    let palette = Palette.signature
    for (name, surface) in [("base", palette.base), ("sunken", palette.sunken),
                            ("raised", palette.raised), ("control", palette.control)] {
      let c = chroma(surface)
      #expect(c >= 0.030, "\(name) chroma is \(String(format: "%.4f", c)) — back toward neutral")
      #expect(c <= 0.050, "\(name) chroma is \(String(format: "%.4f", c)) — reads as a blue app")
      #expect(abs(hue(surface) - 249) <= 6, "\(name) is off the icon's axis at \(hue(surface))°")
    }

    // The one surface allowed to be lit rather than merely tinted.
    #expect(chroma(palette.selection) >= 0.070)
  }

  @Test("Signature's surfaces are separable by weight, not only by rule")
  func signatureHasDepth() {
    // What the luminance-lock test was actually protecting — except it
    // protected it by pinning signature to `dark`, which pinned in `dark`'s
    // flattest interval too. `sunken → raised` is the sidebar against the
    // reading pane, the app's central seam, and it measured ΔL 0.0127: two
    // surfaces that are the same colour with a 1pt line drawn between them.
    //
    // Stated in ΔL rather than in WCAG ratio deliberately. The ratio's +0.05
    // flare term compresses everything below Y≈0.02, so at this end of the
    // range a 3.3× perceptual change moves the ratio by 0.08 and the number
    // tells you almost nothing. Perceptual lightness is the right instrument
    // for "do these two panes read as two panes".
    let p = Palette.signature
    #expect(lightness(p.sunken) - lightness(p.base) >= 0.030)
    #expect(lightness(p.raised) - lightness(p.sunken) >= 0.030)
    #expect(lightness(p.control) - lightness(p.raised) >= 0.030)
    #expect(lightness(p.raised) - lightness(p.base) >= 0.070)
  }

  @Test("Signature really is on a cool axis")
  func signatureIsCool() {
    // Sampled from the icon: blue above green above red, consistently.
    for color in [Palette.signature.base, Palette.signature.sunken,
                  Palette.signature.raised, Palette.signature.control] {
      let rgb = NSColor(color).usingColorSpace(.sRGB)!
      #expect(rgb.blueComponent > rgb.greenComponent)
      #expect(rgb.greenComponent > rgb.redComponent)
    }
  }

  @Test("The neutral dark palette really is neutral")
  func darkIsNeutral() {
    for color in [Palette.dark.base, Palette.dark.sunken, Palette.dark.raised] {
      let rgb = NSColor(color).usingColorSpace(.sRGB)!
      #expect(abs(rgb.redComponent - rgb.blueComponent) < 0.02)
    }
  }

  // MARK: - Selection

  @Test("Signature is the default")
  func signatureIsDefault() {
    // The default is the app's identity, not a preference, so it must not
    // follow the system appearance.
    #expect(AppTheme(rawValue: "signature") == .signature)
    #expect(AppTheme.allCases.first == .signature)
  }

  @Test("Every theme declares a colour scheme for AppKit chrome")
  func colorSchemesAreDeclared() {
    // Written as a total map rather than a list of assertions, so adding a case
    // fails HERE — with a name — instead of silently going uncovered. `isDark`
    // used to be `self != .light`, under which every appearance added after the
    // first light one would have been declared dark: light surfaces with dark
    // scrollbars, carets and focus rings, and a test like the old one, which
    // enumerated three cases by hand, would have kept passing.
    let expected: [AppTheme: ColorScheme] = [
      .signature: .dark, .dark: .dark, .umber: .dark,
      .light: .light, .vellum: .light, .noon: .light,
    ]
    #expect(expected.count == AppTheme.allCases.count, "a theme is missing from this map")

    for theme in AppTheme.allCases {
      #expect(theme.colorScheme == expected[theme], "\(theme.title) declares the wrong scheme")
    }
  }

  @Test("A palette's polarity agrees with how its surfaces are actually built",
        arguments: AppTheme.allCases)
  func polarityMatchesSurfaces(theme: AppTheme) {
    // `isDark` is a hand-written switch, so it can disagree with the palette it
    // describes and nothing else would notice. Ink direction is the check that
    // cannot be fooled: a dark palette writes light ink on a dark ground.
    let palette = Palette.for(theme)
    let inkIsLighterThanGround = luminance(flatten(palette.inkPrimary, on: palette.base))
      > luminance(palette.base)
    #expect(inkIsLighterThanGround == theme.isDark,
            "\(theme.title) declares isDark=\(theme.isDark) but its ink runs the other way")
  }

  // MARK: - Interaction states
  //
  // Every floor above is measured against a surface AT REST, which is a real
  // blind spot: `.alap()` lays a tint over whatever surface a control sits on
  // when it is hovered or pressed, and on a dark palette that tint LIGHTENS the
  // ground under an unchanged ink. A control can therefore clear 4.5:1 sitting
  // still and fail it under the pointer, which is where three of this app's
  // tertiary-inked buttons lived.

  @Test("Ink still clears the floor while a control is hovered or pressed",
        arguments: AppTheme.allCases)
  func stateOverlaysDoNotBreakInk(theme: AppTheme) {
    // Only `base`, `sunken` and `raised`. That is not a convenience — it is the
    // set a quiet button can actually sit on: `AlapButtonStyle` gives `.quiet`
    // a clear resting fill, so the overlay composites onto the PANE behind the
    // control, and the three tertiary-inked buttons in the app (the sync line,
    // and two in the composer) are all quiet. `control` and `selection` are
    // where a filled or selected control lives, and those carry primary ink.
    //
    // At the old 0.11 pressed tint, signature and dark measured 4.31:1 on
    // `raised` and ~4.35 on `sunken` — the exact two panes those buttons are
    // drawn on.
    let palette = Palette.for(theme)
    let panes = [("base", palette.base), ("sunken", palette.sunken), ("raised", palette.raised)]
    let inks = [("secondary", palette.inkSecondary), ("tertiary", palette.inkTertiary)]
    let states = [("hover", palette.stateHover), ("pressed", palette.statePressed)]

    for (paneName, pane) in panes {
      for (stateName, overlay) in states {
        let surface = flatten(overlay, on: pane)
        for (inkName, ink) in inks {
          let ratio = contrast(ink, on: surface)
          let measured = String(format: "%.2f", ratio)
          #expect(
            ratio >= 4.5,
            "\(theme.title): \(inkName) on a \(stateName)ed \(paneName) is \(measured):1"
          )
        }
      }
    }
  }

  @Test("Theme identifiers round-trip for persistence", arguments: AppTheme.allCases)
  func rawValuesRoundTrip(theme: AppTheme) {
    // These strings land in UserDefaults, so renaming a case silently resets
    // everyone's choice.
    #expect(AppTheme(rawValue: theme.rawValue) == theme)
  }

  @Test("Every theme has a distinct title, symbol and subtitle")
  func themesArePresentable() {
    // Subtitles joined this list when the sidebar switcher became a chooser.
    // They had no reader before that and so nothing kept them apart; now they
    // are the line that actually distinguishes two dark palettes from each
    // other in the list, and a duplicate would be a row that explains nothing.
    let titles = Set(AppTheme.allCases.map(\.title))
    let symbols = Set(AppTheme.allCases.map(\.symbol))
    let subtitles = Set(AppTheme.allCases.map(\.subtitle))
    #expect(titles.count == AppTheme.allCases.count)
    #expect(symbols.count == AppTheme.allCases.count)
    #expect(subtitles.count == AppTheme.allCases.count)
  }

  @Test("Every theme says something in its subtitle", arguments: AppTheme.allCases)
  func subtitlesAreUseful(theme: AppTheme) {
    // The switcher gives this line a fixed 240pt row and clips at one line, so
    // a subtitle that restates the title spends a row saying nothing.
    #expect(!theme.subtitle.isEmpty)
    #expect(theme.subtitle != theme.title)
  }

  // MARK: - Colour that lives outside the palette

  @Test("Every account colour is visible against every surface it is drawn on",
        arguments: AppTheme.allCases)
  func accountColoursClearTheGraphicalFloor(theme: AppTheme) {
    // The gap `accountMarkersAreLegible` left open for as long as it existed.
    //
    // That test checks the INITIAL against its own fill, which is a closed
    // system — it never asks whether the fill can be seen against the app. Six
    // of the eight failed 3:1 on the shipped light theme, Amber at 1.83:1 on
    // `control`, and nothing said so.
    //
    // The marker survives that: its letter stays readable, so the account is
    // still identifiable. **The thread-list rail does not.** It is two points
    // of pure colour at 0.35 opacity — no letter, no shape, no second channel —
    // and it is the app's only answer to "whose mailbox did this arrive in".
    // Which is why this is measured per THEME against every drawable surface
    // rather than against `base`, and why light appearances resolve to their
    // own set.
    let palette = Palette.for(theme)
    for choice in AccountPalette.choices {
      let resolved = AccountPalette.resolve(choice.hex, isDark: theme.isDark)
      let fill = try! #require(Color(hex: resolved))
      for (surfaceName, surface) in drawableSurfaces(palette) {
        let ratio = contrast(fill, on: surface)
        let measured = String(format: "%.2f", ratio)
        #expect(
          ratio >= 3.0,
          "\(theme.title): \(choice.name) on \(surfaceName) is \(measured):1"
        )
      }
    }
  }

  @Test("Both account sets keep the separation the assignment order promises")
  func accountSetsStayDistinguishable() {
    // The first attempt at the light set normalised all eight to a single
    // luminance. Every one cleared 3:1 and the set was ruined: at equal
    // lightness they separate on HUE ALONE, which is precisely the channel
    // that fails for the reader the ordering comment is written for.
    //
    // What is asserted here is what `AccountPalette` actually promises — that
    // the FIRST TWO ASSIGNED differ in weight as well as hue, and that the set
    // has not been flattened — rather than a floor on all 28 pairs. Slate and
    // Steel are the closest pair in every set and always have been; forcing
    // them apart would mean distorting colours people already recognise to
    // satisfy a property the palette never claimed.
    func spread(_ set: [(name: String, hex: String)]) -> Double {
      let lums = set.map { luminance(Color(hex: $0.hex)!) }
      return lums.max()! - lums.min()!
    }

    for (name, set) in [("dark", AccountPalette.darkChoices),
                        ("light", AccountPalette.lightChoices)] {
      #expect(set.count == AccountPalette.choices.count, "\(name) set has drifted in size")
      #expect(zip(AccountPalette.choices, set).allSatisfy { $0.name == $1.name },
              "\(name) set is no longer index-aligned with the stored vocabulary")
      #expect(Set(set.map(\.hex)).count == set.count, "\(name) set has a duplicate")

      let teal = try! #require(Color(hex: set[0].hex))
      let clay = try! #require(Color(hex: set[1].hex))
      #expect(contrast(teal, on: clay) >= 1.20,
              "\(name): Teal and Clay are \(contrast(teal, on: clay)) apart")
      #expect(spread(set) >= 0.05, "\(name) set has been flattened onto one lightness")
    }
  }

  @Test("A stored account colour always resolves to something renderable",
        arguments: AppTheme.allCases)
  func accountColoursResolve(theme: AppTheme) {
    // Storage and rendering are separate on purpose, so the mapping between
    // them is worth pinning: every stored value must land in the right set, and
    // anything unrecognised must survive rather than be rewritten.
    for (index, choice) in AccountPalette.choices.enumerated() {
      let expected = (theme.isDark ? AccountPalette.darkChoices : AccountPalette.lightChoices)
      #expect(AccountPalette.resolve(choice.hex, isDark: theme.isDark) == expected[index].hex)
      // Case is not guaranteed by whatever wrote the row.
      #expect(AccountPalette.resolve(choice.hex.uppercased(), isDark: theme.isDark)
              == expected[index].hex)
    }
    #expect(AccountPalette.resolve("#123456", isDark: theme.isDark) == "#123456")
  }

  @Test("Every account colour can carry a readable initial")
  func accountMarkersAreLegible() {
    // `AccountPalette` is a SECOND colour system, chosen for mutual
    // distinguishability rather than for contrast, and it never went through
    // the arithmetic the `Theme` tokens did. Its marker drew a white letter on
    // the account's own fill, and seven of the eight hues failed 4.5:1 that
    // way — Amber at 2.61:1, Teal at 2.98:1.
    //
    // Teal and Clay are the first two ASSIGNED, which the palette's own
    // comment picks for separating on lightness so they survive colour
    // blindness. So the letter that exists as the fallback for exactly that
    // reader was the least readable part of the marker.
    // Both sets. The light one is darker throughout, which makes
    // `readableInk` pick white where it picks black on the dark set — a
    // different branch of the same function, and therefore worth measuring
    // rather than assuming.
    for (setName, set) in [("dark", AccountPalette.darkChoices),
                           ("light", AccountPalette.lightChoices)] {
      for choice in set {
        let fill = try! #require(Color(hex: choice.hex))
        let ink = AccountMarker.readableInk(on: fill)
        let ratio = contrast(ink, on: fill)
        #expect(ratio >= 4.5,
                "\(setName) \(choice.name) initial is \(String(format: "%.2f", ratio)):1")
      }
    }
  }

  @Test("The self-tinted chip treatment holds on the surfaces that use it",
        arguments: AppTheme.allCases)
  func selfTintedChipsAreLegible(theme: AppTheme) {
    // The pattern is a label in `accentBlueText` over
    // `accentBlueText.opacity(0.12)` over a surface — Load more and the empty
    // state's action button. A self-tint drags the backdrop TOWARD the label,
    // so the composite can fail where the same token on the bare surface
    // passes, and the old tests never modelled the combination.
    //
    // It holds on `base` and `raised`, which is where those two sites live.
    // It does NOT hold on `control` (4.15-4.39:1) or on `selection`, both of
    // which land back inside the 3.82-4.37 band the split token exists to
    // escape. The remote-image banner sits on `control` and was tinted this
    // way; it is outlined now.
    //
    // So this asserts the two usable surfaces pass AND the two unusable ones
    // still fail — because if a palette change ever made `control` pass, the
    // banner could go back to a fill, and nobody would think to check.
    let palette = Palette.for(theme)
    let accent = palette.accentBlueText

    func ratio(on surface: Color) -> Double {
      contrast(accent, on: flatten(accent.opacity(0.12), on: surface))
    }

    for (name, surface) in [("base", palette.base), ("raised", palette.raised)] {
      #expect(ratio(on: surface) >= 4.5,
              "\(theme.title): the chip treatment is used on \(name) and fails there")
    }

    #expect(ratio(on: palette.control) < 4.5,
            "\(theme.title): control now passes — the banner may use a fill again")
  }
}
