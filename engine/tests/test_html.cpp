/// @file test_html.cpp
/// @brief Sanitizer tests, written as attacks.
///
/// This is security code operating on hostile input, so the tests are phrased
/// as the bypasses a real payload would attempt rather than as happy paths.
/// Every case here is a technique that appears in published XSS filter-evasion
/// material.

#include <gtest/gtest.h>

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

// MARK: - Script removal

TEST(Sanitize, RemovesScriptTagsAndTheirContents) {
  const auto result = sanitize("<p>hi</p><script>alert(1)</script><p>bye</p>");
  EXPECT_FALSE(contains(result.html, "script"));
  EXPECT_FALSE(contains(result.html, "alert"));
  EXPECT_TRUE(result.removed_active_content);
  // Surrounding text must survive.
  EXPECT_TRUE(contains(result.html, "hi"));
  EXPECT_TRUE(contains(result.html, "bye"));
}

TEST(Sanitize, RemovesStyleContents) {
  // Remote CSS can fetch resources and overlay the interface.
  const auto html = clean("<style>body{background:url(http://tracker)}</style><p>x</p>");
  EXPECT_FALSE(contains(html, "tracker"));
  EXPECT_TRUE(contains(html, "x"));
}

TEST(Sanitize, RemovesEmbeddedFrameAndObjectElements) {
  for (const char* tag : {"iframe", "object", "embed", "applet", "form"}) {
    const std::string input =
        std::string("<") + tag + " src=\"http://evil\">inner</" + tag + ">";
    const auto html = clean(input);
    EXPECT_FALSE(contains(html, tag)) << tag;
    EXPECT_FALSE(contains(html, "evil")) << tag;
  }
}

TEST(Sanitize, RemovesBaseAndMetaWhichCanRedirectEveryLink) {
  EXPECT_FALSE(contains(clean("<base href=\"http://evil/\">"), "evil"));
  EXPECT_FALSE(contains(clean("<meta http-equiv=refresh content=\"0;url=http://evil\">"),
                        "evil"));
}

// MARK: - Event handlers

TEST(Sanitize, StripsEventHandlerAttributes) {
  for (const char* handler : {"onclick", "onerror", "onload", "onmouseover", "onfocus"}) {
    const std::string input = std::string("<p ") + handler + "=\"alert(1)\">x</p>";
    const auto result = sanitize(input);
    EXPECT_FALSE(contains(result.html, handler)) << handler;
    EXPECT_FALSE(contains(result.html, "alert")) << handler;
    EXPECT_TRUE(result.removed_active_content) << handler;
  }
}

TEST(Sanitize, StripsEventHandlersRegardlessOfCase) {
  EXPECT_FALSE(contains(clean("<p OnClick=\"alert(1)\">x</p>"), "alert"));
  EXPECT_FALSE(contains(clean("<p ONERROR=alert(1)>x</p>"), "alert"));
}

TEST(Sanitize, StripsUnquotedEventHandlerValues) {
  // Unquoted attribute values are a classic parser-confusion vector.
  EXPECT_FALSE(contains(clean("<img src=x onerror=alert(1)>"), "alert"));
}

// MARK: - URL schemes

TEST(SafeUrl, AcceptsOrdinarySchemes) {
  EXPECT_TRUE(is_safe_url("https://example.com/x"));
  EXPECT_TRUE(is_safe_url("http://example.com"));
  EXPECT_TRUE(is_safe_url("mailto:a@b.com"));
  EXPECT_TRUE(is_safe_url("cid:logo@example.com"));
  EXPECT_TRUE(is_safe_url("/relative/path"));
  EXPECT_TRUE(is_safe_url("../up"));
}

TEST(SafeUrl, RejectsScriptSchemes) {
  EXPECT_FALSE(is_safe_url("javascript:alert(1)"));
  EXPECT_FALSE(is_safe_url("vbscript:msgbox(1)"));
  EXPECT_FALSE(is_safe_url("data:text/html,<script>alert(1)</script>"));
  EXPECT_FALSE(is_safe_url("file:///etc/passwd"));
}

