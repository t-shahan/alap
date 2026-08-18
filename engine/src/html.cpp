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
  };
  return tags;
}

/// Tags whose CONTENTS are discarded along with the tag.
///
/// These carry executable or externally-fetched material rather than text, so
/// preserving what is inside them would defeat the point.
const std::unordered_set<std::string>& void_content_tags() {
  static const std::unordered_set<std::string> tags = {
      "script", "style", "iframe", "object", "embed", "applet", "form",
      "link", "meta", "base", "noscript", "template", "svg", "math", "head",
  };
  return tags;
}

/// Tags that never have a closing partner.
const std::unordered_set<std::string>& self_closing_tags() {
  static const std::unordered_set<std::string> tags = {"br", "hr", "img"};
  return tags;
}

/// Attributes kept, per tag.
///
/// Deliberately tiny. `style` and `class` are excluded on purpose: inline CSS
/// can fetch remote resources, overlay content to spoof the interface, and in
/// some engines execute expressions.
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
  // `class` stays out. Without a stylesheet it does nothing, and the only way
  // to make it do something is to admit <style>, which is a whole CSS surface
  // — selectors, media queries, @import — that this sanitiser does not parse
  // and therefore cannot vouch for.
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
  for (const char* marker : {"expression", "javascript:", "vbscript:",
                             "behavior", "binding", "@import", "\\"}) {
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
bool style_urls_are_safe(const std::string& value) {
  const std::string lowered = to_lower(value);
  size_t at = 0;
  while ((at = lowered.find("url(", at)) != std::string::npos) {
    size_t start = at + 4;
    const size_t end = lowered.find(')', start);
    if (end == std::string::npos) return false;

    std::string url = value.substr(start, end - start);
    // Strip surrounding whitespace and quotes.
    const auto trim = [](std::string& text) {
      while (!text.empty() && std::isspace(static_cast<unsigned char>(text.front()))) {
        text.erase(text.begin());
      }
      while (!text.empty() && std::isspace(static_cast<unsigned char>(text.back()))) {
        text.pop_back();
      }
    };
    trim(url);
    if (url.size() >= 2 && (url.front() == '"' || url.front() == '\'') &&
        url.back() == url.front()) {
      url = url.substr(1, url.size() - 2);
      trim(url);
    }
    if (!is_safe_image_url(url)) return false;
    at = end + 1;
  }
  return true;
}

/// Filters a `style` attribute down to its safe declarations.
///
/// Returns an empty string when nothing survives, so the caller can omit the
/// attribute rather than emit `style=""`.
std::string sanitize_style(const std::string& value, bool& removed_active) {
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

    if (!out.empty()) out += ";";
    out += to_lower(name) + ":" + property_value;
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
      i = end == std::string::npos ? n : end + 1;
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
        const std::string filtered =
            sanitize_style(attribute.value, result.removed_active_content);
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
