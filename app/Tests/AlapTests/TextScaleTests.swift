import SwiftUI
import Testing
@testable import Alap

/// How much the message body grows with the reader's text-size preference.
///
/// The scope is deliberately narrow and the reason is platform, not laziness:
/// macOS gates its text-size setting behind a per-app allowlist rather than
/// broadcasting it, and a reader who needs everything bigger uses Zoom, which
/// is pixel scaling and indifferent to how fonts are specified. What is worth
/// scaling is the surface someone actually sits and reads.
struct TextScaleTests {
  @Test("The default size renders the design exactly")
  func defaultIsUnscaled() {
    // Anything else would mean the design is authored against a size nobody
    // has, which is the trap D1 was about.
    #expect(TextScale.multiplier(for: .large) == TextScale.reference)
  }

  @Test("Bigger settings produce bigger text, in order",
        arguments: [(DynamicTypeSize.small, DynamicTypeSize.large),
                    (.large, .xLarge),
                    (.xLarge, .xxLarge),
                    (.xxLarge, .xxxLarge)])
  func scaleIsMonotonic(pair: (DynamicTypeSize, DynamicTypeSize)) {
    #expect(TextScale.multiplier(for: pair.0) < TextScale.multiplier(for: pair.1))
  }

  @Test("The accessibility sizes share a ceiling", arguments: [
    DynamicTypeSize.accessibility1, .accessibility2, .accessibility3,
    .accessibility4, .accessibility5,
  ])
  func accessibilitySizesAreCapped(size: DynamicTypeSize) {
    // Not an oversight. A message is a sender's layout, usually a table with
    // pixel widths; past roughly 1.4 the document outgrows the pane, the fit
    // pass scales the whole thing back down, and the text ends up SMALLER than
    // it was. The cap is where growing stops helping.
    #expect(TextScale.multiplier(for: size) == 1.40)
  }

  @Test("The scale reaches the document")
  func scaleReachesTheCSS() throws {
    let message = try Self.plainMessage()

    let normal = MessageDocument.build(for: [message], isDark: true).html
    let large = MessageDocument.build(for: [message], isDark: true,
                                      textScale: 1.25).html

    #expect(normal.contains("font: 14px/1.55"))
    #expect(large.contains("font: 17.5px/1.55"))
  }

  @Test("Sizes land on half-points, never on a long fraction")
  func sizesAreRounded() throws {
    // WebKit lays out on fractional pixels, so whole-point rounding would make
    // the smaller steps of the scale indistinguishable — but an unrounded
    // 14 × 1.08 is `15.120000000000001` in the stylesheet.
    let message = try Self.plainMessage()
    let document = MessageDocument.build(for: [message], isDark: true,
                                         textScale: 1.08).html

    #expect(document.contains("font: 15px/1.55"))
    #expect(!document.contains("0000"))
  }

  private static func plainMessage() throws -> MessageRow {
    let json = """
      {"id":"m1","threadId":"th1","fromName":"Ada","fromEmail":"ada@example.com",
       "toRecipients":[],"ccRecipients":[],"subject":"S","snippet":"s",
       "sentAt":1700000000000,"isRead":true,"isStarred":false,
       "hasAttachments":false,"rfc822MessageId":null,
       "body":{"messageId":"m1","htmlBody":"<p>hi</p>","textBody":null},
       "attachments":[]}
      """
    return try JSONDecoder().decode(MessageRow.self, from: Data(json.utf8))
  }
}