TEST(SafeUrl, SeesThroughCaseAndWhitespaceDisguises) {
  // Browsers ignore leading whitespace and control characters in URLs, and
  // schemes are case-insensitive, so the check must normalise before comparing.
  EXPECT_FALSE(is_safe_url("JaVaScRiPt:alert(1)"));
  EXPECT_FALSE(is_safe_url("  javascript:alert(1)"));
  EXPECT_FALSE(is_safe_url("java\tscript:alert(1)"));
  EXPECT_FALSE(is_safe_url("java\nscript:alert(1)"));
  EXPECT_FALSE(is_safe_url("\x01javascript:alert(1)"));
}

TEST(SafeUrl, SeesThroughEntityEncodedSchemes) {
  // `java&#115;cript:` reaches javascript: after the browser decodes entities.
  EXPECT_FALSE(is_safe_url("java&#115;cript:alert(1)"));
  EXPECT_FALSE(is_safe_url("&#106;avascript:alert(1)"));
  EXPECT_FALSE(is_safe_url("&#x6a;avascript:alert(1)"));
}

TEST(Sanitize, DropsUnsafeHrefButKeepsTheLinkText) {
  const auto result = sanitize("<a href=\"javascript:alert(1)\">click</a>");
  EXPECT_FALSE(contains(result.html, "javascript"));
  EXPECT_FALSE(contains(result.html, "alert"));
  EXPECT_TRUE(contains(result.html, "click"));
  EXPECT_TRUE(result.removed_active_content);
}

TEST(Sanitize, KeepsSafeLinksAndHardensThem) {
  const auto html = clean("<a href=\"https://example.com\">go</a>");
  EXPECT_TRUE(contains(html, "https://example.com"));
  // Prevents window.opener access and referrer leakage.
  EXPECT_TRUE(contains(html, "noopener"));
  EXPECT_TRUE(contains(html, "noreferrer"));
}

// MARK: - Tracking pixels

TEST(Sanitize, BlocksRemoteImagesByDefault) {
  const auto result = sanitize("<img src=\"https://tracker.example/pixel.gif\">");
  // The URL survives in an inert data- attribute so "load images" has
  // something to restore, but never as a live src that WebKit would fetch.
  EXPECT_FALSE(contains(result.html, " src=\"https://tracker.example"));
  EXPECT_TRUE(contains(result.html, "data-blocked-src="));
  EXPECT_EQ(result.blocked_remote_images, 1);
}

TEST(Sanitize, KeepsRemoteImagesWhenExplicitlyAllowed) {
  SanitizeOptions options;
  options.allow_remote_images = true;
  const auto result = sanitize("<img src=\"https://cdn.example/logo.png\">", options);
  EXPECT_TRUE(contains(result.html, "cdn.example"));
  EXPECT_EQ(result.blocked_remote_images, 0);
}

TEST(Sanitize, AlwaysKeepsInlineCidImages) {
  // cid: refers to an attachment already downloaded, so it leaks nothing.
  const auto result = sanitize("<img src=\"cid:logo@example.com\">");
  EXPECT_TRUE(contains(result.html, "cid:logo@example.com"));
  EXPECT_EQ(result.blocked_remote_images, 0);
}

// MARK: - Formatting preserved

TEST(Sanitize, KeepsOrdinaryFormatting) {
  const std::string input =
      "<p>Hello <b>bold</b> <i>italic</i></p>"
      "<ul><li>one</li><li>two</li></ul>"
      "<blockquote>quoted</blockquote>";
  const auto html = clean(input);

  for (const char* fragment : {"<p>", "<b>", "<i>", "<ul>", "<li>", "<blockquote>",
                               "bold", "italic", "one", "two", "quoted"}) {
    EXPECT_TRUE(contains(html, fragment)) << fragment;
  }
}

