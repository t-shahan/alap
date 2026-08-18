import Foundation
import Testing
@testable import Alap

/// Row decoding and the reading pane's HTML document.
///
/// Decoding is tested against real JSON because that is where schema drift
/// actually bites: rename a column in Postgres and an optional field silently
/// becomes nil rather than failing to compile. `rfc822MessageId` going quiet
/// would break reply threading with no visible symptom on this side.
@MainActor
struct RenderingTests {
  // MARK: - Decoding

  @Test("A thread decodes every field the UI depends on")
  func threadDecodes() throws {
    let json = Fixtures.thread(id: "th1", subject: "Design review",
                               unreadCount: 2, isStarred: true)
    let row = try JSONDecoder().decode(ThreadRow.self, from: Data(json.utf8))

    #expect(row.id == "th1")
    #expect(row.subject == "Design review")
    #expect(row.unreadCount == 2)
    #expect(row.isStarred)
    // Needed to file a reply into Gmail's existing conversation.
    #expect(row.remoteThreadId == "t1")
  }

  @Test("A message decodes its Message-ID, which reply threading depends on")
  func messageDecodesThreadingId() throws {
    let json = Fixtures.message(id: "m1", rfc822MessageId: "abc@example.com")
    let row = try JSONDecoder().decode(MessageRow.self, from: Data(json.utf8))

    #expect(row.rfc822MessageId == "abc@example.com")
    #expect(row.fromEmail == "ada@example.com")
    #expect(row.toRecipients.first?.email == "me@example.com")
  }

  @Test("A missing Message-ID decodes as nil rather than failing")
  func absentMessageIdIsTolerated() throws {
    // Older mail, and anything Gmail did not return headers for.
    let json = Fixtures.message(id: "m1", rfc822MessageId: nil)
    let row = try JSONDecoder().decode(MessageRow.self, from: Data(json.utf8))
    #expect(row.rfc822MessageId == nil)
  }

  @Test("An attachment decodes its download columns")
  func attachmentDecodes() throws {
    let json = Fixtures.attachment(id: "a1", filename: "invoice.pdf",
                                   localPath: "/tmp/x", contentHash: "abc")
    let row = try JSONDecoder().decode(AttachmentRow.self, from: Data(json.utf8))

    #expect(row.filename == "invoice.pdf")
    #expect(row.localPath == "/tmp/x")
    #expect(row.contentHash == "abc")
    #expect(row.canDownload)
  }

  @Test("An attachment with no remote id cannot be downloaded")
  func attachmentWithoutRemoteId() throws {
    let json = Fixtures.attachment(id: "a1", remoteAttachmentId: nil)
    let row = try JSONDecoder().decode(AttachmentRow.self, from: Data(json.utf8))
    #expect(!row.canDownload)
  }

  @Test("readyFile reports the disk, not the recorded path")
  func readyFileChecksTheDisk() throws {
    let file = Fixtures.temporaryFile()
    defer { try? FileManager.default.removeItem(at: file) }

    let present = try JSONDecoder().decode(
      AttachmentRow.self,
      from: Data(Fixtures.attachment(id: "a1", localPath: file.path).utf8))
    #expect(present.readyFile == file)

    let missing = try JSONDecoder().decode(
      AttachmentRow.self,
      from: Data(Fixtures.attachment(id: "a1", localPath: "/tmp/gone-\(UUID())").utf8))
    #expect(missing.readyFile == nil)

    let never = try JSONDecoder().decode(
      AttachmentRow.self,
      from: Data(Fixtures.attachment(id: "a1", localPath: nil).utf8))
    #expect(never.readyFile == nil)
  }

  @Test("Sizes render in human units")
  func displaySize() throws {
    let row = try JSONDecoder().decode(
      AttachmentRow.self,
      from: Data(Fixtures.attachment(id: "a1", sizeBytes: 1_048_576).utf8))
    #expect(row.displaySize.contains("MB"))
  }

  // MARK: - The rendered document
  //
  // Mail is hostile input. Sanitisation happens on ingest in the C++ engine,
  // and this document is the second line of defence — so these assert the
  // defence is actually present in the markup we hand WebKit.

  private func message(html: String) throws -> MessageRow {
    let json = """
      {"id":"m1","threadId":"th1","fromName":"Ada","fromEmail":"ada@example.com",
       "toRecipients":[],"ccRecipients":[],"subject":"S","snippet":"s",
       "sentAt":1700000000000,"isRead":true,"isStarred":false,
       "hasAttachments":false,"rfc822MessageId":null,
       "body":{"messageId":"m1","htmlBody":\(jsonString(html)),"textBody":null},
       "attachments":[]}
      """
    return try JSONDecoder().decode(MessageRow.self, from: Data(json.utf8))
  }

  private func plainMessage(text: String) throws -> MessageRow {
    let json = """
      {"id":"m2","threadId":"th1","fromName":"Ada","fromEmail":"ada@example.com",
       "toRecipients":[],"ccRecipients":[],"subject":"S","snippet":"s",
       "sentAt":1700000000000,"isRead":true,"isStarred":false,
       "hasAttachments":false,"rfc822MessageId":null,
       "body":{"messageId":"m2","htmlBody":null,"textBody":\(jsonString(text))},
       "attachments":[]}
      """
    return try JSONDecoder().decode(MessageRow.self, from: Data(json.utf8))
  }

