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
  EXPECT_FALSE(contains(result.html, "tracker.example"));
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

TEST(Sanitize, DropsStyleAndClassAttributes) {
  // Inline CSS can fetch remote resources and overlay the interface.
  const auto html = clean("<p style=\"background:url(http://evil)\" class=\"x\">t</p>");
  EXPECT_FALSE(contains(html, "style"));
  EXPECT_FALSE(contains(html, "evil"));
  EXPECT_FALSE(contains(html, "class"));
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
