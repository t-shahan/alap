import AppKit
import WebKit

// Headless renderer: loads a document in WKWebView at a given width, reports
// layout diagnostics as JSON, and writes a PNG snapshot.
// Usage: render <html-file> <width> <out.png> [app-fit.js] [case-probe.js]

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
// Optional: a per-message geometry probe, for the named regression cases in
// cases.py. It must evaluate to a JSON *string*, which is spliced in under
// "case". Kept out of the standard probe because it is message-specific and
// costs a whole extra round trip.
let caseJS = args.count >= 6 ? (try? String(contentsOfFile: args[5], encoding: .utf8)) : nil

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

final class Driver: NSObject, WKNavigationDelegate {
  let webView: WKWebView
  let out: String
  var appJS: String?
  var caseJS: String?
  var appHeight: Double = -1
  var caseJSON: String?
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
    runCaseProbe()
  }

  /// The case probe runs FIRST, on the pristine layout, before the app's fit
  /// script has stripped the padding or applied its transform. A regression case
  /// asks "did this document lay itself out correctly", and the answer must not
  /// depend on how much the pane then squeezed it.
  func runCaseProbe() {
    guard let js = caseJS else { runAppScript(); return }
    webView.evaluateJavaScript(js) { value, error in
      self.caseJSON = (value as? String)
        ?? "{\"error\":\"\(error?.localizedDescription ?? "case probe failed")\"}"
      self.runAppScript()
    }
  }

  /// Deliberately empty.
  ///
  /// The app's fit script used to run here, in its own `evaluateJavaScript`,
  /// with the harness's own measurement following in a second one. Under
  /// `zoom` that was harmless, because both sides read
  /// `documentElement.scrollHeight` — floored at the viewport — so they agreed
  /// whatever happened in between.
  ///
  /// Under `transform` they read `#fit`'s bounding rect, which is a live
  /// measurement of a document whose images are still arriving. Two round
  /// trips meant two different layouts: the app measured 7,602 and the harness
  /// 8,844 for the same message, and the height gate called the 14% difference
  /// "content clipped" when nothing had been clipped at all. Rendered in
  /// isolation, on a settled document, the two agree exactly.
  ///
  /// So the app's script is now spliced into the measurement probe and both
  /// numbers come out of ONE evaluation, where no reflow can happen between
  /// them. The gate goes back to measuring what it was written to measure —
  /// whether the app is handed the post-scale height — rather than measuring
  /// how fast images loaded.
  func runAppScript() { diagnose() }

  func diagnose() {
    // The app's own script, verbatim, evaluated first inside this same
    // function so its result and ours describe one layout.
    let app = appJS.map { "var appHeight = (\($0));" } ?? "var appHeight = -1;"
    let probe = """
      (function () {
        \(app)
        var d = document.documentElement;
        var f = document.getElementById('fit') || document.body;
        // Restore the PRISTINE document before measuring — all four
        // properties the app's fit script writes, not just two.
        //
        // Resetting `transform` and `width` while leaving `padding` at the
        // zero the app set is not a reset: it hands the content MORE room than
        // it ever really has, and dropping the preserved `width: (100/scale)%`
        // lets it reflow into the narrower box. The measurement then finds
        // nothing overflowing, at every width, and the three gates that exist
        // to catch a fit regression go quietly vacuous.
        //
        // This is the same four lines the app's own script opens with, and it
        // has to stay that way.
        f.style.transform = '';
        f.style.width = '';
        f.style.paddingLeft = '';
        f.style.paddingRight = '';
        var pre = { clientWidth: d.clientWidth, bodyScrollWidth: f.scrollWidth,
                    docScrollHeight: d.scrollHeight,
                    // Which side of the 600px threshold marketing mail almost
                    // universally switches layouts at. Media queries match the
                    // VIEWPORT, which here is the web view rather than the
                    // window — so at the narrow pane widths a message renders
                    // its PHONE layout, at a threshold nobody in this codebase
                    // chose. Reported so the corpus can be read at both.
                    mobileLayout: d.clientWidth < 600 };
        var avail = d.clientWidth, content = f.scrollWidth;
        var scale = (avail > 0 && content > avail) ? avail / content : 1;
        if (scale < 0.5) scale = 0.5;
        if (scale < 1) {
          f.style.transformOrigin = 'top left';
          f.style.transform = 'scale(' + scale + ')';
          f.style.width = (100 / scale) + '%';
        }
        // A transform is paint-time, so `scrollHeight` reports the UNSCALED
        // height and the bounding rect is the one that reflects it. This is
        // the exact inversion of what `zoom` did, and it has to match what the
        // app now measures or the height gate compares two different numbers.
        var post = { docScrollHeight: Math.ceil(f.getBoundingClientRect().height) };
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
          appHeight: appHeight,
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
        var merged = json
        if let c = self.caseJSON, merged.hasSuffix("}") {
          merged = String(merged.dropLast()) + ",\"case\":\(c)}"
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
    webView.evaluateJavaScript(
      "Math.ceil((document.getElementById('fit') || document.body)"
      + ".getBoundingClientRect().height)"
    ) { value, _ in
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
driver.caseJS = caseJS
// baseURL nil, exactly as the app does it. With an https base the document
// is a secure context and WebKit applies mixed-content rules the app never
// sees, so the harness would have been measuring a different browser.
driver.webView.loadHTMLString(html, baseURL: nil)
DispatchQueue.main.asyncAfter(deadline: .now() + 25) { print("{\"error\":\"timeout\"}"); exit(1) }
app.run()