TEST(Sanitize, KeepsTableStructure) {
  const auto html = clean("<table><tr><td colspan=\"2\">cell</td></tr></table>");
  EXPECT_TRUE(contains(html, "<table>"));
  EXPECT_TRUE(contains(html, "colspan"));
  EXPECT_TRUE(contains(html, "cell"));
}

TEST(Sanitize, DropsClassAndFiltersStyle) {
  // This test used to assert that `style` was dropped wholesale. That policy
  // cost every message its design — see the Style suite — so `style` is now
  // filtered against a property allowlist instead of discarded.
  //
  // `class` is still dropped: without a stylesheet it does nothing, and
  // admitting one means admitting <style>, which this sanitiser cannot parse.
  const auto html = clean("<p style=\"color:red;position:fixed\" class=\"x\">t</p>");
  EXPECT_FALSE(contains(html, "class"));
  EXPECT_TRUE(contains(html, "color:red"));
  EXPECT_FALSE(contains(html, "position"));
  EXPECT_TRUE(contains(html, "t"));
}

TEST(Sanitize, KeepsTextInsideUnknownTags) {
  // An unrecognised wrapper should not take its content with it.
  EXPECT_TRUE(contains(clean("<custom-tag>visible</custom-tag>"), "visible"));
  EXPECT_FALSE(contains(clean("<custom-tag>visible</custom-tag>"), "custom-tag"));
}

// MARK: - Malformed input

TEST(Sanitize, EscapesStrayAngleBrackets) {
  const auto html = clean("5 < 7 and 9 > 3");
  EXPECT_TRUE(contains(html, "&lt;"));
  EXPECT_FALSE(contains(html, "<script"));
}

TEST(Sanitize, HandlesUnclosedTagsWithoutLosingText) {
  EXPECT_TRUE(contains(clean("<p>unclosed"), "unclosed"));
  EXPECT_TRUE(contains(clean("<b><i>nested"), "nested"));
}

TEST(Sanitize, HandlesUnterminatedScriptByDroppingTheRest) {
  // A script that is never closed must not have its contents emitted.
  const auto html = clean("<p>before</p><script>alert(1)");
  EXPECT_TRUE(contains(html, "before"));
  EXPECT_FALSE(contains(html, "alert"));
}

TEST(Sanitize, IgnoresCommentsIncludingConditionalOnes) {
  EXPECT_FALSE(contains(clean("<!-- <script>alert(1)</script> -->"), "alert"));
  EXPECT_FALSE(contains(clean("<!--[if IE]><script>alert(1)</script><![endif]-->"),
                        "alert"));
}

TEST(Sanitize, HandlesEmptyAndPlainInput) {
  EXPECT_EQ(clean(""), "");
  EXPECT_EQ(clean("just text"), "just text");
}

TEST(Sanitize, IsIdempotent) {
  // Sanitizing already-sanitized output must not corrupt or re-open it.
  const std::string input =
      "<p>Hello <a href=\"https://example.com\">link</a></p><script>alert(1)</script>";
  const std::string once = clean(input);
  EXPECT_EQ(clean(once), once);
}

TEST(Sanitize, NeverEmitsAngleBracketsFromAttributeValues) {
  // An attribute value containing markup must not break out of the tag.
  const auto html = clean("<a href=\"https://x.com\" title=\"&quot;><script>\">t</a>");
  EXPECT_FALSE(contains(html, "<script"));
}

// MARK: - Entity decoding
//
// Gmail returns `snippet` HTML-escaped, so without this a list row shows
// "Next week&#39;s menu" instead of an apostrophe.

TEST(Unescape, DecodesNamedEntities) {
  EXPECT_EQ(unescape_entities("a &amp; b"), "a & b");
  EXPECT_EQ(unescape_entities("&lt;tag&gt;"), "<tag>");
  EXPECT_EQ(unescape_entities("say &quot;hi&quot;"), "say \"hi\"");
}

