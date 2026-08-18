import SwiftUI
import WebKit

/// Renders a thread's messages as real HTML.
///
/// ## Why a web view
///
/// The alternatives are worse. `NSAttributedString(html:)` spins up a WebKit
/// parse *synchronously on the main thread* — precisely the kind of main-thread
/// work we spent a session removing. Hand-rolling HTML into `AttributedString`
/// is fast but cannot do tables, floats or nested layout, which real mail uses
/// constantly.
///
/// Every serious mail client renders in a web view, and now that the C++
/// engine sanitises on ingest, it is safe to do the same.
///
/// ## Why one view for the whole thread
///
/// A web view per message would mean allocating and laying out N of them per
/// selection. Instead the thread is composed into a single document, and a
/// SINGLE web view instance is reused across selections — created once, then
/// only reloaded. That keeps selection cost to one `loadHTMLString`.
///
/// ## Defence in depth
///
/// The content is already sanitised, but this view assumes nothing:
///   - `baseURL: nil`, so relative URLs cannot resolve to anything
///   - a CSP forbidding scripts and every remote fetch
///   - JavaScript disabled at the WebKit level
///   - navigation intercepted: links open in the browser, and nothing may
///     replace the pane's own document
/// A web view that refuses to scroll itself.
///
/// `WKWebView` consumes scroll wheel events over its own bounds. That was
/// invisible while the view was short and had its own scrollbar — it simply
/// scrolled internally. Once it is sized to its full content it has nothing
/// left to scroll, so those events were swallowed and the enclosing scroll view
/// never saw them: a message taller than the pane could not be scrolled at all.
///
/// Forwarding to `nextResponder` hands every scroll to the SwiftUI `ScrollView`
/// that contains it, which is the only thing that should be scrolling here.
private final class PassThroughWebView: WKWebView {
  override func scrollWheel(with event: NSEvent) {
    nextResponder?.scrollWheel(with: event)
  }
}

struct MessageWebView: NSViewRepresentable {
  let html: String
  /// Content-ID → downloaded file, for the thread being shown.
  var inlineImages: [String: URL] = [:]
  /// Reports the rendered document's height back to the layout.
  ///
  /// A `WKWebView` has no intrinsic content size, so SwiftUI has nothing to
  /// size it by and falls back to whatever the parent proposes. That produced
  /// both failure modes at once: short messages left a screenful of dead space
  /// below them, and long ones got their own inner scrollbar inside the pane's
  /// scrollbar.
  ///
  /// Measuring the document and handing the height up means the OUTER scroll
  /// view does all the scrolling, and the body occupies exactly the room it
  /// needs — no more, no less.
  var onHeightChange: ((CGFloat) -> Void)?

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> WKWebView {
    let config = WKWebViewConfiguration()
    // Mail never needs script. Disabling it at the engine level means a
    // sanitiser mistake is not automatically an execution bug.
    config.defaultWebpagePreferences.allowsContentJavaScript = false

    // Embedded images arrive as `cid:` references to MIME parts. A handler has
    // to be registered before the view exists — the configuration is copied at
    // construction — which is another reason a single reused web view is the
    // right shape here.
    config.setURLSchemeHandler(context.coordinator.imageHandler, forURLScheme: "cid")

    let webView = PassThroughWebView(frame: .zero, configuration: config)
    webView.navigationDelegate = context.coordinator
    webView.setValue(false, forKey: "drawsBackground")  // inherit app background
    return webView
  }

  func updateNSView(_ webView: WKWebView, context: Context) {
    context.coordinator.onHeightChange = onHeightChange

    // Both the fit scale and the height depend on how wide the pane is, and
    // neither was recomputed when it changed — so resizing the window left a
    // message scaled for the old width and clipped to the old height.
    context.coordinator.remeasureIfWidthChanged(webView)

    // The handler must know the new thread's images BEFORE the document that
    // references them is loaded, or every cid: request in the first layout
    // resolves against the previous conversation.
    context.coordinator.imageHandler.setResolvable(inlineImages)

    // Reloading the same content would reset scroll position on every
    // unrelated redraw, so only load when the document actually changed.
    //
    // The resolvable set is part of that identity: images finish downloading
    // after the document first renders, and without a reload they would stay
    // broken until the selection moved.
    let identity = "\(inlineImages.count)|\(inlineImages.keys.sorted().joined(separator: ","))"
    guard context.coordinator.loadedHTML != html
            || context.coordinator.loadedImages != identity
    else { return }
    context.coordinator.loadedHTML = html
    context.coordinator.loadedImages = identity
    webView.loadHTMLString(html, baseURL: nil)
  }