  private func jsonString(_ value: String) -> String {
    String(data: try! JSONSerialization.data(withJSONObject: [value]), encoding: .utf8)!
      .dropFirst().dropLast().description
  }

  @Test("The document carries a restrictive CSP")
  func documentHasCSP() throws {
    let document = MessageDocument.build(for: [try message(html: "<p>hi</p>")], isDark: false)

    #expect(document.contains("Content-Security-Policy"))
    // default-src 'none' is what stops a remote tracking pixel from phoning
    // home even if sanitisation on ingest ever missed one.
    #expect(document.contains("default-src 'none'"))
    #expect(document.contains("form-action 'none'"))
    #expect(document.contains("base-uri 'none'"))
  }

  @Test("The CSP permits no remote image origin")
  func blocksRemoteImages() throws {
    let document = MessageDocument.build(for: [try message(html: "<p>hi</p>")], isDark: false)

    // img-src allows only cid: and data:. An https: origin here would re-enable
    // the tracking pixels the engine strips on ingest.
    #expect(!document.contains("img-src https:"))
    #expect(!document.contains("img-src *"))
  }

  @Test("Mail that brings its own colours renders on a light canvas")
  func colouredHtmlIgnoresTheTheme() throws {
    // Mail assumes a light page under it. A sender who paints a white table
    // but leaves the text at its default got our dark-theme grey on their
    // white — 11 of 30 real messages carried text under 2:1 contrast.
    let message = try message(html: ##"<table bgcolor="#ffffff"><tr><td>hi</td></tr></table>"##)
    let light = MessageDocument.build(for: [message], isDark: false)
    let dark = MessageDocument.build(for: [message], isDark: true)

    #expect(light == dark, "coloured mail should not follow the app theme")
    #expect(dark.contains("background: #ffffff"), "the light page must be painted")
    #expect(dark.contains("color-scheme: light"))
  }

  @Test("Mail that brings no colours follows the app theme")
  func colourlessHtmlFollowsTheTheme() throws {
    // A two-line reply has nothing to clash with, and rendering it as a bright
    // slab in a dark window is our doing rather than the sender's.
    let message = try message(html: "<p>hi</p><p>see you then</p>")
    let dark = MessageDocument.build(for: [message], isDark: true)
    let light = MessageDocument.build(for: [message], isDark: false)

    #expect(dark != light, "colourless mail should follow the theme")
    #expect(dark.contains("background: transparent"))
    #expect(dark.contains("color-scheme: dark"))
  }

  @Test("One colour anywhere is enough to keep the light page")
  func oneColourKeepsItLight() throws {
    // Guessing wrong toward light costs a white background nobody wanted;
    // guessing wrong toward dark costs dark text on a dark background, which
    // cannot be read at all. The threshold is deliberately one mention.
    for coloured in [##"<p style="color:#333">hi</p>"##,
                     ##"<td bgcolor="#eee">hi</td>"##,
                     ##"<font color="red">hi</font>"##] {
      let message = try message(html: coloured)
      let dark = MessageDocument.build(for: [message], isDark: true)
      #expect(dark.contains("color-scheme: light"), "\(coloured) should stay light")
    }
  }

  @Test("Plain text still follows the app theme")
  func plainTextFollowsTheTheme() throws {
    // Plain text has no colours of its own, so there is nothing to clash with
    // and every reason to match the surrounding window.
    let message = try plainMessage(text: "hello")
    let light = MessageDocument.build(for: [message], isDark: false)
    let dark = MessageDocument.build(for: [message], isDark: true)

    #expect(light != dark, "the theme argument should still change plain text")
    #expect(dark.contains("background: transparent"))
  }

  @Test("An empty thread still produces a valid document")
  func handlesNoMessages() {
    let document = MessageDocument.build(for: [], isDark: false)
    #expect(document.contains("<html") || document.contains("<!DOCTYPE"))
  }

  // MARK: - HTML to text

  @Test("Script and style contents are dropped, not surfaced as text")
  func stripsExecutableContent() {
    // This is a readability fallback, not a sanitiser, but leaking the body of
    // a <script> into the snippet would be both ugly and revealing.
    let text = plainTextFromHTML("<p>Hello</p><script>alert('x')</script><style>p{}</style>")

    #expect(text.contains("Hello"))
    #expect(!text.contains("alert"))
    #expect(!text.contains("p{}"))
  }

  @Test("Entities are decoded", arguments: [
    ("a&amp;b", "a&b"), ("a&lt;b", "a<b"), ("a&gt;b", "a>b"),
    ("a&nbsp;b", "a b"), ("a&#39;b", "a'b"), ("a&mdash;b", "a—b"),
  ])
  func decodesEntities(html: String, expected: String) {
    // Gmail HTML-escapes snippets, so "Next week&#39;s menu" arrives verbatim.
    //
    // Each case is embedded between two letters rather than tested alone: the
    // function trims, so a lone "&nbsp;" correctly collapses to empty string
    // and would prove nothing about whether it was decoded.
    #expect(plainTextFromHTML(html).contains(expected))
  }

  @Test("Entity decoding does not double-decode")
  func doesNotDoubleDecode() {
    // "&amp;lt;" is a literal "&lt;", not a "<". Decoding twice would turn
    // text a sender deliberately escaped into markup.
    #expect(plainTextFromHTML("a&amp;lt;b").contains("a&lt;b"))
  }
}

/// Remote image blocking, and the way back from it.
///
/// A remote image in mail is a tracking pixel far more often than it is a
/// picture: loading one tells the sender the message was opened, by whom, and
/// roughly from where. So the default is to withhold them — but withholding
/// them and discarding the URL made the decision permanent, which is a
/// different thing from making it safe.
@MainActor
struct RemoteImageTests {
  private func message(html: String) throws -> MessageRow {
    let escaped = String(
      data: try JSONSerialization.data(withJSONObject: [html]), encoding: .utf8)!
      .dropFirst().dropLast()
    let json = """
      {"id":"m1","threadId":"th1","fromName":"Ada","fromEmail":"ada@example.com",
       "toRecipients":[],"ccRecipients":[],"subject":"S","snippet":"s",
       "sentAt":1700000000000,"isRead":true,"isStarred":false,
       "hasAttachments":false,"rfc822MessageId":null,
       "body":{"messageId":"m1","htmlBody":\(escaped),"textBody":null},
       "attachments":[]}
      """
    return try JSONDecoder().decode(MessageRow.self, from: Data(json.utf8))
  }

