/// @file html.cpp
/// @brief Allowlist HTML sanitizer.

#include "mailengine/html.hpp"

#include <algorithm>
#include <cctype>
#include <string_view>
#include <cstdlib>
#include <unordered_map>
#include <unordered_set>
#include <vector>

namespace mailengine::html {
namespace {

/// Tags kept in the output. Everything else is dropped, though for most of
/// them the CONTENTS are preserved — an unknown `<foo>` wrapper should not
/// take its text with it.
const std::unordered_set<std::string>& allowed_tags() {
  static const std::unordered_set<std::string> tags = {
      "p", "br", "hr", "div", "span", "blockquote", "pre", "code",
      "b", "strong", "i", "em", "u", "s", "strike", "sub", "sup", "small",
      "h1", "h2", "h3", "h4", "h5", "h6",
      "ul", "ol", "li", "dl", "dt", "dd",
      "table", "thead", "tbody", "tfoot", "tr", "td", "th", "caption",
      "a", "img", "figure", "figcaption", "font", "center",
      // `style` is HERE rather than in `void_content_tags` because its
      // contents are now filtered CSS instead of discarded text. See the
      // stylesheet section below for what that filtering costs and buys.
      "style",
  };
  return tags;
}

/// Tags whose CONTENTS are discarded along with the tag.
///
/// These carry executable or externally-fetched material rather than text, so
/// preserving what is inside them would defeat the point.
///
/// `head` is deliberately ABSENT. It was here, and it meant the entire head —
/// including the `<style>` block — was discarded before the stylesheet
/// handling could ever see it. Real mail puts its stylesheet in the head, so
/// the whole feature silently did nothing on real messages while every test
/// passed: the tests all used a bare `<style>` fragment. The head's own
/// children are dropped by the allowlist anyway (`meta`, `link`, `base` as
/// void tags, `title` still by content), so nothing is gained by discarding
/// the element wholesale and a stylesheet is lost by it.
///
/// Every tag here must actually HAVE contents — that is, a closing partner.
/// `link`, `meta` and `base` used to be in this set and are void elements with
/// no closing tag, so the scan for `</link>` ran off the end of the document
/// and took the whole message with it. Google puts `<link itemprop="url">`
/// schema.org markup in the body of its security alerts; one arrived as 4800
/// bytes and was stored as 194.
///
/// `style` left this set for the opposite reason: it does have a closing
/// partner, but its contents are no longer worthless. They are parsed and
/// filtered by `sanitize_stylesheet`, so `sanitize()` handles the element
/// itself and never reaches this branch for it.
const std::unordered_set<std::string>& void_content_tags() {
  static const std::unordered_set<std::string> tags = {
      "script", "iframe", "object", "embed", "applet", "form",
      "noscript", "template", "svg", "math", "title",
  };
  return tags;
}

/// Void elements that are dropped, but which enclose nothing.
///
/// Kept out of `void_content_tags` because they have no closing tag. They are
/// not in the allowlist either, so the tag itself never reaches the output —
/// this set exists only to record that dropping them is deliberate.
bool is_dropped_void_tag(std::string_view tag) {
  return tag == "link" || tag == "meta" || tag == "base";
}

/// Tags that never have a closing partner.
const std::unordered_set<std::string>& self_closing_tags() {
  static const std::unordered_set<std::string> tags = {"br", "hr", "img"};
  return tags;
}

/// Attributes kept, per tag.
///
/// Deliberately tiny. `style` and `class` are the two that carry CSS, and both
/// are admitted only because their reach is bounded by the same property
/// allowlist — `style` through `sanitize_style`, `class` through the rules
/// that survive `sanitize_stylesheet`. Neither can name a property that the
/// other could not.
bool attribute_allowed(std::string_view tag, std::string_view name) {
  // Presentational attributes are how mail has always been laid out: table
  // cells with `bgcolor`, `align` and `width` predate CSS in email and are
  // still what most senders emit. They carry no behaviour — the values are
  // escaped on the way out and cannot be read as markup — so the earlier
  // decision to drop them bought nothing and cost every message its design.
  if (name == "title" || name == "alt" || name == "dir" || name == "lang") return true;
  if (name == "style") return true;  // filtered by sanitize_style, not passed through
  if (name == "align" || name == "valign" || name == "bgcolor") return true;
  if (name == "width" || name == "height") return true;

  if (tag == "a" && name == "href") return true;
  if (tag == "img" && (name == "src" || name == "border")) return true;
  if (tag == "font" && (name == "color" || name == "face" || name == "size")) return true;
  if ((tag == "td" || tag == "th") && (name == "colspan" || name == "rowspan")) {
    return true;
  }
  if (tag == "table" &&
      (name == "cellpadding" || name == "cellspacing" || name == "border")) {
    return true;
  }
  // `class` comes in with the stylesheet, because on its own neither is worth
  // anything. All 14 sampled messages laid themselves out with a <style> block
  // addressed by class, and 13 of them used @media or a show/hide class: with
  // the pair dropped, a three-across product grid rendered one item per row,
  // and `.mobile-hide` / `.showdesktop` stopped hiding anything, so the
  // desktop and mobile copies of a button drew on top of each other.
  //
  // The attribute value itself carries no behaviour. It is escaped on the way
  // out like any other, and the only declarations it can select are ones that
  // already passed `style_property_allowed`.
  if (name == "class") return true;
  return false;
}

char lower(char c) {
  return static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
}

std::string to_lower(std::string_view value) {
  std::string out;
  out.reserve(value.size());
  for (const char c : value) out += lower(c);
  return out;
}

bool is_space(char c) {
  return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f' || c == '\v';
}

std::string trimmed(std::string_view text) {
  size_t begin = 0;
  size_t end = text.size();
  while (begin < end && is_space(text[begin])) ++begin;
  while (end > begin && is_space(text[end - 1])) --end;
  return std::string(text.substr(begin, end - begin));
}

/// Decodes the entity and escape tricks used to disguise a URL scheme.
///
/// `java&#115;cript:` and `java\tscript:` both reach `javascript:` in a
/// browser, so the scheme check has to see through them.
std::string normalise_scheme_prefix(const std::string& url) {
  std::string out;
  for (size_t i = 0; i < url.size() && out.size() < 32; ++i) {
    const char c = url[i];
    // Whitespace and control characters are ignored by URL parsers.
    if (is_space(c) || static_cast<unsigned char>(c) < 0x20) continue;
    if (c == '&' && i + 2 < url.size() && url[i + 1] == '#') {
      // Numeric character reference: decode it and continue.
      size_t j = i + 2;
      int base = 10;
      if (j < url.size() && (url[j] == 'x' || url[j] == 'X')) {
        base = 16;
        ++j;
      }
      int value = 0;
      bool any = false;
      while (j < url.size() && std::isalnum(static_cast<unsigned char>(url[j])) != 0) {
        const int digit = std::isdigit(static_cast<unsigned char>(url[j]))
                              ? url[j] - '0'
                              : lower(url[j]) - 'a' + 10;
        if (digit >= base) break;
        value = value * base + digit;
        any = true;
        ++j;
      }
      if (any) {
        if (value > 0 && value < 128) out += lower(static_cast<char>(value));
        if (j < url.size() && url[j] == ';') ++j;
        i = j - 1;
        continue;
      }
    }
    out += lower(c);
    if (c == ':') break;
  }
  return out;
}


// MARK: - Preheader padding

/// Characters that occupy no width at all.
///
/// Each of these is used by bulk senders to pad the inbox preview. None of
/// them carries meaning in a message body, which is why a dense run of them is
/// safe to discard entirely.
bool is_invisible_codepoint(long cp) {
  switch (cp) {
    case 0x00AD:  // soft hyphen
    case 0x034F:  // combining grapheme joiner, sent as &#847;
    case 0x061C:  // arabic letter mark
    case 0x180E:  // mongolian vowel separator
    case 0x200B:  // zero-width space
    case 0x200C:  // zero-width non-joiner
    case 0x200D:  // zero-width joiner
    case 0x200E:  // left-to-right mark
    case 0x200F:  // right-to-left mark
    case 0x2060:  // word joiner
    case 0xFEFF:  // zero-width no-break space
      return true;
    default:
      return false;
  }
}

/// Characters that render as blank space.
///
/// These are NOT padding on their own — `10&nbsp;kg` is a real space doing a
/// real job. They only count as part of a run that already contains invisible
/// characters, which is what lets a padding block collapse whole.
bool is_blank_codepoint(long cp) {
  switch (cp) {
    case 0x0009: case 0x000A: case 0x000D: case 0x0020:
    case 0x00A0:  // no-break space
    case 0x2002: case 0x2003: case 0x2007:  // en, em, figure space
    case 0x2009: case 0x200A:               // thin, hair space
      return true;
    default:
      return false;
  }
}

/// Codepoint for a named reference, or -1. Only names that can appear in
/// padding need resolving here; everything else falls through as ordinary text.
long padding_entity_codepoint(const std::string& name) {
  static const std::unordered_map<std::string, long> named = {
      {"shy", 0x00AD},   {"zwnj", 0x200C},  {"zwj", 0x200D},
      {"lrm", 0x200E},   {"rlm", 0x200F},   {"zwsp", 0x200B},
      {"wj", 0x2060},    {"feff", 0xFEFF},  {"nbsp", 0x00A0},
      {"ensp", 0x2002},  {"emsp", 0x2003},  {"numsp", 0x2007},
      {"thinsp", 0x2009},{"hairsp", 0x200A},
  };
  const auto found = named.find(to_lower(name));
  return found == named.end() ? -1 : found->second;
}

/// Reads one character reference at `at`, returning its codepoint and length.
/// Returns false when `at` does not begin a reference this cares about.
bool read_reference(const std::string& text, size_t at, long& cp, size_t& length) {
  if (text[at] != '&') return false;
  const size_t semicolon = text.find(';', at + 1);
  if (semicolon == std::string::npos || semicolon - at > 12) return false;

  const std::string body = text.substr(at + 1, semicolon - at - 1);
  if (body.empty()) return false;
  length = semicolon - at + 1;

  if (body[0] == '#') {
    const bool hex = body.size() > 1 && (body[1] == 'x' || body[1] == 'X');
    const std::string digits = body.substr(hex ? 2 : 1);
    if (digits.empty()) return false;
    const char* allowed = hex ? "0123456789abcdefABCDEF" : "0123456789";
    if (digits.find_first_not_of(allowed) != std::string::npos) return false;
    cp = std::strtol(digits.c_str(), nullptr, hex ? 16 : 10);
    return true;
  }

  cp = padding_entity_codepoint(body);
  return cp >= 0;
}

/// Decodes one UTF-8 sequence at `at`.
bool read_utf8(const std::string& text, size_t at, long& cp, size_t& length) {
  const auto byte = static_cast<unsigned char>(text[at]);
  const size_t n = text.size();
  auto continuation = [&](size_t k) {
    return at + k < n && (static_cast<unsigned char>(text[at + k]) & 0xC0) == 0x80;
  };
  auto tail = [&](size_t k) { return static_cast<long>(text[at + k] & 0x3F); };

  if (byte < 0x80) { cp = byte; length = 1; return true; }
  if ((byte & 0xE0) == 0xC0 && continuation(1)) {
    cp = ((byte & 0x1FL) << 6) | tail(1);
    length = 2;
    return true;
  }
  if ((byte & 0xF0) == 0xE0 && continuation(1) && continuation(2)) {
    cp = ((byte & 0x0FL) << 12) | (tail(1) << 6) | tail(2);
    length = 3;
    return true;
  }
  return false;
}

/// How many invisible characters make a run padding rather than typography.
///
/// Ordinary prose can carry one soft hyphen as a hyphenation hint, or a
/// zero-width joiner inside an emoji sequence. Four of them inside a single
/// run of otherwise-blank text is not typography; it is padding.
constexpr int kPaddingThreshold = 4;

/// Rewrites the padding runs in a stretch of text.
std::string collapse_padding_in_text(const std::string& text) {
  std::string out;
  out.reserve(text.size());

  size_t i = 0;
  const size_t n = text.size();

  while (i < n) {
    // Try to open a run at `i`.
    size_t scan = i;
    int invisible = 0;

    while (scan < n) {
      long cp = -1;
      size_t length = 0;

      // `&amp;shy;` — the double-encoded form. The `&amp;` decodes to a bare
      // ampersand which then re-reads as the entity that follows it.
      if (text.compare(scan, 5, "&amp;") == 0) {
        long inner = -1;
        size_t inner_length = 0;
        const std::string rebuilt = "&" + text.substr(scan + 5, 12);
        if (read_reference(rebuilt, 0, inner, inner_length) &&
            (is_invisible_codepoint(inner) || is_blank_codepoint(inner))) {
          cp = inner;
          length = 5 + inner_length - 1;
        }
      }

      if (cp < 0 && !read_reference(text, scan, cp, length) &&
          !read_utf8(text, scan, cp, length)) {
        break;
      }

      if (is_invisible_codepoint(cp)) {
        ++invisible;
      } else if (!is_blank_codepoint(cp)) {
        break;
      }
      scan += length;
    }

    if (invisible >= kPaddingThreshold) {
      // The whole run goes, replaced by the single space it was pretending to
      // be. Anything less dense is left byte-identical.
      out += ' ';
      i = scan;
      continue;
    }

    out += text[i];
    ++i;
  }

  return out;
}

}  // namespace

std::string collapse_padding(const std::string& html) {
  std::string out;
  out.reserve(html.size());

  size_t i = 0;
  const size_t n = html.size();

  while (i < n) {
    if (html[i] == '<') {
      // Markup is copied verbatim, byte for byte. This runs over
      // already-sanitised bodies, where `data-blocked-src` holds the only
      // surviving copy of a blocked image URL.
      const size_t end = html.find('>', i);
      if (end == std::string::npos) {
        out += html.substr(i);
        break;
      }
      out += html.substr(i, end - i + 1);
      i = end + 1;
      continue;
    }
    const size_t start = i;
    while (i < n && html[i] != '<') ++i;
    out += collapse_padding_in_text(html.substr(start, i - start));
  }

  return out;
}

std::string unescape_entities(const std::string& text) {
  static const std::unordered_map<std::string, std::string> named = {
      {"amp", "&"},   {"lt", "<"},     {"gt", ">"},     {"quot", "\""},
      {"apos", "'"},  {"nbsp", " "},   {"mdash", "—"},  {"ndash", "–"},
      {"hellip", "…"},{"rsquo", "\u2019"}, {"lsquo", "\u2018"},
      {"ldquo", "\u201C"}, {"rdquo", "\u201D"}, {"trade", "™"},
      {"copy", "©"},  {"reg", "®"},    {"deg", "°"},    {"euro", "€"},
      {"pound", "£"}, {"middot", "·"}, {"bull", "•"},
  };

  std::string out;
  out.reserve(text.size());

  for (size_t i = 0; i < text.size(); ++i) {
    if (text[i] != '&') {
      out += text[i];
      continue;
    }
    const size_t semicolon = text.find(';', i + 1);
    // Entities are short; a distant semicolon means this is just an ampersand.
    if (semicolon == std::string::npos || semicolon - i > 10) {
      out += text[i];
      continue;
    }
    const std::string body = text.substr(i + 1, semicolon - i - 1);
    if (body.empty()) {
      out += text[i];
      continue;
    }

    if (body[0] == '#') {
      // Numeric reference, decimal or hex.
      const bool hex = body.size() > 1 && (body[1] == 'x' || body[1] == 'X');
      const std::string digits = body.substr(hex ? 2 : 1);
      if (digits.empty() ||
          digits.find_first_not_of("0123456789abcdefABCDEF") != std::string::npos) {
        out += text[i];
        continue;
      }
      const long code = std::strtol(digits.c_str(), nullptr, hex ? 16 : 10);
      // Encode as UTF-8 so non-ASCII references survive.
      if (code < 0x80) {
        out += static_cast<char>(code);
      } else if (code < 0x800) {
        out += static_cast<char>(0xC0 | (code >> 6));
        out += static_cast<char>(0x80 | (code & 0x3F));
      } else if (code < 0x10000) {
        out += static_cast<char>(0xE0 | (code >> 12));
        out += static_cast<char>(0x80 | ((code >> 6) & 0x3F));
        out += static_cast<char>(0x80 | (code & 0x3F));
      } else {
        out += static_cast<char>(0xF0 | (code >> 18));
        out += static_cast<char>(0x80 | ((code >> 12) & 0x3F));
        out += static_cast<char>(0x80 | ((code >> 6) & 0x3F));
        out += static_cast<char>(0x80 | (code & 0x3F));
      }
      i = semicolon;
      continue;
    }

    const auto found = named.find(to_lower(body));
    if (found != named.end()) {
      out += found->second;
      i = semicolon;
    } else {
      out += text[i];
    }
  }
  return out;
}

/// True when `text[at]` begins a well-formed character reference.
///
/// Recognises `&name;`, `&#123;` and `&#x1F600;`. Deliberately structural
/// rather than a table of known names: mail is full of entities nobody keeps a
/// list of — `&zwnj;`, `&shy;`, `&#8199;` — and a table only ever mangles the
/// ones it has not heard of.
bool begins_entity(const std::string& text, size_t at) {
  const size_t n = text.size();
  size_t i = at + 1;  // past '&'
  if (i >= n) return false;

  if (text[i] == '#') {
    ++i;
    if (i < n && (text[i] == 'x' || text[i] == 'X')) {
      ++i;
      const size_t start = i;
      while (i < n && std::isxdigit(static_cast<unsigned char>(text[i]))) ++i;
      return i > start && i < n && text[i] == ';';
    }
    const size_t start = i;
    while (i < n && std::isdigit(static_cast<unsigned char>(text[i]))) ++i;
    return i > start && i < n && text[i] == ';';
  }

  const size_t start = i;
  while (i < n && std::isalnum(static_cast<unsigned char>(text[i]))) ++i;
  // 31 is longer than the longest real entity name; anything past it is prose
  // that happens to contain an ampersand.
  return i > start && i - start <= 31 && i < n && text[i] == ';';
}

std::string escape_text(const std::string& text) {
  std::string out;
  out.reserve(text.size());
  for (size_t i = 0; i < text.size(); ++i) {
    const char c = text[i];
    switch (c) {
      case '<': out += "&lt;"; break;
      case '>': out += "&gt;"; break;
      case '"': out += "&quot;"; break;
      case '\'': out += "&#39;"; break;
      case '&':
        // An ampersand that already begins an entity is left ALONE. Escaping
        // it produced `&amp;#847;`, which renders as the literal text
        // "&#847;" — and marketing mail pads its preheader with hundreds of
        // those, so a real message opened with a paragraph of visible entity
        // codes.
        out += begins_entity(text, i) ? "&" : "&amp;";
        break;
      default: out += c;
    }
  }
  return out;
}

bool is_safe_url(const std::string& url) {
  const std::string normalised = normalise_scheme_prefix(url);

  const size_t colon = normalised.find(':');
  if (colon == std::string::npos) {
    return true;  // relative URL, no scheme to abuse
  }
  // A '/' or '?' before the colon means it is a path, not a scheme.
  const size_t slash = normalised.find('/');
  const size_t question = normalised.find('?');
  if ((slash != std::string::npos && slash < colon) ||
      (question != std::string::npos && question < colon)) {
    return true;
  }

  const std::string scheme = normalised.substr(0, colon);
  return scheme == "http" || scheme == "https" || scheme == "mailto" ||
         scheme == "cid";
}

namespace {
// MARK: - Inline style

/// CSS properties kept.
///
/// An allowlist, for the same reason the tag list is one: a blocklist of
/// dangerous properties fails open on every property nobody thought of.
///
/// What is missing is as deliberate as what is here. `position`, `top`,
/// `left`, `z-index` and `transform` are absent because they let a message
/// draw on top of the surrounding interface — the mechanism behind a message
/// that renders fake app chrome asking for a password. `content` is absent
/// because it injects text that is not in the document. `cursor`, `animation`
/// and `transition` are absent because they buy nothing in mail.
bool style_property_allowed(std::string_view name) {
  static const std::unordered_set<std::string> allowed = {
      // Colour and type
      "color", "background", "background-color", "background-image",
      "background-position", "background-repeat", "background-size",
      "font", "font-family", "font-size", "font-style", "font-weight",
      "font-variant", "line-height", "letter-spacing", "word-spacing",
      "text-align", "text-decoration", "text-indent", "text-transform",
      "text-overflow", "vertical-align", "white-space", "word-break",
      "overflow-wrap", "word-wrap", "direction", "opacity",
      // Box
      "margin", "margin-top", "margin-right", "margin-bottom", "margin-left",
      "padding", "padding-top", "padding-right", "padding-bottom",
      "padding-left",
      "border", "border-top", "border-right", "border-bottom", "border-left",
      "border-color", "border-style", "border-width", "border-radius",
      "border-collapse", "border-spacing",
      "width", "height", "max-width", "max-height", "min-width", "min-height",
      "box-sizing", "display", "float", "clear", "table-layout",
      "list-style", "list-style-type", "list-style-position",
  };
  std::string key = to_lower(name);
  return allowed.count(key) != 0;
}

/// True when a declaration value carries something executable or fetchable
/// that the property allowlist alone would not catch.
bool style_value_is_dangerous(const std::string& value) {
  const std::string lowered = to_lower(value);
  // `expression()` executes in legacy engines. `behavior` and `-moz-binding`
  // attach code. `@import` pulls in a stylesheet wholesale. A backslash is a
  // CSS escape, which is the standard way to spell any of the above past a
  // naive filter — there is no legitimate use of one in mail, so it is
  // rejected outright rather than decoded and re-checked.
  //
  // `var(` is here because a custom property splits a payload across two
  // declarations that are each innocent on their own: `--u:javascript:alert(1)`
  // is refused by the property allowlist and vanishes, but `background:
  // url(var(--u))` names no scheme at all and would sail through every check
  // in this file. Refusing the reference is what makes that pair unusable —
  // and nothing in mail needs custom properties, which the allowlist already
  // excludes by never naming one.
  for (const char* marker : {"expression", "javascript:", "vbscript:",
                             "behavior", "binding", "@import", "var(", "\\"}) {
    if (lowered.find(marker) != std::string::npos) return true;
  }
  return false;
}

/// Whether a URL may be used as an IMAGE source.
///
/// Everything `is_safe_url` permits, plus `data:` restricted to raster image
/// types. Inlined base64 images are ordinary in mail — 979 of them in a real
/// mailbox had no source at all because `data:` was refused outright — and a
/// raster payload is decoded by the image decoder, not interpreted.
///
/// `image/svg+xml` is deliberately excluded despite being an image type. SVG
/// is a document format: it carries `<script>`, event handlers and external
/// references, and a data: SVG is the standard way to smuggle all three past a
/// filter that checked only for the word "image".
///
/// Kept separate from `is_safe_url` so that `href` is unaffected. A link to a
/// data: URL is a navigation, and navigations stay restricted to real schemes.
bool is_safe_image_url(const std::string& url) {
  if (normalise_scheme_prefix(url) != "data:") return is_safe_url(url);

  // `normalise_scheme_prefix` stops at the colon, so the media type has to be
  // normalised separately — with the same disregard for whitespace and control
  // characters that a URL parser has, or `data:image/\tpng` walks straight
  // through a naive comparison.
  std::string head;
  for (size_t i = 0; i < url.size() && head.size() < 40; ++i) {
    const char c = url[i];
    if (is_space(c) || static_cast<unsigned char>(c) < 0x20) continue;
    head += lower(c);
  }

  static const std::string_view allowed[] = {
      "data:image/png", "data:image/jpeg", "data:image/jpg",
      "data:image/gif", "data:image/webp", "data:image/bmp",
  };
  for (const auto& prefix : allowed) {
    if (head.size() < prefix.size()) continue;
    if (head.compare(0, prefix.size(), prefix) != 0) continue;
    // The type must END here, so `data:image/pngx` and `data:image/png+xml`
    // cannot ride in on a prefix match.
    const char next = head.size() > prefix.size() ? head[prefix.size()] : ';';
    if (next == ';' || next == ',') return true;
  }
  return false;
}

/// Validates every `url(...)` in a declaration value.
///
/// Hero images in mail are CSS backgrounds, so `url()` cannot simply be
/// banned. The SCHEME is checked here; whether the fetch is permitted at all
/// is the render-time CSP's decision, which is what keeps the remote-image
/// preference working on already-stored messages.
/// The payload of one `url(...)`, with its whitespace and quotes removed.
std::string url_payload(std::string_view raw) {
  std::string url = trimmed(raw);
  if (url.size() >= 2 && (url.front() == '"' || url.front() == '\'') &&
      url.back() == url.front()) {
    url = trimmed(std::string_view(url).substr(1, url.size() - 2));
  }
  return url;
}

/// Every `url(...)` payload in a declaration value.
///
/// Returns false when one is unterminated: an unclosed `url(` runs to the end
/// of the value with no way to tell where the URL stopped, so no check made
/// against it means anything.
bool collect_urls(const std::string& value, std::vector<std::string>& urls) {
  const std::string lowered = to_lower(value);
  size_t at = 0;
  while ((at = lowered.find("url(", at)) != std::string::npos) {
    const size_t start = at + 4;
    const size_t end = lowered.find(')', start);
    if (end == std::string::npos) return false;
    urls.push_back(url_payload(std::string_view(value).substr(start, end - start)));
    at = end + 1;
  }
  return true;
}

bool style_urls_are_safe(const std::string& value) {
  std::vector<std::string> urls;
  if (!collect_urls(value, urls)) return false;
  for (const auto& url : urls) {
    if (!is_safe_image_url(url)) return false;
  }
  return true;
}

/// Neutralises every remote `url(...)` in a declaration value.
///
/// A `background-image` pointing at a sender's server is the same tracking
/// pixel an `<img src>` is, reaching the same log line, and until now it
/// walked past the images preference entirely because that preference only
/// ever looked at `<img>`.
///
/// The URL is KEPT, behind a scheme no engine can resolve, for the same reason
/// `<img>` keeps it in `data-blocked-src`: the stored body stays a complete
/// record, so turning images on is a re-sanitise rather than a re-fetch from
/// Gmail. A URL that could not be written back inside quotes intact — one
/// carrying a quote, a bracket or whitespace — is not rewritten at all; the
/// caller drops that declaration instead.
bool block_remote_urls(std::string& value, int& blocked) {
  const std::string lowered = to_lower(value);
  std::string out;
  size_t at = 0;
  size_t copied = 0;
  while ((at = lowered.find("url(", at)) != std::string::npos) {
    const size_t start = at + 4;
    const size_t end = lowered.find(')', start);
    if (end == std::string::npos) return false;
    const std::string url = url_payload(std::string_view(value).substr(start, end - start));
    if (normalise_scheme_prefix(url).rfind("http", 0) == 0) {
      if (url.find_first_of("\"'()<>&{};\\ \t\r\n") != std::string::npos) return false;
      out += value.substr(copied, start - copied);
      out += "\"blocked-remote:" + url + "\"";
      copied = end;
      ++blocked;
    }
    at = end + 1;
  }
  if (copied == 0) return true;
  out += value.substr(copied);
  value = out;
  return true;
}

/// Filters a declaration list down to its safe declarations.
///
/// Returns an empty string when nothing survives, so the caller can omit the
/// attribute rather than emit `style=""`.
///
/// `blocked_remote_images` is the images preference: pass a counter to have
/// remote `url()` fetches defused and tallied, or nullptr to leave them live.
///
/// The stylesheet passes a counter, the `style` attribute passes nullptr, and
/// the difference is about where the decision can still be made later. An
/// attribute belongs to one element that the reading pane holds a handle on,
/// which is what `data-blocked-src` and the render-time CSP act through; a
/// rule in a stylesheet belongs to no element until it matches one, so there
/// is nothing to revisit and blocking has to happen as the CSS is written or
/// not at all.
std::string sanitize_style(const std::string& value, bool& removed_active,
                           int* blocked_remote_images = nullptr) {
  std::string out;

  size_t i = 0;
  while (i < value.size()) {
    // Find the separator at paren depth zero. A plain `find(';')` cut inside
    // `url(data:image/png;base64,...)`, which left `base64,...)` as a junk
    // declaration and silently dropped the background it belonged to.
    size_t end = std::string::npos;
    int depth = 0;
    for (size_t scan = i; scan < value.size(); ++scan) {
      const char c = value[scan];
      if (c == '(') ++depth;
      else if (c == ')') { if (depth > 0) --depth; }
      else if (c == ';' && depth == 0) { end = scan; break; }
    }
    const std::string declaration =
        value.substr(i, end == std::string::npos ? std::string::npos : end - i);
    i = end == std::string::npos ? value.size() : end + 1;

    const size_t colon = declaration.find(':');
    if (colon == std::string::npos) continue;

    std::string name = declaration.substr(0, colon);
    std::string property_value = declaration.substr(colon + 1);
    const auto trim = [](std::string& text) {
      while (!text.empty() && std::isspace(static_cast<unsigned char>(text.front()))) {
        text.erase(text.begin());
      }
      while (!text.empty() && std::isspace(static_cast<unsigned char>(text.back()))) {
        text.pop_back();
      }
    };
    trim(name);
    trim(property_value);
    if (name.empty() || property_value.empty()) continue;

    if (style_value_is_dangerous(property_value) || style_value_is_dangerous(name)) {
      removed_active = true;
      continue;
    }
    if (!style_property_allowed(name)) continue;
    if (!style_urls_are_safe(property_value)) {
      removed_active = true;
      continue;
    }
    if (blocked_remote_images != nullptr &&
        !block_remote_urls(property_value, *blocked_remote_images)) {
      continue;
    }

    if (!out.empty()) out += ";";
    out += to_lower(name) + ":" + property_value;
  }

  return out;
}

// MARK: - Stylesheet
//
// The <style> block used to go in `void_content_tags`, discarded whole. That
// was not a small loss: all 14 messages sampled from the Gmail API carried one
// and addressed it by class, and 13 used @media or a show/hide class. Without
// the stylesheet a three-across product grid rendered one item per row, and
// `.mobile-hide` / `.showdesktop` stopped hiding anything, so the desktop and
// mobile copies of the same button drew on top of each other.
//
// So the block is kept, and every declaration in it goes through
// `sanitize_style` — the SAME function the `style` attribute uses. That is the
// point of the design: there is one property allowlist, so the two paths
// cannot drift into disagreeing about what `position` or `expression()` means.
// This layer only decides which rules exist and what their selectors may say.

/// How deeply @media may nest before the rest is dropped.
///
/// Real mail nests zero or one level. The cap is here because the parser
/// recurses, and a few kilobytes of `@media{@media{@media{` is cheap to send
/// and would otherwise walk the stack down.
constexpr int kMaxAtRuleDepth = 4;

/// At-rules whose whole purpose is to fetch something.
///
/// Dropping any of these counts as removing active content, so the reading
/// pane can say so. Other unknown at-rules are dropped just as thoroughly but
/// silently — `@charset` is inert, and flagging it would put a warning on a
/// message where nothing was actually withheld.
bool at_rule_fetches(std::string_view name) {
  return name == "import" || name == "font-face" || name == "namespace";
}

/// The lowercased keyword of an at-rule prelude: `@MEDIA screen` -> `media`.
std::string at_rule_name(std::string_view prelude) {
  std::string name;
  for (size_t i = 1; i < prelude.size(); ++i) {
    if (std::isalnum(static_cast<unsigned char>(prelude[i])) == 0 &&
        prelude[i] != '-') {
      break;
    }
    name += lower(prelude[i]);
  }
  return name;
}

/// Removes `/* ... */`, closing the gap where each comment was.
///
/// Run before parsing, so that a comment cannot hide a brace and desynchronise
/// the rule scanner: `.a{color:red /* } */ }` has to end where CSS says it
/// ends, not at the brace inside the comment.
///
/// The two halves are JOINED rather than separated by a space, which is not
/// what a CSS parser does — to a browser `col/*x*/or` is two identifiers, not
/// `color`. Joining is the fail-closed reading. `@im/**/port`, `expr/**/ession`
/// and `url(java/**/script:...)` are comments inserted for no reason except to
/// break a substring check, and every one of them becomes visible once the
/// halves are joined. The cost is that a declaration a browser would have
/// ignored is occasionally dropped instead, which is the direction to be wrong
/// in.
///
/// An unterminated comment swallows the rest of the stylesheet, as it does in
/// a browser. The scan resumes past the matched `*/` rather than at the next
/// byte, so 20,000 unmatched `/*` cost one pass, not 20,000.
std::string strip_css_comments(const std::string& css) {
  std::string out;
  out.reserve(css.size());
  size_t i = 0;
  while (i < css.size()) {
    if (css[i] == '/' && i + 1 < css.size() && css[i + 1] == '*') {
      const size_t end = css.find("*/", i + 2);
      if (end == std::string::npos) break;
      i = end + 2;
      continue;
    }
    out += css[i];
    ++i;
  }
  return out;
}

/// Characters a selector may be built from.
///
/// A selector is attacker-controlled text that ends up inside `<style>`, and
/// `<style>` is a raw-text element: the HTML parser does not decode entities
/// in it and leaves only on `</style`. Escaping is therefore not available as
/// a defence — `&gt;` inside a stylesheet is four literal characters to the
/// CSS parser, not a combinator — so safety has to come from refusing
/// characters outright, and a selector holding anything not listed here takes
/// its whole rule down with it.
///
/// `<` is the load-bearing exclusion: with no `<`, no `</style` can be
/// spelled and the element cannot be closed early. `&` goes with it because it
/// means nothing in CSS and is only ever there to smuggle something past a
/// reader. `>` is excluded too, even though it is the legitimate child
/// combinator: it is a markup delimiter, and mail that depends on `.a > .b`
/// is rare enough that dropping those rules costs less than keeping a second
/// angle bracket in play. Descendant and compound selectors, which is what
/// mail actually ships, are unaffected.
bool selector_char_allowed(char c) {
  if (std::isalnum(static_cast<unsigned char>(c)) != 0) return true;
  switch (c) {
    // Type, class, id, universal, grouping, and every combinator.
    //
    // `>` is here on purpose. `<` is what ends a raw-text element, and it stays
    // refused; a lone `>` cannot close `<style>` and carries no other risk. It
    // was excluded on a first pass, which silently dropped every child-combinator
    // rule — 3 of 43 in a real Rainier Arms stylesheet, all list indentation.
    // Cheap here, but the same reasoning would have dropped a layout rule.
    case ' ': case '\t': case '\n': case '\r': case '\f':
    case '-': case '_': case '.': case '#': case '*': case ',':
    case '+': case '~': case '>':
    // Pseudo-classes and attribute selectors: `:nth-child(2n+1)` and
    // `[class~="mobile"]` both appear in real mail.
    case ':': case '(': case ')': case '[': case ']': case '=':
    case '"': case '\'':
      return true;
    default:
      return false;
  }
}

/// True when every `"` and `'` in `text` is closed again.
///
/// A rule body is delimited by counting braces, and a brace inside a quoted
/// string is invisible to that count — `font-family:"a}b{position:fixed"` ends
/// the rule at the brace inside the string and leaves the emitted CSS holding
/// an unterminated quote. A CSS parser then swallows whatever follows into
/// that string, which silently eats the next sender's rules and makes the
/// output depend on text this filter thought it had dropped. Nothing legible
/// is lost by refusing it: real CSS closes its strings.
///
/// No escape handling, because a backslash never survives this far —
/// `style_value_is_dangerous` rejects the value and `selector_char_allowed`
/// rejects the selector.
bool quotes_are_balanced(std::string_view text) {
  char open = '\0';
  for (const char c : text) {
    if (open == '\0') {
      if (c == '"' || c == '\'') open = c;
    } else if (c == open) {
      open = '\0';
    }
  }
  return open == '\0';
}

bool selector_is_safe(std::string_view selector) {
  if (selector.empty()) return false;
  for (const char c : selector) {
    if (!selector_char_allowed(c)) return false;
  }
  return quotes_are_balanced(selector);
}

/// Characters an `@media` condition may be built from.
///
/// Same reasoning as the selector set, minus the parts of selector syntax that
/// mean nothing in a media query. `/` is here for ratio values such as
/// `(min-aspect-ratio:16/9)`.
bool media_condition_is_safe(std::string_view condition) {
  if (condition.empty()) return false;
  for (const char c : condition) {
    if (std::isalnum(static_cast<unsigned char>(c)) != 0) continue;
    switch (c) {
      case ' ': case '\t': case '\n': case '\r': case '\f':
      case '-': case '_': case ':': case '(': case ')': case ',':
      case '.': case '/':
        continue;
      default:
        return false;
    }
  }
  return true;
}

/// Last check before a rule's declarations are written into the stylesheet.
///
/// `sanitize_style` vets each declaration's property and value, but it was
/// written for an attribute, where the caller escapes the result and a stray
/// brace is inert. Inside a `<style>` block neither holds, and two kinds of
/// character it has no reason to reject become escapes:
///
///   - `}` ends the rule early, and everything after it is read as a NEW rule
///     that no allowlist ever saw. `color:red} body{position:fixed` would have
///     laid a fixed overlay across the interface using the exact property the
///     filter exists to refuse. `{` is refused with it, symmetrically.
///   - `<` spells `</style` and closes the element, putting the remainder of
///     the value into the document as markup. `&` and `>` go with it so that
///     no markup delimiter reaches the output at all.
///
/// `\` is refused here as well as in `style_value_is_dangerous`, so that what
/// may reach the stylesheet is stated in one place and does not depend on a
/// check made three functions away staying where it is.
///
/// Refusing the whole rule rather than the one declaration is deliberate: a
/// declaration doing this is not a formatting accident, and the rest of the
/// rule is not worth the argument.
bool declarations_are_emittable(std::string_view declarations) {
  if (declarations.find_first_of("<>&{}\\") != std::string_view::npos) return false;
  return quotes_are_balanced(declarations);
}

/// Filters a stylesheet down to the rules that are safe to keep.
///
/// Anything it cannot parse confidently is dropped rather than passed through:
/// there is no path here that emits unrecognised text, because unrecognised
/// text inside `<style>` is exactly the payload this is meant to stop.
std::string sanitize_stylesheet(const std::string& css, bool& removed_active,
                                int* blocked_remote_images, int depth) {
  std::string out;
  const size_t n = css.size();
  size_t i = 0;

  while (i < n) {
    while (i < n && is_space(css[i])) ++i;
    if (i >= n) break;
    // A '}' with nothing open is the tail of a rule that was already consumed
    // or never started. Skipping it stops it being read as a selector.
    if (css[i] == '}') {
      ++i;
      continue;
    }

    size_t scan = i;
    while (scan < n && css[scan] != '{' && css[scan] != ';' && css[scan] != '}') {
      ++scan;
    }
    const std::string prelude = trimmed(std::string_view(css).substr(i, scan - i));
    const bool is_at_rule = !prelude.empty() && prelude.front() == '@';

    // A prelude with no block at all: either a statement at-rule terminated by
    // ';' — `@import url(evil.css);`, which is precisely what must not survive
    // — or junk. Either way there is nothing to keep.
    if (scan < n && css[scan] != '{') {
      if (is_at_rule && at_rule_fetches(at_rule_name(prelude))) {
        removed_active = true;
      }
      i = scan + 1;
      continue;
    }
    // Ran off the end without finding a block. The tail is truncated CSS, and
    // truncated CSS is dropped — emitting it would put unparsed sender text
    // straight into the page.
    if (scan >= n) break;

    const size_t body_start = scan + 1;
    size_t body_end = body_start;
    int nesting = 1;
    while (body_end < n) {
      if (css[body_end] == '{') {
        ++nesting;
      } else if (css[body_end] == '}') {
        --nesting;
        if (nesting == 0) break;
      }
      ++body_end;
    }
    // An unterminated block takes the rest of the stylesheet with it, for the
    // same reason: whatever follows was never delimited, so it cannot be read.
    if (nesting != 0) break;
    const std::string body = css.substr(body_start, body_end - body_start);
    i = body_end + 1;

    if (is_at_rule) {
      const std::string name = at_rule_name(prelude);
      // @media is the only at-rule with a block that is kept. Everything else
      // is dropped by default, which is the same allowlist argument the tag
      // and property sets make: the at-rule grammar is open-ended, and a
      // blocklist would admit whatever gets standardised next.
      if (name != "media" || depth >= kMaxAtRuleDepth) {
        if (at_rule_fetches(name)) removed_active = true;
        continue;
      }
      const std::string condition =
          trimmed(std::string_view(prelude).substr(1 + name.size()));
      if (!media_condition_is_safe(condition)) continue;
      const std::string inner =
          sanitize_stylesheet(body, removed_active, blocked_remote_images, depth + 1);
      if (inner.empty()) continue;
      out += "@media " + condition + "{" + inner + "}";
      continue;
    }

    if (!selector_is_safe(prelude)) continue;
    const std::string declarations =
        sanitize_style(body, removed_active, blocked_remote_images);
    if (declarations.empty()) continue;
    if (!declarations_are_emittable(declarations)) {
      removed_active = true;
      continue;
    }
    out += prelude + "{" + declarations + "}";
  }

  return out;
}

}  // namespace

SanitizeResult sanitize(const std::string& input, const SanitizeOptions& options) {
  SanitizeResult result;
  std::string& out = result.html;
  out.reserve(input.size());

  size_t i = 0;
  const size_t n = input.size();

  while (i < n) {
    if (input[i] != '<') {
      // Text. Accumulate to the next tag, then DECODE any entities before
      // re-escaping.
      //
      // Escaped, but NOT decoded first. Decoding used to run here to avoid
      // double-encoding, but `unescape_entities` knows only a handful of
      // names — everything else survived decoding untouched and was then
      // escaped, so `&#847;` became `&amp;#847;` and rendered as visible text.
      //
      // `escape_text` now leaves any well-formed entity alone, which handles
      // every entity rather than fourteen of them, and still guarantees that
      // nothing here can be read as markup.
      const size_t start = i;
      while (i < n && input[i] != '<') ++i;
      out += escape_text(collapse_padding_in_text(input.substr(start, i - start)));
      continue;
    }

    // Comment or doctype/CDATA: drop entirely.
    if (input.compare(i, 4, "<!--") == 0) {
      const size_t end = input.find("-->", i + 4);
      i = end == std::string::npos ? n : end + 3;
      continue;
    }
    if (i + 1 < n && input[i + 1] == '!') {
      const size_t end = input.find('>', i);
      i = end == std::string::npos ? n : end + 1;
      continue;
    }

    const bool closing = i + 1 < n && input[i + 1] == '/';
    size_t cursor = i + (closing ? 2 : 1);

    // Read the tag name.
    const size_t name_start = cursor;
    while (cursor < n && (std::isalnum(static_cast<unsigned char>(input[cursor])) != 0 ||
                          input[cursor] == '-')) {
      ++cursor;
    }
    const std::string tag = to_lower(input.substr(name_start, cursor - name_start));

    if (tag.empty()) {
      // A bare '<' that begins no tag. Escape it rather than passing it on.
      out += "&lt;";
      ++i;
      continue;
    }

    if (void_content_tags().count(tag) != 0) {
      result.removed_active_content = true;
      if (closing) {
        const size_t end = input.find('>', cursor);
        i = end == std::string::npos ? n : end + 1;
        continue;
      }
      // Skip the element AND everything inside it up to its closing tag.
      const std::string close = "</" + tag;
      size_t search = cursor;
      size_t end = std::string::npos;
      while (search < n) {
        const size_t candidate = input.find("</", search);
        if (candidate == std::string::npos) break;
        if (to_lower(input.substr(candidate, close.size())) == close) {
          end = input.find('>', candidate);
          break;
        }
        search = candidate + 2;
      }
      // An unterminated one takes the rest of the document with it, on
      // purpose. Skipping just the tag would spill its contents into the page
      // as visible text — `<script>alert(1)` with no closing tag would render
      // the word `alert(1)` in the middle of the message. Content-bearing
      // tags here are executable or fetched material, so failing closed is the
      // right trade. Void elements never reach this branch; that was the bug.
      i = end == std::string::npos ? n : end + 1;
      continue;
    }

    // Void elements that are dropped outright. They enclose nothing, so only
    // the tag itself is skipped.
    if (is_dropped_void_tag(tag)) {
      result.removed_active_content = true;
      const size_t tag_close = input.find('>', cursor);
      i = tag_close == std::string::npos ? n : tag_close + 1;
      continue;
    }

    // Parse attributes up to '>' regardless of whether we keep the tag, so the
    // cursor always lands past the whole tag.
    struct Attribute {
      std::string name;
      std::string value;
    };
    std::vector<Attribute> attributes;

    while (cursor < n && input[cursor] != '>') {
      while (cursor < n && (is_space(input[cursor]) || input[cursor] == '/')) ++cursor;
      if (cursor >= n || input[cursor] == '>') break;

      const size_t attr_start = cursor;
      while (cursor < n && !is_space(input[cursor]) && input[cursor] != '=' &&
             input[cursor] != '>') {
        ++cursor;
      }
      const std::string name = to_lower(input.substr(attr_start, cursor - attr_start));

      std::string value;
      while (cursor < n && is_space(input[cursor])) ++cursor;
      if (cursor < n && input[cursor] == '=') {
        ++cursor;
        while (cursor < n && is_space(input[cursor])) ++cursor;
        if (cursor < n && (input[cursor] == '"' || input[cursor] == '\'')) {
          const char quote = input[cursor++];
          const size_t value_start = cursor;
          while (cursor < n && input[cursor] != quote) ++cursor;
          value = input.substr(value_start, cursor - value_start);
          if (cursor < n) ++cursor;
        } else {
          const size_t value_start = cursor;
          while (cursor < n && !is_space(input[cursor]) && input[cursor] != '>') ++cursor;
          value = input.substr(value_start, cursor - value_start);
        }
      }

      if (!name.empty()) attributes.push_back({name, value});
    }
    const size_t tag_end = cursor < n ? cursor + 1 : n;

    if (allowed_tags().count(tag) == 0) {
      // Unknown tag: drop the tag but keep going, so its text survives.
      i = tag_end;
      continue;
    }

    if (tag == "style") {
      // Handled here rather than by the generic path because the contents are
      // CSS, not markup. Running the tokenizer over them would escape every
      // `>` in a selector and read `{` as text; running the CSS parser over
      // them is the whole point of keeping the element.
      if (closing) {
        // A `</style>` with no opener. The opening branch below consumes its
        // own closing tag, so anything reaching here is unbalanced and would
        // emit a stray close into the output.
        i = tag_end;
        continue;
      }

      // Find the end of the raw-text span the same way an HTML parser does:
      // `</style` followed by whitespace, `/` or `>`. `</styles>` does not
      // close it, and neither does a `</style` that a sender wrapped in a CSS
      // comment — that one closes it for a browser too, so it closes it here.
      size_t search = tag_end;
      size_t css_end = std::string::npos;
      while (search < n) {
        const size_t candidate = input.find("</", search);
        if (candidate == std::string::npos) break;
        if (to_lower(input.substr(candidate, 7)) == "</style") {
          const char after = candidate + 7 < n ? input[candidate + 7] : '>';
          if (is_space(after) || after == '>' || after == '/') {
            css_end = candidate;
            break;
          }
        }
        search = candidate + 2;
      }

      const std::string raw = input.substr(
          tag_end, css_end == std::string::npos ? std::string::npos : css_end - tag_end);
      if (css_end == std::string::npos) {
        // Unterminated. The remainder of the document is the stylesheet, which
        // is how a browser reads it, and is safe here in a way it is not for
        // `<script>`: every byte still has to survive the rule parser and the
        // property allowlist, so the worst case is that it all falls out.
        i = n;
      } else {
        const size_t close_end = input.find('>', css_end);
        i = close_end == std::string::npos ? n : close_end + 1;
      }

      // Decoded, then decommented, then parsed. Decoding first for the same
      // reason the `style` attribute does it: `&#39;` ends in a semicolon, so
      // parsing first splits the declaration list INSIDE the entity, and
      // `width:&#101;xpression(...)` does not match "expression" while it is
      // still encoded. A browser does not decode entities inside a raw-text
      // element, so this is stricter than a browser rather than looser — the
      // encoded spelling is refused rather than emitted, which is what matters
      // if it ever reaches a renderer that does decode it.
      const std::string filtered = sanitize_stylesheet(
          strip_css_comments(unescape_entities(raw)), result.removed_active_content,
          options.allow_remote_images ? nullptr : &result.blocked_remote_images, 0);

      // Checked ONE more time, here, on the exact bytes about to be written.
      // Every selector and every declaration above already refuses `<`, but
      // this is the character that ends the element early: `</style><script>`
      // inside a quoted font name or an attribute selector is a script
      // injection that no amount of CSS-level correctness catches, because the
      // browser's raw-text scanner never learns the bytes were inside a
      // string. It cannot be escaped away either — `&lt;` is four literal
      // characters to a CSS parser — so refusing to emit is the only move, and
      // it is cheap enough to do twice.
      //
      // No attributes are carried over. `media` and `type` are the only ones a
      // sender sends and neither survives `attribute_allowed`; emitting the
      // bare tag keeps the element from carrying an unvetted value at all.
      if (!filtered.empty() && filtered.find('<') == std::string::npos) {
        out += "<style>" + filtered + "</style>";
      }
      continue;
    }

    if (closing) {
      if (self_closing_tags().count(tag) == 0) {
        out += "</" + tag + ">";
      }
      i = tag_end;
      continue;
    }

    // Emit the opening tag with only allowlisted attributes.
    out += "<" + tag;
    bool image_blocked = false;
    std::string blocked_src;

    for (const auto& attribute : attributes) {
      // Any on* handler is executable content, whatever it is attached to.
      if (attribute.name.rfind("on", 0) == 0) {
        result.removed_active_content = true;
        continue;
      }
      if (!attribute_allowed(tag, attribute.name)) continue;

      if (attribute.name == "href" || attribute.name == "src") {
        const bool is_image_source = (tag == "img" && attribute.name == "src");
        if (is_image_source ? !is_safe_image_url(attribute.value)
                            : !is_safe_url(attribute.value)) {
          result.removed_active_content = true;
          continue;
        }
        // Remote images are tracking pixels. cid: refers to an attachment we
        // already hold, so it leaks nothing.
        if (tag == "img" && attribute.name == "src" && !options.allow_remote_images) {
          const std::string scheme = normalise_scheme_prefix(attribute.value);
          if (scheme.rfind("http", 0) == 0) {
            ++result.blocked_remote_images;
            image_blocked = true;
            // The URL is PRESERVED rather than discarded, so "load images"
            // has something to restore. Dropping it meant the only way to
            // ever see a blocked image was to re-fetch the whole message from
            // Gmail. It is inert here: `data-` attributes are not fetched, and
            // the CSP forbids remote loads regardless.
            blocked_src = attribute.value;
            continue;
          }
        }
      }

      if (attribute.name == "style") {
        // DECODED before parsing, exactly as a browser does it.
        //
        // `&#39;` ends in a semicolon, so parsing the raw attribute split the
        // declaration list inside the entity — a quoted font name lost its
        // stack and every declaration up to the next well-formed one went with
        // it. 17,858 of 32,396 stored bodies carry an entity in a style
        // attribute.
        //
        // It also closes a bypass: `width:&#101;xpression(...)` did not match
        // the "expression" check while encoded, and the browser decodes it
        // before the CSS parser ever sees it. Checking the decoded text is the
        // only order that means anything.
        //
        // Re-escaped on the way out by the caller below, so the attribute is
        // still well-formed markup.
        const std::string filtered = sanitize_style(
            unescape_entities(attribute.value), result.removed_active_content);
        if (filtered.empty()) continue;
        out += " style=\"" + escape_text(filtered) + "\"";
        continue;
      }

      out += " " + attribute.name + "=\"" + escape_text(attribute.value) + "\"";
    }

    if (tag == "a") {
      // Prevents a target window from reaching back through window.opener, and
      // withholds the referrer.
      out += " rel=\"noopener noreferrer\"";
    }
    if (image_blocked) {
      out += " data-blocked=\"remote\"";
      if (!blocked_src.empty()) {
        out += " data-blocked-src=\"" + escape_text(blocked_src) + "\"";
      }
    }

    out += self_closing_tags().count(tag) != 0 ? " />" : ">";
    i = tag_end;
  }

  return result;
}

}  // namespace mailengine::html
