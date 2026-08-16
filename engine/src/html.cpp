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
      "a", "img", "figure", "figcaption",
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
  if (name == "title" || name == "alt") return true;
  if (tag == "a" && (name == "href")) return true;
  if (tag == "img" && (name == "src" || name == "width" || name == "height")) return true;
  if ((tag == "td" || tag == "th") && (name == "colspan" || name == "rowspan")) {
    return true;
  }
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

}  // namespace

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

std::string escape_text(const std::string& text) {
  std::string out;
  out.reserve(text.size());
  for (const char c : text) {
    switch (c) {
      case '<': out += "&lt;"; break;
      case '>': out += "&gt;"; break;
      case '&': out += "&amp;"; break;
      case '"': out += "&quot;"; break;
      case '\'': out += "&#39;"; break;
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

SanitizeResult sanitize(const std::string& input, const SanitizeOptions& options) {
  SanitizeResult result;
  std::string& out = result.html;
  out.reserve(input.size());

  size_t i = 0;
  const size_t n = input.size();

  while (i < n) {
    if (input[i] != '<') {
      // Text. Accumulate to the next tag and escape it, so anything that is
      // not well-formed markup can only ever become inert text.
      const size_t start = i;
      while (i < n && input[i] != '<') ++i;
      out += escape_text(input.substr(start, i - start));
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

    for (const auto& attribute : attributes) {
      // Any on* handler is executable content, whatever it is attached to.
      if (attribute.name.rfind("on", 0) == 0) {
        result.removed_active_content = true;
        continue;
      }
      if (!attribute_allowed(tag, attribute.name)) continue;

      if (attribute.name == "href" || attribute.name == "src") {
        if (!is_safe_url(attribute.value)) {
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
            continue;
          }
        }
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
    }

    out += self_closing_tags().count(tag) != 0 ? " />" : ">";
    i = tag_end;
  }

  return result;
}

}  // namespace mailengine::html