  private let blocked =
    #"<p>hi</p><img data-blocked="remote" data-blocked-src="https://t.example/a.gif" alt="a">"#

  @Test("Blocked images are counted so the offer can be specific")
  func countsBlockedImages() throws {
    // "Images blocked" is vague; "3 remote images not loaded" is a fact.
    let one = try message(html: blocked)
    #expect(MessageDocument.blockedImageCount(in: [one]) == 1)

    let three = try message(html: blocked + blocked + blocked)
    #expect(MessageDocument.blockedImageCount(in: [three]) == 3)

    let none = try message(html: "<p>nothing here</p>")
    #expect(MessageDocument.blockedImageCount(in: [none]) == 0)
  }

  @Test("While blocking, the URL is present but inert")
  func blockedDocumentCannotLoadRemoteImages() throws {
    let document = MessageDocument.build(
      for: [try message(html: blocked)], isDark: true, showRemoteImages: false)

    // The URL survives so it CAN be restored...
    #expect(document.contains("data-blocked-src="))
    // ...but nothing will fetch it: no live src, and the CSP forbids https.
    #expect(!document.contains(" src=\"https://"))
    #expect(!document.contains("img-src cid: data: https:"))
  }

  @Test("Images load by default")
  func imagesLoadByDefault() throws {
    // This assertion used to read the other way. Mail is built out of its
    // images, and withholding them leaves a skeleton of empty cells rather
    // than a clean text version — so the default changed and the privacy
    // control moved into Settings, where it says what it costs.
    let document = MessageDocument.build(for: [try message(html: blocked)], isDark: true)

    #expect(document.contains("src=\"https://t.example/a.gif\""))
    #expect(document.contains("img-src cid: data: https:"))
  }

  @Test("Loading images restores the src and widens the CSP together")
  func loadingRestoresBoth() throws {
    // Either half alone is useless: a restored src with the old CSP is blocked
    // by WebKit, and a widened CSP with no src has nothing to load.
    let document = MessageDocument.build(
      for: [try message(html: blocked)], isDark: true, showRemoteImages: true)

    #expect(document.contains("src=\"https://t.example/a.gif\""))
    #expect(document.contains("img-src cid: data: https:"))
    #expect(!document.contains("data-blocked-src="))
  }

  @Test("Loading images does not widen what may be INTERPRETED")
  func loadingDoesNotRelaxScriptPolicy() throws {
    // The one thing that must not follow from "show me the pictures".
    let document = MessageDocument.build(
      for: [try message(html: blocked)], isDark: true, showRemoteImages: true)

    #expect(document.contains("default-src 'none'"))
    #expect(!document.contains("script-src"))
    #expect(document.contains("form-action 'none'"))
  }

  @Test("Only the sanitiser's own attribute is restored")
  func onlyRestoresTheSanitisersAttribute() throws {
    // Checked with a LEADING SPACE. `data-evil-src="` ends in `src="`, so the
    // naive substring matches the very attribute this distinguishes from a
    // live one — the same trap as the C++ side of this test.
    let sneaky = try message(
      html: #"<img data-evil-src="https://evil.example/x.gif" alt="x">"#)
    let document = MessageDocument.build(for: [sneaky], isDark: true,
                                         showRemoteImages: true)
    #expect(!document.contains(" src=\"https://evil.example"))
  }
}