TEST(Unescape, DecodesNumericReferences) {
  EXPECT_EQ(unescape_entities("you&#39;d"), "you'd");
  EXPECT_EQ(unescape_entities("week&#39;s"), "week's");
  EXPECT_EQ(unescape_entities("&#x27;"), "'");
}

TEST(Unescape, DecodesNonAsciiAsUtf8) {
  EXPECT_EQ(unescape_entities("caf&#233;"), "café");
  EXPECT_EQ(unescape_entities("&#8212;"), "—");
}

TEST(Unescape, LeavesBareAmpersandsAlone) {
  EXPECT_EQ(unescape_entities("Tom & Jerry"), "Tom & Jerry");
  EXPECT_EQ(unescape_entities("a & b & c"), "a & b & c");
  // A semicolon far away is not an entity terminator.
  EXPECT_EQ(unescape_entities("A & B; C"), "A & B; C");
}

TEST(Unescape, LeavesUnknownEntitiesIntact) {
  EXPECT_EQ(unescape_entities("&notarealentity;"), "&notarealentity;");
}

TEST(Unescape, HandlesEmptyInput) {
  EXPECT_EQ(unescape_entities(""), "");
}

TEST(Sanitize, PreservesEntitiesInsteadOfDoubleEncodingThem) {
  // Escaping an ampersand that already begins an entity turns "&nbsp;" into
  // "&amp;nbsp;", which the browser then renders as the literal characters.
  // The entity is passed through untouched so the browser interprets it.
  const auto html = clean("<p>Hello&nbsp;world</p>");
  EXPECT_FALSE(contains(html, "&amp;nbsp"));
  EXPECT_TRUE(contains(html, "&nbsp;"));

  // A literal ampersand IS an entity already and stays one.
  const auto quoted = clean("<p>Tom &amp; Jerry</p>");
  EXPECT_FALSE(contains(quoted, "&amp;amp;"));
  EXPECT_TRUE(contains(quoted, "&amp;"));
}

TEST(Sanitize, PreservesEntitiesNobodyKeepsATableOf) {
  // Straight from a real marketing email, which padded its preheader with
  // hundreds of these. A fixed table of known entity names left every one of
  // them double-encoded, so the message opened with a visible paragraph of
  // "&#847; &zwnj; &nbsp; &#8199; &shy;" repeated across the screen.
  const auto html = clean("<p>text&#847; &zwnj; &nbsp; &#8199; &shy;end</p>");

  for (const char* entity : {"&#847;", "&zwnj;", "&nbsp;", "&#8199;", "&shy;"}) {
    EXPECT_TRUE(contains(html, entity)) << entity << " was mangled";
  }
  EXPECT_FALSE(contains(html, "&amp;#847")) << "double-encoded";
  EXPECT_FALSE(contains(html, "&amp;zwnj")) << "double-encoded";
}

TEST(Sanitize, PreservesHexAndDecimalCharacterReferences) {
  const auto html = clean("<p>&#x1F600; and &#128512;</p>");
  EXPECT_TRUE(contains(html, "&#x1F600;"));
  EXPECT_TRUE(contains(html, "&#128512;"));
}

TEST(Sanitize, StillEscapesAnAmpersandThatIsNotAnEntity) {
  // The escape must not become a free pass. A bare ampersand, or one that only
  // looks like the start of an entity, has to be escaped or a crafted body
  // could smuggle markup past this.
  for (const char* input : {"<p>Tom & Jerry</p>", "<p>a &notanentity b</p>",
                            "<p>x &# y</p>", "<p>q &#zz; r</p>"}) {
    const auto html = clean(input);
    EXPECT_TRUE(contains(html, "&amp;")) << input << " left a bare ampersand";
  }
}