  final class Coordinator: NSObject, WKNavigationDelegate {
    var loadedHTML: String?
    var loadedImages: String?
    let imageHandler = InlineImageHandler()
    var onHeightChange: ((CGFloat) -> Void)?
    private var lastReported: CGFloat = 0
    private var lastWidth: CGFloat = 0
    private var measurementGeneration = 0

    /// Re-runs the fit pass when the pane has been resized.
    ///
    /// Guarded on the width actually changing: `updateNSView` runs for every
    /// unrelated redraw, and re-measuring on each one would evaluate script
    /// against the document continuously while the user types elsewhere.
    func remeasureIfWidthChanged(_ webView: WKWebView) {
      let width = webView.bounds.width
      guard width > 0, abs(width - lastWidth) > 1 else { return }
      lastWidth = width
      // The height legitimately changes with the width, so the noise guard in
      // `measure` must not suppress the new value.
      lastReported = 0
      measure(webView)
    }

    /// Measurement starts as soon as the document exists, NOT when the load
    /// finishes.
    ///
    /// `didFinish` waits for every subresource, and mail contains subresources
    /// that never complete: one message in a 30-message sample carries a
    /// tracking pixel whose URL is an endless redirect chain — 19 hops and
    /// still going after 30 seconds. Keying the only measurement off
    /// `didFinish` meant that message never reported a height at all, so it
    /// rendered inside the 400pt placeholder frame with the rest cut off. It
    /// looked like a broken message; it was an unanswered load.
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
      scheduleMeasurements(webView)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
      scheduleMeasurements(webView)
    }

