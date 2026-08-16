import Foundation
import UniformTypeIdentifiers
import WebKit

/// Serves `cid:` image references out of the downloaded attachment cache.
///
/// ## What a cid: URL is
///
/// A message with embedded images carries them as ordinary MIME parts, each
/// tagged with a `Content-ID`, and the HTML refers to them as
/// `<img src="cid:that-id">`. Nothing resolves that by default, which is why
/// every message with a logo or an inline screenshot rendered as a broken box.
///
/// ## Why a scheme handler rather than data: URLs
///
/// Inlining the bytes as base64 `data:` URLs would work and was tempting,
/// because the document is already assembled as a string. It was rejected on
/// size: base64 inflates by a third, the document is rebuilt on every theme
/// change and selection, and a newsletter with a dozen images would push a
/// multi-megabyte string through `loadHTMLString` on the main thread on every
/// keystroke of arrow-key navigation. A scheme handler streams each image once,
/// lazily, and only for images actually laid out.
///
/// ## Trust boundary
///
/// This is the ONE place the renderer is allowed to reach the local disk, so it
/// is deliberately narrow:
///
///   - It resolves only from a map handed to it per thread. A `cid:` naming
///     something outside the open conversation resolves to nothing, so a
///     crafted message cannot address another message's attachments.
///   - It refuses to serve anything that is not an image, whatever the row
///     claims. Mail is attacker-controlled, and a part labelled `text/html`
///     served into this document would run as same-origin content.
///   - It resolves paths and requires them to sit inside the blob cache, so a
///     tampered `local_path` cannot turn into an arbitrary file read.
///
/// The CSP (`img-src cid: data:`) is the outer layer; this is the inner one.
final class InlineImageHandler: NSObject, WKURLSchemeHandler {
  /// Content-ID → file on disk, for the thread currently displayed.
  ///
  /// Replaced wholesale when the selection moves rather than accumulated, so
  /// the reachable set is always exactly one conversation's images.
  private var resolvable: [String: URL] = [:]
  private let root: URL

  /// - Parameter root: The attachment cache. Everything served must be inside.
  init(root: URL = InlineImageHandler.defaultRoot) {
    self.root = root.standardizedFileURL
  }

  static var defaultRoot: URL {
    let home = FileManager.default.homeDirectoryForCurrentUser
    return home.appendingPathComponent("Library/Caches/dev.local.mailapp/Attachments")
  }

  @MainActor
  func setResolvable(_ map: [String: URL]) {
    resolvable = map
  }

  // MARK: - WKURLSchemeHandler

  func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
    guard let url = task.request.url else {
      task.didFailWithError(URLError(.badURL))
      return
    }

    // `cid:google_logo` parses with an empty host, so the identifier is the
    // path — and it may be percent-encoded, since it can contain `@`.
    let identifier = (url.absoluteString.dropFirst("cid:".count))
      .removingPercentEncoding ?? String(url.absoluteString.dropFirst("cid:".count))

    guard let file = lookup(identifier) else {
      // Not an error worth surfacing: an image whose bytes have not downloaded
      // yet is a normal transient state, and the document re-renders when they
      // arrive.
      task.didFailWithError(URLError(.fileDoesNotExist))
      return
    }

    guard let data = try? Data(contentsOf: file), let mime = imageMIMEType(for: file, data: data)
    else {
      task.didFailWithError(URLError(.cannotDecodeContentData))
      return
    }

    let response = URLResponse(
      url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: nil)
    task.didReceive(response)
    task.didReceive(data)
    task.didFinish()
  }

  func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}

  // MARK: - Resolution

  /// Internal rather than private: this is the trust boundary, so it is
  /// exactly the part that must be tested directly.
  func lookup(_ identifier: String) -> URL? {
    // Content-IDs are case-sensitive in principle; senders are inconsistent in
    // practice, so an exact match is tried first and a folded one second.
    let candidate =
      resolvable[identifier]
      ?? resolvable.first { $0.key.caseInsensitiveCompare(identifier) == .orderedSame }?.value
    guard let candidate else { return nil }

    // The map is built from database rows. Requiring the resolved path to sit
    // inside the cache means a tampered `local_path` cannot become a read of
    // anything else on disk.
    let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath()
    guard resolved.path.hasPrefix(root.resolvingSymlinksInPath().path) else { return nil }
    return resolved
  }

  /// The image type of `data`, or nil when it is not an image at all.
  ///
  /// Sniffed from the bytes rather than trusted from the attachment row.
  /// `mime_type` comes from the message, which is attacker-controlled; serving
  /// a part that merely *claims* to be a PNG as `image/png` would let a sender
  /// place arbitrary content inside this document's origin.
  func imageMIMEType(for file: URL, data: Data) -> String? {
    let signatures: [(bytes: [UInt8], mime: String)] = [
      ([0x89, 0x50, 0x4E, 0x47], "image/png"),
      ([0xFF, 0xD8, 0xFF], "image/jpeg"),
      ([0x47, 0x49, 0x46, 0x38], "image/gif"),
      ([0x42, 0x4D], "image/bmp"),
    ]

    let prefix = [UInt8](data.prefix(12))
    for signature in signatures where prefix.starts(with: signature.bytes) {
      return signature.mime
    }
    // RIFF....WEBP
    if prefix.count >= 12, Array(prefix[0..<4]) == Array("RIFF".utf8),
       Array(prefix[8..<12]) == Array("WEBP".utf8) {
      return "image/webp"
    }
    // SVG is deliberately absent: it is a document format that can carry
    // script, and treating it as an image would reintroduce exactly the
    // execution vector the sanitiser exists to remove.
    return nil
  }
}
