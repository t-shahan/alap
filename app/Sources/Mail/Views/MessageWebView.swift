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
struct MessageWebView: NSViewRepresentable {
  let html: String

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> WKWebView {
    let config = WKWebViewConfiguration()
    // Mail never needs script. Disabling it at the engine level means a
    // sanitiser mistake is not automatically an execution bug.
    config.defaultWebpagePreferences.allowsContentJavaScript = false

    let webView = WKWebView(frame: .zero, configuration: config)
    webView.navigationDelegate = context.coordinator
    webView.setValue(false, forKey: "drawsBackground")  // inherit app background
    return webView
  }

  func updateNSView(_ webView: WKWebView, context: Context) {
    // Reloading the same content would reset scroll position on every
    // unrelated redraw, so only load when the document actually changed.
    guard context.coordinator.loadedHTML != html else { return }
    context.coordinator.loadedHTML = html
    webView.loadHTMLString(html, baseURL: nil)
  }

  final class Coordinator: NSObject, WKNavigationDelegate {
    var loadedHTML: String?

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
  static func build(for messages: [MessageRow], isDark: Bool) -> String {
    let showHeaders = messages.count > 1

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
      let content = message.hasRenderableHTML
        ? (message.body?.htmlBody ?? "")
        : "<pre class=\"plain\">\(escape(message.displayBody))</pre>"
      return "<article>\(header)\(content)</article>"
    }

    return """
      <!doctype html>
      <html><head><meta charset="utf-8">
      <meta http-equiv="Content-Security-Policy"
            content="default-src 'none'; img-src cid: data:; style-src 'unsafe-inline'; form-action 'none'; base-uri 'none';">
      <style>\(css(isDark: isDark))</style>
      </head><body>\(bodies.joined())</body></html>
      """
  }

  /// The CSP above is the second line of defence. `default-src 'none'` means
  /// no scripts, no fonts, no frames and no remote images can load even if
  /// something slipped past the sanitiser. `img-src cid: data:` permits only
  /// content we already hold locally.
  private static func css(isDark: Bool) -> String {
    let text = isDark ? "#d8dee9" : "#1c1f24"
    let secondary = isDark ? "#8a94a6" : "#6b7280"
    let rule = isDark ? "rgba(255,255,255,0.10)" : "rgba(0,0,0,0.08)"
    let link = isDark ? "#6fb0ff" : "#0b62d6"

    return """
      :root { color-scheme: \(isDark ? "dark" : "light"); }
      html, body {
        margin: 0; padding: 0; background: transparent;
        color: \(text);
        font: 14px/1.55 -apple-system, BlinkMacSystemFont, system-ui, sans-serif;
        -webkit-text-size-adjust: 100%;
      }
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
      /* Images the sanitiser blocked leave a marker rather than a broken icon. */
      img[data-blocked] { display: none; }
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