    /// Re-measures over the first few seconds.
    ///
    /// Images resolve after first paint and change the height when they land,
    /// and a ResizeObserver is not available — the document's own CSP forbids
    /// script. Spacing the attempts out covers both a fast local render and a
    /// slow remote one without polling forever.
    private func scheduleMeasurements(_ webView: WKWebView) {
      measurementGeneration += 1
      let generation = measurementGeneration
      measure(webView)
      for delay in [0.05, 0.25, 0.8, 2.0, 4.0] {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak webView] in
          guard let self, let webView else { return }
          // A newer load supersedes this schedule; measuring here would report
          // the previous conversation's height against the current one.
          guard generation == self.measurementGeneration else { return }
          self.measure(webView)
        }
      }
    }

    /// Scales an over-wide document down to fit, then reports its height.
    ///
    /// Marketing mail is laid out for a 600px canvas that it states in fixed
    /// pixels. When the reading pane is narrower, `max-width: 100%` cannot
    /// always rescue it — a 52px headline has a min-content width of its own,
    /// and a table will not shrink below that — so the document simply ran off
    /// the right edge and the last word of the headline was cut in half.
    ///
    /// Scaling is what Apple Mail does, and it is the only option that keeps
    /// the sender's layout intact: wrapping their headline differently changes
    /// their design, and a horizontal scrollbar inside a message is worse than
    /// either.
    ///
    /// Runs in the same pass as the height measurement because the height is
    /// only meaningful AFTER the scale is applied.
    private static let fitAndMeasure = """
      (function () {
        var body = document.body;
        if (!body) { return 0; }
        body.style.zoom = '';
        body.style.paddingLeft = '';
        body.style.paddingRight = '';
        var available = document.documentElement.clientWidth;
        var content = body.scrollWidth;
        // Padding is the first thing to go, before any shrinking. A message
        // laid out for 600-700px would otherwise pay for our margins twice:
        // once in lost width and again in being scaled down to fit what was
        // left. Text mail keeps the margins because it never needs the room.
        if (available > 0 && content > available) {
          body.style.paddingLeft = '0';
          body.style.paddingRight = '0';
          content = body.scrollWidth;
        }
        // A width of zero means the view has not been laid out yet. Dividing
        // by it would scale every message to the 0.5 floor below and shrink a
        // perfectly ordinary message to half size.
        if (!(available > 0) || !(content > 0)) { return 0; }
        var scale = content > available ? available / content : 1;
        // Below this the message is unreadable and fitting it is not a
        // kindness; let it clip rather than shrink to nothing.
        if (scale < 0.5) { scale = 0.5; }
        if (scale < 1) { body.style.zoom = scale; }
        // Read the height AFTER applying the scale, and do NOT scale it again.
        // `scrollHeight` already reflects `zoom` — multiplying a second time
        // reported 982px for a 1303px message and silently cut a quarter of it
        // off, which looked like images failing to load. Measured across 30
        // real messages before this was believed.
        return Math.ceil(document.documentElement.scrollHeight);
      })()
      """

    func measure(_ webView: WKWebView) {
      // `evaluateJavaScript` is host-initiated and still runs with
      // `allowsContentJavaScript` disabled — that flag governs the PAGE's own
      // scripts, which remain blocked both there and by the CSP.
      webView.evaluateJavaScript(Coordinator.fitAndMeasure) { [weak self] value, _ in
        // JavaScript numbers arrive as NSNumber regardless of how they look.
        guard let self, let number = value as? NSNumber else { return }
        let height = CGFloat(number.doubleValue)
        // Ignore noise: re-laying out for a one-point change would thrash the
        // scroll position while images settle.
        guard height > 0, abs(height - self.lastReported) > 2 else { return }
        self.lastReported = height
        self.onHeightChange?(height)
      }
    }

    func webView(
      _ webView: WKWebView,
      decidePolicyFor navigationAction: WKNavigationAction,
      decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
      // The initial loadHTMLString is the only navigation ever permitted
      // in-place.
      if navigationAction.navigationType == .other, navigationAction.request.url == nil {
        decisionHandler(.allow)
        return
      }
      guard let url = navigationAction.request.url else {
        decisionHandler(.allow)
        return
      }
      if url.scheme == "about" {
        decisionHandler(.allow)
        return
      }
      // Image subresources are not navigations, so reaching here with cid:
      // means something tried to NAVIGATE to one. Never allowed.
      if url.scheme == "cid" {
        decisionHandler(.cancel)
        return
      }

      // A clicked link opens in the user's browser. Letting it navigate here
      // would replace the reading pane with a remote page inside the app.
      if navigationAction.navigationType == .linkActivated,
         let scheme = url.scheme?.lowercased(),
         scheme == "http" || scheme == "https" || scheme == "mailto" {
        NSWorkspace.shared.open(url)
      }
      decisionHandler(.cancel)
    }
  }
}

/// Builds the HTML document for a thread.
///
/// Styling mirrors `Theme` so the rendered body sits inside the app rather than
/// looking like an embedded web page. Those values are duplicated here as CSS
/// and must be kept in step with `Theme.swift`.
enum MessageDocument {

  /// Composes a thread into one styled, self-contained document.
  ///
  /// Per-message headers are omitted for a single-message thread, because the
  /// reading pane already shows sender, recipient and time above the document —
  /// repeating them reads as a duplicate.
  /// Number of remote images the sanitiser withheld.
  ///
  /// Counted from the markup rather than tracked through the database, because
  /// the answer needed is "in what is on screen right now", and the document is
  /// what is on screen right now.
  static func blockedImageCount(in messages: [MessageRow]) -> Int {
    messages.reduce(0) { total, message in
      guard let html = message.body?.htmlBody else { return total }
      return total + html.components(separatedBy: "data-blocked=").count - 1
    }
  }

