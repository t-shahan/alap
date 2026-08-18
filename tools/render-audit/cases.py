"""Named regression cases: two real messages, held to what their layout must do.

The sweep measures a population — how many messages overflow, how many are
clipped, how much text is unreadable. That catches regressions that move an
aggregate. It does not catch a regression that ruins one *kind* of message,
because thirty messages of which two are product grids will not move any rate
far enough to trip a threshold.

These are the other half: two messages, by name, each with an assertion about
its geometry. Both exist because the sanitiser strips `<style>` blocks and
`class` attributes, and a mail template that carries its column widths in a
stylesheet has nowhere else to put them.

The assertions are geometric on purpose. "The document contains `Column-1`"
would pass the moment the sanitiser stopped deleting the attribute, whether or
not the browser did anything with it — and the bug is not a missing attribute,
it is a layout that collapsed.

NOTE ON DATA: `message_body.html_body` holds the sanitiser's OUTPUT, not the
bytes Gmail sent (see `store.cpp`, which writes `html::sanitize(...).html`).
Fixing the sanitiser therefore does not fix these rows by itself — the affected
messages have to be fetched again before the stylesheet is back in the stored
body. Until then these checks fail, which is correct: the reading pane really
would render the broken layout.
"""

import json
import os
import subprocess

HERE = os.path.dirname(os.path.abspath(__file__))


# ---------------------------------------------------------------------------
# Probes
# ---------------------------------------------------------------------------

# Answers "is the repeated tile in this message laid out in more than one
# column" without being told what the tile is.
#
# Step one finds the grid: bucket every image wider than MIN_W by rendered
# width and take the biggest bucket. A product grid is by definition the same
# picture box repeated, so the modal width IS the tile — 16 images at 130px
# here, against 7 category thumbnails at 240px and ten full-bleed banners near
# 570px. Self-calibrating rather than hardcoded, so the check survives the
# tile being resized, and honest in its reporting: it says how many tiles it
# found and how wide they were.
#
# Step two groups the tiles into horizontal bands. Two tiles share a band when
# their vertical extents overlap by more than half the shorter one AND their
# horizontal extents are disjoint. Grouping on an identical
# `getBoundingClientRect().top` was the obvious first cut and is too brittle:
# tiles carry photos of different heights, so a perfectly good two-column grid
# puts its cells a few pixels apart and a strict top-match reports one column.
# Overlap-and-disjoint asks what we actually mean — "is there something next to
# this" — and answers it the same way whether the grid is built from floats,
# inline-blocks, or table cells.
#
# MIN_W drops the 36px social icon row and the 20px footer pixel. They sit side
# by side even in the collapsed layout, so counting them would let this pass on
# a document whose grid is gone entirely.
SIDE_BY_SIDE_PROBE = """
(function () {
  var MIN_W = %(min_width)d;
  var BUCKET = %(bucket)d;
  var boxes = [];
  Array.prototype.slice.call(document.images).forEach(function (im) {
    var r = im.getBoundingClientRect();
    if (r.width < MIN_W || r.height < 8) return;
    boxes.push({ t: r.top, b: r.bottom, l: r.left, r: r.right, w: r.width });
  });

  var buckets = {};
  boxes.forEach(function (b) {
    var k = Math.round(b.w / BUCKET) * BUCKET;
    (buckets[k] = buckets[k] || []).push(b);
  });
  var tileWidth = 0;
  Object.keys(buckets).forEach(function (k) {
    if (buckets[k].length > (buckets[tileWidth] || []).length) tileWidth = k;
  });
  var cells = buckets[tileWidth] || [];
  cells.sort(function (a, b) { return (a.t - b.t) || (a.l - b.l); });

  function sideBySide(a, b) {
    var overlap = Math.min(a.b, b.b) - Math.max(a.t, b.t);
    var shorter = Math.min(a.b - a.t, b.b - b.t);
    if (shorter <= 0 || overlap <= shorter * 0.5) return false;
    return (a.r <= b.l + 1) || (b.r <= a.l + 1);   // no horizontal overlap
  }

  var bands = [];
  cells.forEach(function (c) {
    for (var i = 0; i < bands.length; i++) {
      for (var j = 0; j < bands[i].length; j++) {
        if (sideBySide(bands[i][j], c)) { bands[i].push(c); return; }
      }
    }
    bands.push([c]);
  });

  var widest = 0;
  var multi = 0;
  bands.forEach(function (b) {
    if (b.length > widest) widest = b.length;
    if (b.length > 1) multi++;
  });
  return JSON.stringify({
    tileWidth: Number(tileWidth),
    tiles: cells.length,
    bands: bands.length,
    multiColumnBands: multi,
    widestBand: widest,
    docHeight: Math.ceil(document.documentElement.scrollHeight)
  });
})()
"""

