import SwiftUI
import WebKit

/// Mounts the bridge's `WKWebView` into the window hierarchy at zero size.
///
/// This is not cosmetic. WebKit does not reliably schedule a web view that has
/// never been added to a window — it can sit indefinitely without loading the
/// page or running any JavaScript. Hosting it (invisibly) is what makes the
/// headless client actually run.
struct BridgeHost: NSViewRepresentable {
  let bridge: any MailBridge

  func makeNSView(context: Context) -> NSView {
    let container = NSView(frame: .zero)
    if let webView = bridge.webView {
      webView.frame = NSRect(x: 0, y: 0, width: 1, height: 1)
      container.addSubview(webView)
    }
    return container
  }

  func updateNSView(_ nsView: NSView, context: Context) {}
}
