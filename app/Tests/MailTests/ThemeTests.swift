import Foundation
import SwiftUI
import Testing
@testable import Mail

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
    let front = NSColor(ink).usingColorSpace(.sRGB)!
    let back = NSColor(surface).usingColorSpace(.sRGB)!
    let alpha = front.alphaComponent

    let composited = NSColor(
      srgbRed: front.redComponent * alpha + back.redComponent * (1 - alpha),
      green: front.greenComponent * alpha + back.greenComponent * (1 - alpha),
      blue: front.blueComponent * alpha + back.blueComponent * (1 - alpha),
      alpha: 1
    )

    let a = luminance(Color(nsColor: composited))
    let b = luminance(surface)
    return (max(a, b) + 0.05) / (min(a, b) + 0.05)
  }

  @Test("Every ink level is readable on every surface", arguments: AppTheme.allCases)
  func inkMeetsWCAGAA(theme: AppTheme) {
    let palette = Palette.for(theme)
    let surfaces = [
      ("base", palette.base), ("sunken", palette.sunken), ("raised", palette.raised),
    ]
    let inks = [
      ("primary", palette.inkPrimary),
      ("secondary", palette.inkSecondary),
      ("tertiary", palette.inkTertiary),
    ]

    for (surfaceName, surface) in surfaces {
      for (inkName, ink) in inks {
        let ratio = contrast(ink, on: surface)
        #expect(
          ratio >= 4.5,
          "\(theme.title): \(inkName) on \(surfaceName) is \(String(format: "%.2f", ratio)):1"
        )
      }
    }
  }

  @Test("Destructive and action accents are readable", arguments: AppTheme.allCases)
  func accentsMeetWCAGAA(theme: AppTheme) {
    // Red marks destructive actions and failures. Someone who cannot read it
    // cannot tell a failed send from a queued one.
    let palette = Palette.for(theme)
    for (name, accent) in [("blue", palette.accentBlue), ("red", palette.accentRed)] {
      let ratio = contrast(accent, on: palette.base)
      #expect(ratio >= 4.5, "\(theme.title): \(name) is \(String(format: "%.2f", ratio)):1")
    }
  }

  @Test("Ink levels stay distinguishable from each other", arguments: AppTheme.allCases)
  func hierarchyIsPreserved(theme: AppTheme) {
    // Raising tertiary for contrast must not collapse it into secondary —
    // three levels that look like two is a hierarchy that has stopped working.
    let palette = Palette.for(theme)
    let primary = contrast(palette.inkPrimary, on: palette.base)
    let secondary = contrast(palette.inkSecondary, on: palette.base)
    let tertiary = contrast(palette.inkTertiary, on: palette.base)

    #expect(primary > secondary)
    #expect(secondary > tertiary)
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

  @Test("The light palette inverts that order")
  func lightSurfacesAreOrdered() {
    let palette = Palette.light
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