TEST(Sanitize, KeepsTheUrlOfABlockedImageSoItCanBeLoadedLater) {
  // Discarding the src meant the only way to ever see a blocked image was to
  // re-fetch the entire message from Gmail.
  const auto html = clean("<img src=\"https://tracker.example/pixel.gif\" alt=\"x\">");

  EXPECT_TRUE(contains(html, "data-blocked=\"remote\""));
  EXPECT_TRUE(contains(html, "data-blocked-src="));
  EXPECT_TRUE(contains(html, "tracker.example/pixel.gif"));
  // Still not loadable. Checked with a LEADING SPACE: `data-blocked-src="`
  // ends in `src="` too, so the naive substring matches the very attribute
  // this is meant to distinguish from a live one.
  EXPECT_FALSE(contains(html, " src=\"https://"));
}

TEST(Sanitize, DropsSenderSuppliedDataAttributes) {
  // The reading pane restores `data-blocked-src` into a live `src` when the
  // user asks for images. That is only safe because a SENDER cannot put that
  // attribute there: the allowlist admits title, alt, href, src, width,
  // height, colspan and rowspan, and nothing else survives.
  const auto html = clean(
      "<img data-blocked-src=\"https://evil.example/x.gif\" "
      "data-anything=\"y\" alt=\"x\">");

  EXPECT_FALSE(contains(html, "evil.example"));
  EXPECT_FALSE(contains(html, "data-anything"));
  EXPECT_TRUE(contains(html, "alt=")) << "allowed attributes must survive";
}

// MARK: - Preheader padding
//
// Bulk senders pad the inbox preview with long runs of invisible characters so
// the preview shows their tagline rather than body text. 996 messages in a real
// mailbox carry it. It is meant to be invisible, and usually is — but it leaves
// a wall of whitespace at the top of the body, and one sender double-encoded it
// (`&amp;shy;`) so it rendered as the literal text "&shy; &shy; &shy;".

TEST(Padding, CollapsesRunsOfInvisibleEntities) {
  const std::string padded =
      "Ordered: item&#847; &zwnj; &nbsp; &#8199; &shy;&#847; &zwnj; &nbsp; "
      "&#8199; &shy;&#847; &zwnj; &nbsp; &#8199; &shy;Real body text";
  const std::string out = collapse_padding(padded);
  EXPECT_FALSE(contains(out, "shy"));
  EXPECT_FALSE(contains(out, "zwnj"));
  EXPECT_TRUE(contains(out, "Ordered: item"));
  EXPECT_TRUE(contains(out, "Real body text"));
}

TEST(Padding, CollapsesDoubleEncodedPadding) {
  // The exact shape of the message that rendered visible "&shy;" text.
  const std::string out =
      collapse_padding("Hi&amp;shy; &amp;shy; &amp;shy; &amp;shy; &amp;shy; there");
  EXPECT_FALSE(contains(out, "shy"));
  EXPECT_TRUE(contains(out, "Hi"));
  EXPECT_TRUE(contains(out, "there"));
}

TEST(Padding, CollapsesLiteralInvisibleCharacters) {
  // Already-decoded form: U+00AD soft hyphen and U+200C zero-width non-joiner.
  const std::string out =
      collapse_padding("Hi­ ‌   ­ ‌ ­ there");
  EXPECT_TRUE(contains(out, "Hi"));
  EXPECT_TRUE(contains(out, "there"));
  EXPECT_EQ(out.find("­"), std::string::npos);
}

TEST(Padding, LeavesOrdinaryTextAlone) {
  EXPECT_EQ(collapse_padding("Hello, world."), "Hello, world.");
  EXPECT_EQ(collapse_padding("a &amp; b"), "a &amp; b");
  // Ordinary non-breaking spaces are meaningful and must survive.
  EXPECT_EQ(collapse_padding("10&nbsp;kg"), "10&nbsp;kg");
  EXPECT_EQ(collapse_padding("Mr&nbsp;Smith and Mrs&nbsp;Jones"),
            "Mr&nbsp;Smith and Mrs&nbsp;Jones");
}

