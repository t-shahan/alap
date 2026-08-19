import SwiftUI
import WebKit
import os

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
    /// ## Why `transform` and not `zoom`
    ///
    /// This used to set `body.style.zoom`. `zoom` is non-standard and has
    /// LAYOUT semantics: WebKit re-runs layout at the scaled size, which
    /// desynchronises anything whose position depends on a computed box —
    /// floats, `table-layout: fixed` cells, absolutely positioned overlays,
    /// and `mso-`-conditioned Outlook markup, which is most marketing mail.
    ///
    /// It also interacts badly with the sender's own media queries. Those
    /// evaluate against the VIEWPORT, which is this web view rather than the
    /// window, and the pane widths in play (557/645/685/700pt) straddle the
    /// 600px threshold nearly all marketing mail switches layouts at. Under
    /// `zoom` the query resolves against the un-zoomed viewport while the
    /// content is re-laid out at the scaled size; under `transform` it cleanly
    /// does not, because a transform is a paint-time operation and changes no
    /// layout at all.
    ///
    /// The scale target is `#fit` rather than `<body>`: a transform on the body
    /// interacts badly with viewport sizing, and the fit pass has to own the
    /// element whose padding it surrenders.
    private static let fitAndMeasure = """
      (function () {
        var fit = document.getElementById('fit');
        if (!fit) { return 0; }
        fit.style.transform = '';
        fit.style.width = '';
        fit.style.paddingLeft = '';
        fit.style.paddingRight = '';

        var available = document.documentElement.clientWidth;
        var content = fit.scrollWidth;
        // Padding is the first thing to go, before any shrinking. A message
        // laid out for 600-700px would otherwise pay for our margins twice:
        // once in lost width and again in being scaled down to fit what was
        // left. Text mail keeps the margins because it never needs the room.
        if (available > 0 && content > available) {
          fit.style.paddingLeft = '0';
          fit.style.paddingRight = '0';
          content = fit.scrollWidth;
        }
        // A width of zero means the view has not been laid out yet. Dividing
        // by it would scale every message to the 0.5 floor below and shrink a
        // perfectly ordinary message to half size.
        if (!(available > 0) || !(content > 0)) { return 0; }
        var scale = content > available ? available / content : 1;
        // Below this the message is unreadable and fitting it is not a
        // kindness; let it clip rather than shrink to nothing.
        if (scale < 0.5) { scale = 0.5; }
        if (scale < 1) {
          fit.style.transformOrigin = 'top left';
          fit.style.transform = 'scale(' + scale + ')';
          // Keep the PRE-scale layout width, or the content reflows into the
          // narrower box and the scale is computed against a moving target.
          fit.style.width = (100 / scale) + '%';
        }
        // `getBoundingClientRect`, NOT `scrollHeight`.
        //
        // The old code measured `scrollHeight` and carried a hard-won comment
        // saying not to scale the result again, because `scrollHeight` already
        // reflected `zoom`. That fact INVERTS here: `scrollHeight` is a layout
        // property and `transform` is a paint-time operation, so under a
        // transform `scrollHeight` reports the UNSCALED height and would
        // over-report by 1/scale. The bounding rect is the one that reflects
        // the transform, which is why it replaces it.
        return Math.ceil(fit.getBoundingClientRect().height);
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
  /// Counted from BOTH markers the sanitiser writes.
  ///
  /// `<img>` gets `data-blocked`. A remote `background-image` in a retained
  /// `<style>` block gets its URL rewritten to a `blocked-remote:` scheme
  /// instead, because a rule in a stylesheet belongs to no element until it
  /// matches one — there is nothing to hang an attribute on. Counting only the
  /// first meant a message whose remote images are all CSS backgrounds showed
  /// no banner at all, and so had no route to loading them.
  ///
  /// `ranges(of:)` rather than `components(separatedBy:)`, which allocated the
  /// full split array for every body on every render pass.
  static func blockedImageCount(in messages: [MessageRow]) -> Int {
    messages.reduce(0) { total, message in
      guard let html = message.body?.htmlBody else { return total }
      return total
        + html.ranges(of: "data-blocked=").count
        + html.ranges(of: Self.blockedCSSMarker).count
        + html.ranges(of: Self.blockedCSSAttributeMarker).count
    }
  }

  /// The scheme the engine parks a blocked CSS URL behind, quote included so
  /// the substitution that restores it cannot match a bare mention in text.
  private static let blockedCSSMarker = "\"blocked-remote:"

  /// The same marker as it survives inside a `style` ATTRIBUTE.
  ///
  /// The engine parks a blocked CSS URL behind `"blocked-remote:` in both
  /// places, but an attribute value is entity-escaped on the way out — it has
  /// to be, or the quote would end the attribute — so the stored bytes read
  /// `&quot;blocked-remote:` there and `"blocked-remote:` in a `<style>` block.
  /// Matching only the second left every attribute-borne background image
  /// permanently dead once the attribute path started honouring the images
  /// preference: blocked at ingest, and never restored at render.
  private static let blockedCSSAttributeMarker = "&quot;blocked-remote:"

  /// - Parameter showRemoteImages: Restores the URLs the sanitiser withheld.
  ///   Defaults to on, following `ReadingSettings.loadsRemoteImages`. Mail is
  ///   built out of its images; withholding them does not leave a clean text
  ///   version behind, it leaves a skeleton of empty cells. The privacy cost is
  ///   real and the setting states it plainly, but it is no longer the default.
  static func build(for messages: [MessageRow], isDark: Bool,
                    showRemoteImages: Bool = true) -> RenderedMessage {
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
    // which is unreadable.
    //
    // The bare substring `background` used to be in this list, justified by
    // "`<style>` blocks are dropped on ingest, so inline styles and `<font>`
    // are the only places a colour can come from." That is no longer true —
    // the sanitiser keeps stylesheets and admits `class` — so `background`
    // matched `background-image`, `background-position` and any
    // `class="background-cell"` in retained markup, and the dark-canvas branch
    // was close to dead. The markers below all name a COLOUR specifically.
    let bringsOwnColours = messages.contains { message in
      guard let html = message.body?.htmlBody else { return false }
      for marker in ["bgcolor", "background-color", "color:", "color=", "<font"] {
        if html.range(of: marker, options: .caseInsensitive) != nil { return true }
      }
      return false
    }
    let lightCanvas = hasHTML && bringsOwnColours

    let bodies = messages.enumerated().map { index, message -> String in
      // Prefixed class names. These are the APP's chrome sitting in a document
      // full of the sender's CSS, and `msg-head` / `from` / `addr` / `when`
      // are exactly the kind of names a newsletter template also uses. A
      // collision should require intent rather than coincidence.
      let header = !showHeaders ? "" : """
        <div class="alap-msg-head">
          <span class="alap-from">\(escape(message.displayName))</span>
          <span class="alap-addr">\(escape(message.fromEmail))</span>
          <span class="alap-when">\(escape(message.sentDate.formatted(date: .abbreviated, time: .shortened)))</span>
        </div>
        """
      // Messages with no HTML fall back to their plain text, wrapped so it
      // keeps its own line breaks.
      var content = message.hasRenderableHTML
        ? (message.body?.htmlBody ?? "")
        : "<pre class=\"alap-plain\">\(escape(message.displayBody))</pre>"
      if showRemoteImages {
        content = restoringRemoteImages(in: content)
      }
      // Each message gets an id, and its own stylesheet is scoped to it.
      let scope = "alap-msg-\(index)"
      return "<article id=\"\(scope)\" class=\"alap-msg\">"
        + header + scoping(content, to: scope) + "</article>"
    }

    // ## Why the app's stylesheet is emitted AFTER the bodies
    //
    // A retained `<style>` block sits in the body, scoped to nothing. With the
    // app's rules in `<head>` they came FIRST in document order, so the app
    // lost every specificity tie to a sender — and `msg-head`, `from`, `addr`,
    // `when` and `pre.plain` were unprefixed names in a document full of
    // stranger CSS. The app had stopped owning its own chrome. These headers
    // render only in multi-message threads, which is exactly the case that also
    // carries more than one sender stylesheet.
    //
    // Emitting last wins those ties on the same document-order rule that lost
    // them, and takes nothing from the sender: every selector below names an
    // `alap-` class or a structural element the app introduced.
    //
    // None of this was ever a security question — the property allowlist
    // refuses positioning, `content`, `expression()` and custom properties, the
    // selector allowlist refuses combinators, and 50 tests in `test_css.cpp`
    // say so. It is a fidelity question.
    let document = """
      <!doctype html>
      <html><head><meta charset="utf-8">
      <meta http-equiv="Content-Security-Policy"
            content="default-src 'none'; img-src cid: data:\(showRemoteImages ? " https:" : ""); style-src 'unsafe-inline'; font-src 'none'; form-action 'none'; base-uri 'none';\(showRemoteImages ? " upgrade-insecure-requests;" : "")">
      <style>\(baseCSS(isDark: isDark && !lightCanvas))</style>
      </head><body><div id="fit">\(bodies.joined())</div>
      <style>\(chromeCSS(isDark: isDark && !lightCanvas))</style>
      </body></html>
      """
    return RenderedMessage(html: document, usesLightCanvas: lightCanvas)
  }

  /// Confines a message's own stylesheet to its own article.
  ///
  /// ## The problem
  ///
  /// `build` composes the whole thread into ONE document, and a retained
  /// `<style>` block sits in the body scoped to nothing. So in a multi-message
  /// thread one sender's stylesheet restyles every other message in it — a
  /// `td { font-size: 18px }` written for a newsletter applies to the reply
  /// above it. Emitting the app's own rules last protects the app's chrome, but
  /// it does nothing for one sender against another.
  ///
  /// ## Why this is a text wrap and not a rewrite
  ///
  /// The alternative is prefixing every retained selector, which means a second
  /// CSS parser — in Swift, beside the thorough one the engine already has —
  /// and a re-fetch of every stored body, since `html_body` holds the
  /// sanitiser's OUTPUT rather than the original. `@scope` needs neither: the
  /// existing rules are wrapped, unmodified, in one at-rule.
  ///
  /// The sanitiser is what makes the wrap safe. It refuses `<` and `>` inside
  /// selectors and declarations and rejects unbalanced braces, so a retained
  /// block cannot close its own `<style>` early or unbalance the wrapper.
  ///
  /// ## What this deliberately breaks
  ///
  /// A scoped rule matches DESCENDANTS of the scope root, so a sender's
  /// `body { … }` or `html { … }` stops applying. That is the point rather than
  /// a side effect — those rules were reaching our document, not theirs — and
  /// the app's own base stylesheet already sets the margin and padding they
  /// almost always restate.
  private static func scoping(_ html: String, to scope: String) -> String {
    guard html.contains("<style") else { return html }

    var out = ""
    var rest = Substring(html)
    while let open = rest.range(of: "<style", options: .caseInsensitive),
          let openEnd = rest[open.upperBound...].firstIndex(of: ">"),
          let close = rest.range(of: "</style", options: .caseInsensitive,
                                 range: openEnd..<rest.endIndex) {
      let afterOpen = rest.index(after: openEnd)
      out += rest[..<afterOpen]
      out += "@scope (#\(scope)) {"
      out += rest[afterOpen..<close.lowerBound]
      out += "}"
      rest = rest[close.lowerBound...]
    }
    return out + rest
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
      // The CSS half. Without it, a message whose remote images are all
      // `background-image` had no route back to loading them in EITHER
      // preference state — ingest sanitises with images off and stores the
      // result, so the live URL exists nowhere else.
      .replacingOccurrences(of: Self.blockedCSSMarker, with: "\"")
      .replacingOccurrences(of: Self.blockedCSSAttributeMarker, with: "&quot;")
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
  /// The page itself: canvas, default text, and the one rule the fit pass
  /// operates on.
  ///
  /// Stays in `<head>`, because these are DEFAULTS a sender is entitled to
  /// override — a message that sets its own body colour should win. Everything
  /// the app needs to keep is in `chromeCSS`, after the bodies.
  ///
  /// ## Why there is no cell padding here
  ///
  /// `td, th { padding: 4px 8px }` used to be in this sheet, and it corrupted
  /// the layout of exactly the mail this renderer exists for. Marketing and
  /// transactional mail is built out of DEEPLY NESTED tables — the cells are
  /// layout scaffolding, not data — so the padding applies at every level and
  /// accumulates. On a real six-level daycare report the content column
  /// collapsed to ~185px inside a 664px pane, every line wrapped, and the
  /// document ran to 3,516px against the 1,750px it should be: half of it was
  /// our padding.
  ///
  /// Measured over a 20-message corpus at 664px, removing it made **19 of 20
  /// documents shorter**, the corpus 13% shorter overall, and the worst two
  /// 49% shorter — and took pane overflow from 1/20 to 0/20 and height
  /// mismatches from 4/20 to 2/20.
  ///
  /// It was always wrong; it got worse when the sanitiser began keeping
  /// `<style>` and `class`, because more messages now lay themselves out the
  /// way their sender designed and this rule fought every one of them.
  ///
  /// Senders that want cell padding set `cellpadding` or an inline style, and
  /// both still work. Choosing the sender's cell metrics for them is not a
  /// mail client's job.
  private static func baseCSS(isDark: Bool) -> String {
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
        margin: 0; padding: 0; background: \(canvas);
        color: \(text);
        font: 14px/1.55 -apple-system, BlinkMacSystemFont, system-ui, sans-serif;
        -webkit-text-size-adjust: 100%;
      }
      /* The fit pass's target. Breathing room for ordinary mail, surrendered
         by that pass when a message genuinely needs the width — so text mail
         reads well without costing wide marketing layouts the room they are
         built for.

         `border-box` is NOT optional: the fit pass sets `width` as a
         percentage while padding may still be applied, and under the default
         `content-box` the element would overflow by exactly the padding. */
      #fit { box-sizing: border-box; padding: 0 24px; }
      a { color: \(link); }
      blockquote {
        margin: 12px 0; padding-left: 14px;
        border-left: 2px solid \(rule); color: \(secondary);
      }
      /* Mail HTML routinely specifies widths far wider than the pane. */
      img, table { max-width: 100% !important; height: auto; }
      table { border-collapse: collapse; }
      /* Deliberately no `td`/`th` padding — see the note above. */
      pre { white-space: pre-wrap; word-wrap: break-word; }
      """
  }

  /// The app's own chrome, emitted after the bodies so it wins ties.
  ///
  /// Every selector here names something the app introduced. `img[data-blocked]`
  /// is included for the same reason the classes are: it is one
  /// attribute-selector rule holding a withheld image's box open, and a sender
  /// rule of equal specificity earlier in the document could otherwise make a
  /// blocked image look like a loaded one.
  private static func chromeCSS(isDark: Bool) -> String {
    let secondary = isDark ? "#8a94a6" : "#6b7280"
    let rule = isDark ? "rgba(255,255,255,0.10)" : "rgba(0,0,0,0.08)"

    return """
      article.alap-msg { padding: 0 0 28px; }
      article.alap-msg + article.alap-msg {
        border-top: 1px solid \(rule); padding-top: 20px;
      }
      .alap-msg-head {
        display: flex; gap: 8px; align-items: baseline;
        margin-bottom: 14px; flex-wrap: wrap;
      }
      .alap-from { font-weight: 600; font-size: 13px; }
      .alap-addr, .alap-when { color: \(secondary); font-size: 12px; }
      .alap-when { margin-left: auto; font-variant-numeric: tabular-nums; }
      .alap-plain {
        font: 13px/1.6 ui-monospace, SFMono-Regular, Menlo, monospace;
        white-space: pre-wrap; word-wrap: break-word; margin: 0;
      }
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

/// A composed thread document, and what the app has to know about it.
///
/// The canvas decision used to be computed inside `build` and thrown away, so
/// the reading pane could not tell whether it was about to draw a white page
/// or a transparent one — and therefore drew every message flush to the edge
/// of a dark window either way.
struct RenderedMessage: Equatable {
  let html: String
  /// True when the message brought its own colours and is being rendered on a
  /// white page. The pane frames those as documents rather than adopting them
  /// as surfaces.
  let usesLightCanvas: Bool
}