# Counts elements whose own text is exactly LABEL, and how many of them the
# reader can actually see.
#
# Visibility is the whole point. A template that ships a desktop button and a
# mobile button and hides one with a stylesheet is correct; a client that drops
# the stylesheet renders both, stacked on top of each other. So the DOM count
# is reported but never asserted on — only `visible` is.
#
# A zero-size rect is the test that catches every way of hiding something,
# including `display:none` on an ancestor several levels up, which the
# element's own computed style says nothing about. `visibility` and `opacity`
# are walked up by hand because neither collapses the box.
VISIBLE_LABEL_PROBE = """
(function () {
  var LABEL = %(label)s;
  var found = [];
  var nodes = document.querySelectorAll('a, button, td, th, div, span, p');
  Array.prototype.forEach.call(nodes, function (el) {
    if ((el.textContent || '').trim() !== LABEL) return;
    // Only the innermost carrier. Every wrapper up the tree has the same
    // textContent and would multiply the count by the nesting depth.
    if (el.querySelector('a, button, td, th, div, span, p')) return;
    var r = el.getBoundingClientRect();
    var shown = r.width > 1 && r.height > 1;
    for (var p = el; shown && p && p.nodeType === 1; p = p.parentElement) {
      var cs = getComputedStyle(p);
      if (cs.visibility === 'hidden' || cs.visibility === 'collapse') shown = false;
      if (parseFloat(cs.opacity) <= 0.01) shown = false;
    }
    found.push({ shown: shown, top: Math.round(r.top), left: Math.round(r.left),
                 w: Math.round(r.width), h: Math.round(r.height) });
  });
  return JSON.stringify({
    inDom: found.length,
    visible: found.filter(function (f) { return f.shown; }).length,
    boxes: found
  });
})()
"""


# ---------------------------------------------------------------------------
# Verifiers
# ---------------------------------------------------------------------------

def _verify_rainier(c, limits):
    """Rainier Arms: 16 product tiles whose column widths live in a `<style>`.

    Broken, every product gets its own row and the message is 10,863px tall.
    Fixed, it is a two-column grid at roughly 6,926px.
    """
    fails = []
    # If the tile cohort itself has gone, the band count below is meaningless
    # and would report "0 columns" for a message that no longer has a grid to
    # have columns of. Say which it is.
    if c.get("tiles", 0) < limits["min_tiles"]:
        fails.append(
            f"Rainier Arms: found only {c.get('tiles', 0)} repeated product tiles "
            f"(at {c.get('tileWidth', 0)}px), expected at least {limits['min_tiles']}. "
            "The grid is not merely single-column, it is missing")
    elif c.get("multiColumnBands", 0) < limits["min_multicolumn_bands"]:
        fails.append(
            "Rainier Arms product grid collapsed to one column: of "
            f"{c.get('tiles', 0)} product tiles ({c.get('tileWidth', 0)}px each) "
            f"only {c.get('multiColumnBands', 0)} horizontal bands hold two or more "
            f"side by side, need {limits['min_multicolumn_bands']} "
            f"(widest band {c.get('widestBand', 0)} tile(s) across "
            f"{c.get('bands', 0)} bands)")
    # Height is a corroborating proxy, never the primary signal: a document can
    # get shorter because images failed to load, or because the sanitiser ate
    # half the message. It is here so a "grid restored" that somehow does not
    # shorten the message gets a second look.
    h = c.get("docHeight", 0)
    if h > limits["max_doc_height"]:
        fails.append(
            f"Rainier Arms renders {h}px tall, over the {limits['max_doc_height']}px "
            "ceiling. Single-column was 10,863px; the two-column grid is ~6,926px")
    return fails


def _verify_gphotos(c, limits):
    """Google Photos: two "See your photos" buttons, one hidden by a stylesheet.

    The second anchor is marked desktop-only/mobile-hidden and is meant to be
    suppressed. With the stylesheet gone both render and overlap. Left in the
    document but hidden is a correct fix, so only what is on screen is asserted.
    """
    want = limits["visible_cta"]
    got = c.get("visible", -1)
    if got == want:
        return []
    return [
        f"Google Photos shows {got} visible \"See your photos\" button(s), "
        f"want exactly {want} ({c.get('inDom', 0)} in the DOM; hidden ones are "
        f"fine). Boxes: {json.dumps(c.get('boxes', []))}"]


