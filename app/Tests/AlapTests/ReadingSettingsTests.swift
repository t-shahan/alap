import Testing
@testable import Alap

/// The default is the whole point of this change, so it is what gets asserted.
@MainActor
@Suite("Reading settings")
struct ReadingSettingsTests {
  @Test("Remote images load unless the document is told otherwise")
  func remoteImagesDefaultOn() {
    let html = MessageDocument.build(for: [], isDark: true)
    // The CSP is what actually admits or refuses the load, so it is the
    // honest thing to assert: a permissive default here with a closed CSP
    // would render nothing and look like the setting did not work.
    #expect(html.contains("img-src cid: data: https:"))
  }

  @Test("Turning it off closes the CSP as well as the markup")
  func remoteImagesOffClosesCSP() {
    let html = MessageDocument.build(for: [], isDark: true, showRemoteImages: false)
    #expect(html.contains("img-src cid: data:"))
    #expect(!html.contains("https:"))
  }

  @Test("A blocked image keeps its box rather than collapsing")
  func blockedImagesKeepLayout() {
    let html = MessageDocument.build(for: [], isDark: true, showRemoteImages: false)
    // `display: none` removed the element from layout entirely, which is what
    // made image-sliced messages fall apart into stray padding.
    #expect(!html.contains("img[data-blocked] { display: none; }"))
    #expect(html.contains("img[data-blocked]"))
  }
}
