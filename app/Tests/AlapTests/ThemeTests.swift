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

  @Test("Surfaces stay ordered by lightness", arguments: [AppTheme.signature, .dark])
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

  @Test("Light elevation runs the way light interfaces actually use it")
  func lightSurfacesAreOrdered() {
    // The light palette used to copy the dark palettes' DIRECTION — building
    // upward from `base` — with `base` at #FFFFFF, the lightest possible
    // value, which left `raised` nowhere to go. In a light interface the app
    // background is a tinted grey and raised surfaces approach white.
    let palette = Palette.light
    #expect(luminance(palette.raised) > luminance(palette.base))
    #expect(luminance(palette.base) > luminance(palette.sunken))
    #expect(luminance(palette.control) > luminance(palette.border))
  }

  @Test("Signature preserves the neutral palette's luminance steps")
  func signatureIsARotationNotARepaint() {
    // The whole claim of the signature palette is that it moves hue and NOT
    // lightness, so no pane changes apparent weight. If these drift apart, it
    // has quietly become a different design rather than a tint of the same one.
    let signature = Palette.signature
    let neutral = Palette.dark

    for (a, b) in [
      (signature.base, neutral.base),
      (signature.sunken, neutral.sunken),
      (signature.raised, neutral.raised),
      (signature.control, neutral.control),
    ] {
      let difference = abs(luminance(a) - luminance(b))
      #expect(difference < 0.01, "luminance drifted by \(difference)")
    }
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
    #expect(AppTheme.signature.colorScheme == .dark)
    #expect(AppTheme.dark.colorScheme == .dark)
    #expect(AppTheme.light.colorScheme == .light)
  }

  @Test("Theme identifiers round-trip for persistence", arguments: AppTheme.allCases)
  func rawValuesRoundTrip(theme: AppTheme) {
    // These strings land in UserDefaults, so renaming a case silently resets
    // everyone's choice.
    #expect(AppTheme(rawValue: theme.rawValue) == theme)
  }

  @Test("Every theme has a distinct title and symbol")
  func themesArePresentable() {
    let titles = Set(AppTheme.allCases.map(\.title))
    let symbols = Set(AppTheme.allCases.map(\.symbol))
    #expect(titles.count == AppTheme.allCases.count)
    #expect(symbols.count == AppTheme.allCases.count)
  }
}