TEST(Padding, LeavesOccasionalSoftHyphensAlone) {
  // A soft hyphen used for its actual purpose is a hyphenation hint, not
  // padding. Only a dense run is padding.
  EXPECT_EQ(collapse_padding("hy&shy;phen&shy;ation"), "hy&shy;phen&shy;ation");
}

TEST(Padding, DoesNotTouchMarkup) {
  // Tags must survive byte-identical: this runs over already-sanitised bodies
  // where `data-blocked-src` holds the only copy of a blocked image URL.
  const std::string html =
      "<img data-blocked=\"remote\" data-blocked-src=\"https://x.test/a.png\" />"
      "text&shy; &shy; &shy; &shy; &shy; after";
  const std::string out = collapse_padding(html);
  EXPECT_TRUE(contains(out, "data-blocked-src=\"https://x.test/a.png\""));
  EXPECT_TRUE(contains(out, "<img"));
  EXPECT_FALSE(contains(out, "shy;"));
}

TEST(Padding, SanitizeCollapsesPadding) {
  const auto result =
      sanitize("<p>Deal&shy; &zwnj; &shy; &zwnj; &shy; &zwnj; inside</p>");
  EXPECT_FALSE(contains(result.html, "shy"));
  EXPECT_TRUE(contains(result.html, "Deal"));
  EXPECT_TRUE(contains(result.html, "inside"));
}

// MARK: - Presentational styling
//
// Mail is a styled document. Stripping every presentational attribute left
// navy header bars, orange buttons and hero images rendering as a flat stack
// of blue underlined links -- correct, inert, and nothing like the message the
// sender wrote. These tests hold the line between "styled" and "dangerous".