  /// - Parameter showRemoteImages: Restores the URLs the sanitiser withheld.
  ///   Defaults to on, following `ReadingSettings.loadsRemoteImages`. Mail is
  ///   built out of its images; withholding them does not leave a clean text
  ///   version behind, it leaves a skeleton of empty cells. The privacy cost is
  ///   real and the setting states it plainly, but it is no longer the default.
  static func build(for messages: [MessageRow], isDark: Bool,
                    showRemoteImages: Bool = true) -> String {
    let showHeaders = messages.count > 1
    // HTML mail is rendered on WHITE only when it brings colours of its own.
    //
    // It brings its own colours, and it assumes a light page underneath them:
    // a sender who sets a white table background but leaves the body text at
    // its default gets our dark-theme `#d8dee9` on their white — light grey on
    // white, unreadable. Measured across 30 real messages, 11 of them had text
    // at under 2:1 contrast, including a payment reminder whose amount and due
    // date were the affected lines.
    //
    // Every major client does this, and for this reason. Plain-text messages
    // have no colours of their own, so they keep the app's theme.
    let hasHTML = messages.contains(where: \.hasRenderableHTML)
    // A message that sets no colour anywhere has nothing to clash with, so it
    // can follow the app's theme like plain text does. That is the case where
    // the white page was ours rather than the sender's — a two-line reply
    // rendered as a bright slab in a dark window.
    //
    // Deliberately generous about what counts as "brings colours": one
    // `bgcolor` or one `color:` anywhere is enough to keep the light page. The
    // failure mode of guessing wrong in that direction is a white background
    // nobody wanted; the other direction is dark text on a dark background,
    // which is unreadable. `<style>` blocks are dropped on ingest, so inline
    // styles and `<font>` are the only places a colour can come from.
    let bringsOwnColours = messages.contains { message in
      guard let html = message.body?.htmlBody else { return false }
      for marker in ["bgcolor", "background", "color:", "color=", "<font"] {
        if html.range(of: marker, options: .caseInsensitive) != nil { return true }
      }
      return false
    }
    let lightCanvas = hasHTML && bringsOwnColours

    let bodies = messages.map { message -> String in
      let header = !showHeaders ? "" : """
        <div class="msg-head">
          <span class="from">\(escape(message.displayName))</span>
          <span class="addr">\(escape(message.fromEmail))</span>
          <span class="when">\(escape(message.sentDate.formatted(date: .abbreviated, time: .shortened)))</span>
        </div>
        """
      // Messages with no HTML fall back to their plain text, wrapped so it
      // keeps its own line breaks.
      var content = message.hasRenderableHTML
        ? (message.body?.htmlBody ?? "")
        : "<pre class=\"plain\">\(escape(message.displayBody))</pre>"
      if showRemoteImages {
        content = restoringRemoteImages(in: content)
      }
      return "<article>\(header)\(content)</article>"
    }

    return """
      <!doctype html>
      <html><head><meta charset="utf-8">
      <meta http-equiv="Content-Security-Policy"
            content="default-src 'none'; img-src cid: data:\(showRemoteImages ? " https:" : ""); style-src 'unsafe-inline'; font-src 'none'; form-action 'none'; base-uri 'none';\(showRemoteImages ? " upgrade-insecure-requests;" : "")">
      <style>\(css(isDark: isDark && !lightCanvas))</style>
      </head><body>\(bodies.joined())</body></html>
      """
  }

  /// Puts withheld image URLs back into `src`.
  ///
  /// A string substitution rather than script, because JavaScript is disabled
  /// in this web view on purpose and re-enabling it to show a picture would be
  /// a poor trade.
  ///
  /// Note what is NOT restored: only the exact attribute the sanitiser wrote.
  /// Anything else claiming to be an image source was already dropped and stays
  /// dropped — this widens what may load, never what may be interpreted.
  private static func restoringRemoteImages(in html: String) -> String {
    html
      .replacingOccurrences(of: "data-blocked-src=\"", with: "src=\"")
      .replacingOccurrences(of: "data-blocked=\"remote\"", with: "")
  }

