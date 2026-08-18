import AppKit
import WebKit

// Headless renderer: loads a document in WKWebView at a given width, reports
// layout diagnostics as JSON, and writes a PNG snapshot.
// Usage: render <html-file> <width> <out.png>

let args = CommandLine.arguments
guard args.count >= 4, let width = Double(args[2]) else {
  FileHandle.standardError.write("usage: render <html> <width> <out.png>\n".data(using: .utf8)!)
  exit(2)
}
let html = (try? String(contentsOfFile: args[1], encoding: .utf8)) ?? ""
let outPath = args[3]
// Optional: the app's own fit-and-measure script, so the harness reports what
// the app computes rather than a copy of it that can drift.
let appJS = args.count >= 5 ? (try? String(contentsOfFile: args[4], encoding: .utf8)) : nil

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

final class Driver: NSObject, WKNavigationDelegate {
  let webView: WKWebView
  let out: String
  var appJS: String?
  var appHeight: Double = -1
  init(width: Double, out: String) {
    let config = WKWebViewConfiguration()
    config.defaultWebpagePreferences.allowsContentJavaScript = false
    self.webView = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: 800),
                             configuration: config)
    self.out = out
    super.init()
    webView.navigationDelegate = self
  }

  private var probed = false

  // Probe off didCommit, not didFinish. Mail carries subresources that never
  // complete -- tracking pixels whose URLs are endless redirect chains -- and
  // waiting for the load to finish means never probing those messages at all,
  // which is exactly the app bug this harness exists to catch.
  func webView(_ webView: WKWebView, didCommit nav: WKNavigation!) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { self.probeOnce() }
  }

  func webView(_ webView: WKWebView, didFinish nav: WKNavigation!) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.probeOnce() }
  }

  func probeOnce() {
    guard !probed else { return }
    probed = true
    runAppScript()
  }

  /// What the app itself would compute for this document at this width.
  func runAppScript() {
    guard let js = appJS else { diagnose(); return }
    webView.evaluateJavaScript(js) { value, _ in
      self.appHeight = (value as? NSNumber)?.doubleValue ?? -1
      self.diagnose()
    }
  }

  func diagnose() {
    let probe = """
      (function () {
        var b = document.body, d = document.documentElement;
        b.style.zoom = '';
        var pre = { clientWidth: d.clientWidth, bodyScrollWidth: b.scrollWidth,
                    docScrollHeight: d.scrollHeight };
        var avail = d.clientWidth, content = b.scrollWidth;
        var scale = (avail > 0 && content > avail) ? avail / content : 1;
        if (scale < 0.5) scale = 0.5;
        if (scale < 1) b.style.zoom = scale;
        var post = { docScrollHeight: d.scrollHeight };
        var imgs = Array.prototype.slice.call(document.images);

        // Contrast probe: text whose colour was inherited from our own CSS
        // sitting on a background the message painted itself.
        function lum(c) {
          var m = /rgba?\\((\\d+), ?(\\d+), ?(\\d+)(?:, ?([\\d.]+))?\\)/.exec(c);
          if (!m) return null;
          if (m[4] !== undefined && parseFloat(m[4]) === 0) return null;
          var r = +m[1]/255, g = +m[2]/255, bl = +m[3]/255;
          function f(x){ return x <= 0.03928 ? x/12.92 : Math.pow((x+0.055)/1.055, 2.4); }
          return 0.2126*f(r) + 0.7152*f(g) + 0.0722*f(bl);
        }
        function bgOf(el) {
          while (el && el !== document.documentElement) {
            var c = getComputedStyle(el).backgroundColor, l = lum(c);
            if (l !== null) return l;
            el = el.parentElement;
          }
          return null;
        }
        var lowContrast = 0, checked = 0;
        var nodes = document.querySelectorAll('td,p,div,span,a,h1,h2,h3,li');
        for (var i = 0; i < nodes.length && checked < 400; i++) {
          var el = nodes[i];
          if (!el.textContent || !el.textContent.trim()) continue;
          var hasOwnText = false;
          for (var c = 0; c < el.childNodes.length; c++) {
            if (el.childNodes[c].nodeType === 3 && el.childNodes[c].nodeValue.trim()) hasOwnText = true;
          }
          if (!hasOwnText) continue;
          var r = el.getBoundingClientRect();
          if (r.width < 30 || r.height < 8) continue;
          checked++;
          var fg = lum(getComputedStyle(el).color), bg = bgOf(el);
          if (fg === null || bg === null) continue;
          var ratio = (Math.max(fg,bg) + 0.05) / (Math.min(fg,bg) + 0.05);
          if (ratio < 2.0) lowContrast++;
        }
        return JSON.stringify({
          pre: pre, scale: scale, post: post,
          images: imgs.length,
          imagesLoaded: imgs.filter(function (i) { return i.naturalWidth > 0; }).length,
          imagesNoSrc: imgs.filter(function (i) { return !i.getAttribute('src'); }).length,
          checked: checked, lowContrast: lowContrast
        });
      })()
      """
    webView.evaluateJavaScript(probe) { value, error in
      if let json = value as? String {
        // Splice the app-computed height in beside the measured truth.
        var merged = json
        if merged.hasSuffix("}") {
          merged = String(merged.dropLast()) + ",\"appHeight\":\(self.appHeight)}"
        }
        print(merged)
      }
      else { print("{\"error\":\"\(error?.localizedDescription ?? "probe failed")\"}") }
      self.snapshot()
    }
  }

  func snapshot() {
    // Size the view to the post-scale content height so nothing is cut off by
    // the frame itself -- we want to see what the document does, not what the
    // frame allows.
    webView.evaluateJavaScript("Math.ceil(document.documentElement.scrollHeight)") { value, _ in
      let h = (value as? NSNumber)?.doubleValue ?? 800
      self.webView.frame = NSRect(x: 0, y: 0, width: self.webView.frame.width, height: min(h, 6000))
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
        let cfg = WKSnapshotConfiguration()
        cfg.rect = self.webView.bounds
        self.webView.takeSnapshot(with: cfg) { image, _ in
          if let image, let tiff = image.tiffRepresentation,
             let rep = NSBitmapImageRep(data: tiff),
             let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: self.out))
          }
          exit(0)
        }
      }
    }
  }
}

let driver = Driver(width: width, out: outPath)
driver.appJS = appJS
// baseURL nil, exactly as the app does it. With an https base the document
// is a secure context and WebKit applies mixed-content rules the app never
// sees, so the harness would have been measuring a different browser.
driver.webView.loadHTMLString(html, baseURL: nil)
DispatchQueue.main.asyncAfter(deadline: .now() + 25) { print("{\"error\":\"timeout\"}"); exit(1) }
app.run()
