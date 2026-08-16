import Foundation
import Testing
@testable import Mail

/// Resolution of `cid:` image references.
///
/// This is the one place the HTML renderer is allowed to reach the local disk,
/// and the content driving it — Content-IDs, MIME types, filenames — all comes
/// from email, which is attacker-controlled. The security properties are
/// therefore asserted rather than assumed.
@MainActor
struct InlineImageTests {
  /// A handler rooted in a temp directory, with real files in it.
  private func handler(files: [String: Data]) -> (InlineImageHandler, URL, [String: URL]) {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("cid-tests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    var map: [String: URL] = [:]
    for (contentId, bytes) in files {
      let file = root.appendingPathComponent(UUID().uuidString)
      try? bytes.write(to: file)
      map[contentId] = file
    }

    let handler = InlineImageHandler(root: root)
    handler.setResolvable(map)
    return (handler, root, map)
  }

  private var pngBytes: Data {
    Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D])
  }

  // MARK: - Resolution

  @Test("A known content id resolves to its file")
  func resolvesKnownId() {
    let (handler, _, map) = handler(files: ["google_logo": pngBytes])
    #expect(handler.lookup("google_logo")?.lastPathComponent
            == map["google_logo"]?.lastPathComponent)
  }

  @Test("An unknown content id resolves to nothing")
  func rejectsUnknownId() {
    // The map holds ONE conversation, so this is also what stops a crafted
    // message from addressing another message's attachments.
    let (handler, _, _) = handler(files: ["google_logo": pngBytes])
    #expect(handler.lookup("someone_elses_image") == nil)
  }

  @Test("Matching tolerates case, since senders are inconsistent")
  func matchingFoldsCase() {
    let (handler, _, _) = handler(files: ["Image002.JPG@01D1602D": pngBytes])
    #expect(handler.lookup("image002.jpg@01d1602d") != nil)
  }

  @Test("Content ids that look like paths resolve to nothing",
        arguments: ["../../../etc/passwd", "/etc/passwd", "..", ""])
  func rejectsPathLikeIds(hostile: String) {
    let (handler, _, _) = handler(files: ["logo": pngBytes])
    #expect(handler.lookup(hostile) == nil)
  }

  @Test("A file outside the cache is refused even when mapped to")
  func refusesFilesOutsideTheRoot() {
    // The map is built from database rows. A tampered local_path must not
    // become a read of an arbitrary file on disk.
    let (handler, _, _) = handler(files: ["logo": pngBytes])
    handler.setResolvable(["escape": URL(fileURLWithPath: "/etc/passwd")])
    #expect(handler.lookup("escape") == nil)
  }

  @Test("Replacing the map drops what the previous thread could reach")
  func mapIsReplacedNotAccumulated() {
    let (handler, _, _) = handler(files: ["first": pngBytes])
    #expect(handler.lookup("first") != nil)

    handler.setResolvable([:])
    #expect(handler.lookup("first") == nil)
  }

  // MARK: - Content typing

  @Test("Image formats are recognised from their bytes", arguments: [
    ([0x89, 0x50, 0x4E, 0x47], "image/png"),
    ([0xFF, 0xD8, 0xFF, 0xE0], "image/jpeg"),
    ([0x47, 0x49, 0x46, 0x38], "image/gif"),
    ([0x42, 0x4D, 0x00, 0x00], "image/bmp"),
  ])
  func sniffsImageTypes(bytes: [UInt8], expected: String) {
    let (handler, root, _) = handler(files: [:])
    let data = Data(bytes + Array(repeating: 0, count: 12))
    #expect(handler.imageMIMEType(for: root, data: data) == expected)
  }

  @Test("Anything that is not an image is refused", arguments: [
    "<html><script>alert(1)</script></html>",
    "%PDF-1.4",
    "GIF",                    // truncated, not a real header
    "",
  ])
  func refusesNonImages(content: String) {
    // The type is sniffed rather than taken from the attachment row, because
    // that row's mime_type came from the message. A part merely CLAIMING to be
    // a PNG must not be served as one into this document's origin.
    let (handler, root, _) = handler(files: [:])
    #expect(handler.imageMIMEType(for: root, data: Data(content.utf8)) == nil)
  }

  @Test("SVG is refused despite being an image format")
  func refusesSVG() {
    // SVG is a document format that can carry script. Serving it as an image
    // would reintroduce the execution vector the sanitiser exists to remove.
    let (handler, root, _) = handler(files: [:])
    let svg = #"<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>"#
    #expect(handler.imageMIMEType(for: root, data: Data(svg.utf8)) == nil)
  }

  @Test("WEBP is recognised only with the full RIFF container")
  func recognisesWebP() {
    let (handler, root, _) = handler(files: [:])
    var valid = Data("RIFF".utf8)
    valid.append(Data([0, 0, 0, 0]))
    valid.append(Data("WEBP".utf8))
    #expect(handler.imageMIMEType(for: root, data: valid) == "image/webp")

    var riffOnly = Data("RIFF".utf8)
    riffOnly.append(Data([0, 0, 0, 0]))
    riffOnly.append(Data("WAVE".utf8))
    #expect(handler.imageMIMEType(for: root, data: riffOnly) == nil)
  }
}