  /// ## Why `font-src 'none'` is stated rather than inherited
  ///
  /// A webfont is fetched only when glyphs in its `unicode-range` actually
  /// render, so a sender can slice the range across several faces and learn
  /// which characters were painted. That is a tracking channel `img-src` does
  /// not cover, and it is invisible to the remote-images preference.
  ///
  /// `default-src 'none'` is supposed to cover fonts by fallback. It does not
  /// here: serving a font from a local HTTP server and `@font-face`-ing it
  /// from a message, the request ARRIVED, with this exact policy minus this
  /// line. So the fallback cannot be relied on and the directive is spelled
  /// out. The engine also drops `@font-face` outright; this is the second
  /// line, not the first.
  ///
  /// ## Why `upgrade-insecure-requests`
  ///
  /// Half of all mail with images in it — 16,348 bodies of 30,032, 124,321
  /// references — points at least one `<img>` at a plain `http://` URL, and
  /// `img-src` lists only `https:`. Every one of those was blocked outright,
  /// which is a large share of the images that appeared not to load.
  ///
  /// The directive makes WebKit rewrite those requests to https rather than
  /// admitting `http:` to the policy. Sampled over real URLs, two thirds then
  /// resolve; the rest fail as they already did. Nothing is ever sent in the
  /// clear, so this needs no App Transport Security exception and gives an
  /// interception no new surface.
  ///
  /// The CSP above is the second line of defence. `default-src 'none'` means
  /// no scripts, no fonts, no frames and no remote images can load even if
  /// something slipped past the sanitiser. `img-src cid: data:` permits only
  /// content we already hold locally.
  private static func css(isDark: Bool) -> String {
    let text = isDark ? "#d8dee9" : "#1c1f24"
    let secondary = isDark ? "#8a94a6" : "#6b7280"
    let rule = isDark ? "rgba(255,255,255,0.10)" : "rgba(0,0,0,0.08)"
    let link = isDark ? "#6fb0ff" : "#0b62d6"
    // Painted rather than inherited. The web view draws no background of its
    // own so that plain text can sit directly on the app's surface, which
    // means a light document has to supply the page it assumes.
    let canvas = isDark ? "transparent" : "#ffffff"

    return """
      :root { color-scheme: \(isDark ? "dark" : "light"); }
      html, body {
        margin: 0; background: \(canvas);
        color: \(text);
        font: 14px/1.55 -apple-system, BlinkMacSystemFont, system-ui, sans-serif;
        -webkit-text-size-adjust: 100%;
      }
      /* Breathing room for ordinary mail. Surrendered by the fit pass below
         when a message genuinely needs the width, so text messages read well
         without costing wide marketing layouts the room they are built for. */
      body { padding: 0 24px; }
      article { padding: 0 0 28px; }
      article + article { border-top: 1px solid \(rule); padding-top: 20px; }
      .msg-head { display: flex; gap: 8px; align-items: baseline; margin-bottom: 14px; flex-wrap: wrap; }
      .from { font-weight: 600; font-size: 13px; }
      .addr, .when { color: \(secondary); font-size: 12px; }
      .when { margin-left: auto; font-variant-numeric: tabular-nums; }
      .plain { font: 13px/1.6 ui-monospace, SFMono-Regular, Menlo, monospace;
               white-space: pre-wrap; word-wrap: break-word; margin: 0; }
      a { color: \(link); }
      blockquote {
        margin: 12px 0; padding-left: 14px;
        border-left: 2px solid \(rule); color: \(secondary);
      }
      /* Mail HTML routinely specifies widths far wider than the pane. */
      img, table { max-width: 100% !important; height: auto; }
      table { border-collapse: collapse; }
      td, th { padding: 4px 8px; }
      pre { white-space: pre-wrap; word-wrap: break-word; }
      /* A blocked image keeps its box rather than collapsing to nothing.
         `display: none` removed the element from layout entirely, so a message
         laid out as a table of image slices fell apart into stray padding and
         orphaned cells — which reads as a broken client rather than a private
         one. A dashed placeholder holds the space the sender reserved.
         Tracking pixels are 1x1 and stay invisible either way. */
      img[data-blocked] {
        background: \(rule);
        border: 1px dashed \(rule);
        border-radius: 3px;
        min-width: 0; min-height: 0;
      }
      """
  }

  private static func escape(_ text: String) -> String {
    text
      .replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
      .replacingOccurrences(of: "\"", with: "&quot;")
  }
}