TEST(Style, KeepsOrdinaryDeclarations) {
  const auto out = sanitize(
      R"(<td style="background-color:#003057;color:#fff;text-align:center">x</td>)");
  EXPECT_TRUE(contains(out.html, "background-color:#003057"));
  EXPECT_TRUE(contains(out.html, "color:#fff"));
  EXPECT_TRUE(contains(out.html, "text-align:center"));
}

TEST(Style, KeepsPresentationalAttributes) {
  const auto out = sanitize(
      R"(<table bgcolor="#003057" width="600" align="center" cellpadding="0">)"
      R"(<tr><td valign="top" height="40">x</td></tr></table>)");
  EXPECT_TRUE(contains(out.html, "bgcolor=\"#003057\""));
  EXPECT_TRUE(contains(out.html, "width=\"600\""));
  EXPECT_TRUE(contains(out.html, "align=\"center\""));
  EXPECT_TRUE(contains(out.html, "valign=\"top\""));
}

TEST(Style, DropsScriptingProperties) {
  // IE-era CSS expressions are executable content wearing a style attribute.
  const auto out = sanitize(
      R"CSS(<div style="width:expression(alert(1));color:red">x</div>)CSS");
  EXPECT_FALSE(contains(out.html, "expression"));
  EXPECT_TRUE(contains(out.html, "color:red"));
  EXPECT_TRUE(out.removed_active_content);
}

TEST(Style, DropsBehaviourAndBinding) {
  for (const std::string attack : {"behavior:url(#default#time2)",
                                   "-moz-binding:url(http://evil.test/x.xml)"}) {
    const auto out = sanitize("<div style=\"" + attack + "\">x</div>");
    EXPECT_FALSE(contains(out.html, "behavior"));
    EXPECT_FALSE(contains(out.html, "binding"));
  }
}

TEST(Style, DropsPositioningThatCouldOverlayTheInterface) {
  // A fixed overlay is how a message would try to draw fake app chrome.
  const auto out = sanitize(
      R"(<div style="position:fixed;top:0;left:0;z-index:9999;color:red">x</div>)");
  EXPECT_FALSE(contains(out.html, "position"));
  EXPECT_FALSE(contains(out.html, "z-index"));
  EXPECT_TRUE(contains(out.html, "color:red"));
}

TEST(Style, AllowsImageUrlsButOnlySafeSchemes) {
  // Hero images in mail are CSS backgrounds. The scheme is checked here; the
  // CSP decides whether the fetch is actually permitted at render time.
  const auto ok = sanitize(
      R"CSS(<td style="background-image:url(https://cdn.test/hero.jpg)">x</td>)CSS");
  EXPECT_TRUE(contains(ok.html, "background-image:url(https://cdn.test/hero.jpg)"));

  for (const std::string attack : {"background-image:url(javascript:alert(1))",
                                   "background:url('vbscript:x')",
                                   "background-image:url(\"data:text/html,<script>\")"}) {
    const auto out = sanitize("<div style=\"" + attack + "\">x</div>");
    EXPECT_FALSE(contains(out.html, "javascript"));
    EXPECT_FALSE(contains(out.html, "vbscript"));
    EXPECT_FALSE(contains(out.html, "text/html"));
  }
}

TEST(Style, DropsImportAndEscapes) {
  // Backslash escapes are the standard way to spell a blocked keyword.
  const auto out = sanitize(
      R"CSS(<div style="color:\65 xpression(alert(1));background:red">x</div>)CSS");
  EXPECT_FALSE(contains(out.html, "\\65"));
  const auto imported = sanitize(R"CSS(<div style="@import url(http://evil.test)">x</div>)CSS");
  EXPECT_FALSE(contains(imported.html, "@import"));
}

TEST(Style, StillDropsClassAndStyleBlocks) {
  // `class` without a stylesheet is dead weight, and a <style> block is a
  // whole CSS surface -- selectors, media queries, @import -- that this
  // sanitiser does not parse and therefore cannot vouch for.
  const auto out = sanitize(R"(<style>.a{color:red}</style><div class="a">x</div>)");
  EXPECT_FALSE(contains(out.html, "class="));
  EXPECT_FALSE(contains(out.html, "color:red"));
}

TEST(Style, StillDropsEventHandlersAlongsideStyle) {
  const auto out = sanitize(
      R"CSS(<div style="color:red" onclick="alert(1)" onmouseover="x()">hi</div>)CSS");
  EXPECT_TRUE(contains(out.html, "color:red"));
  EXPECT_FALSE(contains(out.html, "onclick"));
  EXPECT_FALSE(contains(out.html, "onmouseover"));
  EXPECT_TRUE(out.removed_active_content);
}

// MARK: - Inline image data
//
// 979 images across a real mailbox had no source at all: `is_safe_url` allowed
// only http/https/mailto/cid, so every base64-inlined image was discarded. Two
// bugs compounded — the scheme was rejected, AND the declaration splitter cut
// at the `;` inside `data:image/png;base64,`, so a background survived neither
// check.

TEST(DataURI, KeepsInlineImageSources) {
  const auto out = sanitize(
      R"HTML(<img src="data:image/png;base64,iVBORw0KGgo=" width="20">)HTML");
  EXPECT_TRUE(contains(out.html, "data:image/png;base64,iVBORw0KGgo="));
}

TEST(DataURI, KeepsInlineImageBackgrounds) {
  const auto out = sanitize(
      R"HTML(<td style="background-image:url(data:image/gif;base64,R0lGOD=)">x</td>)HTML");
  EXPECT_TRUE(contains(out.html, "data:image/gif;base64,R0lGOD="));
}

TEST(DataURI, SemicolonInsideAUrlDoesNotSplitTheDeclaration) {
  // The splitter cut here, leaving `base64,R0lGOD=)` as a junk declaration and
  // dropping the background entirely while the later ones survived.
  const auto out = sanitize(
      R"HTML(<td style="background:url(data:image/gif;base64,R0lGOD=);color:#fff;padding:10px">x</td>)HTML");
  EXPECT_TRUE(contains(out.html, "base64,R0lGOD="));
  EXPECT_TRUE(contains(out.html, "color:#fff"));
  EXPECT_TRUE(contains(out.html, "padding:10px"));
}

TEST(DataURI, RejectsEverythingThatIsNotAnImage) {
  // The whole point of admitting `data:` is pictures. A data URL that declares
  // any other type is a document the browser might interpret.
  for (const std::string attack : {"data:text/html,<script>alert(1)</script>",
                                   "data:text/html;base64,PHNjcmlwdD4=",
                                   "data:application/javascript,alert(1)",
                                   "data:image/svg+xml,<svg onload=alert(1)>"}) {
    const auto out = sanitize("<img src=\"" + attack + "\">");
    EXPECT_FALSE(contains(out.html, "text/html"));
    EXPECT_FALSE(contains(out.html, "javascript"));
    // SVG is an image type that can carry script, so it stays out too.
    EXPECT_FALSE(contains(out.html, "svg+xml"));
  }
}

TEST(DataURI, RejectsNonImageDataInStyles) {
  const auto out = sanitize(
      R"HTML(<td style="background-image:url(data:text/html;base64,PHNjcmlwdD4=)">x</td>)HTML");
  EXPECT_FALSE(contains(out.html, "text/html"));
}

// MARK: - Void elements must not swallow the document
//
// `<link>`, `<meta>` and `<base>` are VOID elements: they have no closing tag
// and no contents. They were listed among the tags whose contents get
// discarded, so the sanitiser searched for `</link>`, never found one, and
// threw away everything from there to the end of the document.
//
// Google puts schema.org markup — `<link itemprop="url">` — in the body of its
// security alerts. A real one arrived as 4800 bytes from Gmail and was stored
// as 194: the message rendered as an empty white box. 909 stored messages have
// an HTML body under a quarter the size of their plain text.

TEST(VoidElements, LinkDoesNotDiscardTheRestOfTheDocument) {
  const auto html = clean(
      R"HTML(<p>before</p><link itemprop="url" href="https://x.test/a"/><p>after</p>)HTML");
  EXPECT_TRUE(contains(html, "before"));
  EXPECT_TRUE(contains(html, "after"));
  // The element itself is still gone.
  EXPECT_FALSE(contains(html, "<link"));
}

TEST(VoidElements, MetaAndBaseDoNotDiscardTheRestOfTheDocument) {
  for (const std::string tag : {"meta", "base"}) {
    const auto html = clean("<p>before</p><" + tag + " href=\"http://evil/\"><p>after</p>");
    EXPECT_TRUE(contains(html, "before")) << tag;
    EXPECT_TRUE(contains(html, "after")) << tag;
    EXPECT_FALSE(contains(html, "evil")) << tag;
  }
}

TEST(VoidElements, SchemaOrgMarkupKeepsTheMessage) {
  // The exact shape from a Google security alert.
  const auto html = clean(
      R"HTML(<div itemscope itemtype="//schema.org/EmailMessage">)HTML"
      R"HTML(<div itemprop="action" itemscope><link itemprop="url" href="https://accounts.google.com/x"/>)HTML"
      R"HTML(<meta itemprop="name" content="Review"/></div></div><p>Your password was changed.</p>)HTML");
  EXPECT_TRUE(contains(html, "Your password was changed."));
}

// An unterminated content-bearing tag still takes the rest of the document
// with it — see Sanitize.HandlesUnterminatedScriptByDroppingTheRest. That is
// deliberate: skipping just the tag would spill `alert(1)` into the page as
// visible text. Void elements are the ones that must not do this, because they
// have no closing tag to find in the first place.

TEST(VoidElements, AClosedScriptStillSwallowsItsContents) {
  const auto result = sanitize("<p>a</p><script>alert(1)</script><p>b</p>");
  EXPECT_FALSE(contains(result.html, "alert"));
  EXPECT_TRUE(contains(result.html, "a"));
  EXPECT_TRUE(contains(result.html, "b"));
}