CASES = [
    {
        "slug": "rainier-grid",
        "subject": "Back in Stock & Ready to Go at Rainier Arms",
        # 60px clears the 36px social row and the 20px footer pixel. The 10px
        # bucket keeps tiles that differ by a rounding pixel in one cohort
        # without merging 130px tiles into 240px category thumbnails.
        "probe": SIDE_BY_SIDE_PROBE % {"min_width": 60, "bucket": 10},
        "limits": "rainier_grid",
        "verify": _verify_rainier,
    },
    {
        "slug": "gphotos-cta",
        "subject": "Taylor, revisit your memories in Google Photos",
        "probe": VISIBLE_LABEL_PROBE % {"label": json.dumps("See your photos")},
        "limits": "gphotos_cta",
        "verify": _verify_gphotos,
    },
]


# ---------------------------------------------------------------------------
# Runner
# ---------------------------------------------------------------------------

def message_id_for_subject(subject):
    """The newest message with exactly this subject, or None.

    Selects a single column on purpose. Message ids are composite and contain a
    literal `|`, which is also psql's unaligned field separator, so anything
    that returns two columns cannot be split back apart.
    """
    sql = ("select m.id from message m join message_body b on b.message_id = m.id "
           "where m.subject = $sub$%s$sub$ and b.html_body is not null "
           "order by m.sent_at desc limit 1;" % subject.replace("$sub$", ""))
    out = subprocess.run(["psql", "-d", "mailapp", "-Atc", sql],
                         capture_output=True, text=True).stdout.strip()
    return out or None


def html_for(message_id):
    return subprocess.run(
        ["psql", "-d", "mailapp", "-Atc",
         "select html_body from message_body where message_id = $mid$%s$mid$"
         % message_id],
        capture_output=True, text=True).stdout


def run(case, width, build, app_js_path, out_dir):
    """Render one named case and return (status, detail, probe-result).

    status is "ok", "skip" (message not in this database) or "error".
    """
    mid = message_id_for_subject(case["subject"])
    if not mid:
        return "skip", "not in this database", None

    html = html_for(mid)
    if not html.strip():
        return "skip", "message has no stored html body", None

    doc_path = os.path.join(out_dir, "case-%s.html" % case["slug"])
    png_path = os.path.join(out_dir, "case-%s.png" % case["slug"])
    js_path = os.path.join(out_dir, "case-%s.js" % case["slug"])
    with open(doc_path, "w") as f:
        f.write(build(html))
    with open(js_path, "w") as f:
        f.write(case["probe"])

    try:
        r = subprocess.run([os.path.join(HERE, "render"), doc_path, str(width),
                            png_path, app_js_path, js_path],
                           capture_output=True, text=True, timeout=45)
        d = json.loads(r.stdout.strip().split("\n")[-1])
    except Exception as e:
        return "error", "render failed: %s" % type(e).__name__, None

    if "case" not in d:
        # The probe slot is the sixth argument to `render`. A binary built
        # before it existed silently ignores the extra path and reports a
        # perfectly healthy-looking sweep with no case data in it.
        return "error", ("`render` ignored the case probe - rebuild it: "
                         "swiftc -O tools/render-audit/render.swift "
                         "-o tools/render-audit/render"), None
    c = d.get("case")
    if not isinstance(c, dict) or "error" in c:
        return "error", "probe returned %r" % (c,), None
    return "ok", mid, c


def check_all(width, build, app_js_path, out_dir, limits):
    """Run every named case. Returns (failure-lines, status-lines).

    A message that is not in this database is skipped, not failed. These are
    real messages from one developer's mailbox; a fresh clone will not have
    them, and a gate that fails on an empty database teaches people to pass
    `--no-verify`.
    """
    fails, notes = [], []
    for case in CASES:
        status, detail, c = run(case, width, build, app_js_path, out_dir)
        if status == "skip":
            notes.append("  %-14s SKIP  (%s)" % (case["slug"], detail))
            continue
        if status == "error":
            fails.append("case %s: %s" % (case["slug"], detail))
            notes.append("  %-14s ERROR (%s)" % (case["slug"], detail))
            continue
        case_fails = case["verify"](c, limits[case["limits"]])
        notes.append("  %-14s %s  %s" % (case["slug"],
                                         "FAIL" if case_fails else "ok",
                                         json.dumps({k: v for k, v in c.items()
                                                     if k != "boxes"})))
        fails.extend(case_fails)
    return fails, notes
