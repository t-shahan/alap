/// @file mime.cpp
/// @brief Implementation of header decoding and address parsing.

#include "mailengine/mime.hpp"

#include <algorithm>
#include <cctype>

#include "mailengine/crypto.hpp"

namespace mailengine::mime {
namespace {

/// Case-insensitive comparison for charset and encoding tokens.
bool iequals(std::string_view a, std::string_view b) {
  return a.size() == b.size() &&
         std::equal(a.begin(), a.end(), b.begin(), [](char x, char y) {
           return std::tolower(static_cast<unsigned char>(x)) ==
                  std::tolower(static_cast<unsigned char>(y));
         });
}

std::string trim(const std::string& s) {
  const auto begin = s.find_first_not_of(" \t\r\n");
  if (begin == std::string::npos) return {};
  const auto end = s.find_last_not_of(" \t\r\n");
  return s.substr(begin, end - begin + 1);
}

int hex_value(char c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'A' && c <= 'F') return c - 'A' + 10;
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  return -1;
}

/// One `=?charset?encoding?text?=` token.
struct EncodedWord {
  size_t start = 0;
  size_t length = 0;
  std::string charset;
  char encoding = 'B';
  std::string text;
};

/// Locates the next encoded-word at or after `from`.
bool find_encoded_word(const std::string& value, size_t from, EncodedWord& out) {
  const size_t start = value.find("=?", from);
  if (start == std::string::npos) return false;

  const size_t charset_end = value.find('?', start + 2);
  if (charset_end == std::string::npos) return false;

  const size_t encoding_end = value.find('?', charset_end + 1);
  if (encoding_end == std::string::npos) return false;
  // The encoding is exactly one character: B or Q.
  if (encoding_end != charset_end + 2) return false;

  const size_t finish = value.find("?=", encoding_end + 1);
  if (finish == std::string::npos) return false;

  out.start = start;
  out.length = finish + 2 - start;
  out.charset = value.substr(start + 2, charset_end - start - 2);
  out.encoding = value[charset_end + 1];
  out.text = value.substr(encoding_end + 1, finish - encoding_end - 1);
  return true;
}

}  // namespace

std::string decode_quoted_printable(const std::string& input,
                                    bool underscores_are_spaces) {
  std::string out;
  out.reserve(input.size());

  for (size_t i = 0; i < input.size(); ++i) {
    const char c = input[i];
    if (c == '_' && underscores_are_spaces) {
      out += ' ';
    } else if (c == '=' && i + 1 < input.size()) {
      // A soft line break: "=\r\n" or "=\n" joins wrapped lines and emits
      // nothing.
      if (input[i + 1] == '\n') {
        i += 1;
      } else if (input[i + 1] == '\r' && i + 2 < input.size() && input[i + 2] == '\n') {
        i += 2;
      } else if (i + 2 < input.size()) {
        const int hi = hex_value(input[i + 1]);
        const int lo = hex_value(input[i + 2]);
        if (hi >= 0 && lo >= 0) {
          out += static_cast<char>(hi * 16 + lo);
          i += 2;
        } else {
          out += c;  // malformed escape: pass through
        }
      } else {
        out += c;
      }
    } else {
      out += c;
    }
  }
  return out;
}

std::string decode_encoded_words(const std::string& value) {
  std::string out;
  size_t cursor = 0;
  bool previous_was_encoded = false;

  while (cursor < value.size()) {
    EncodedWord word;
    if (!find_encoded_word(value, cursor, word)) {
      out += value.substr(cursor);
      break;
    }

    // Text between the cursor and this encoded-word is literal. RFC 2047 says
    // whitespace separating two adjacent encoded-words is not part of the
    // text, so drop it when the previous token was also encoded.
    std::string between = value.substr(cursor, word.start - cursor);
    if (previous_was_encoded && trim(between).empty()) {
      between.clear();
    }
    out += between;

    std::string decoded;
    if (word.encoding == 'B' || word.encoding == 'b') {
      auto result = crypto::base64url_decode(word.text);
      decoded = result ? *result : word.text;
    } else if (word.encoding == 'Q' || word.encoding == 'q') {
      decoded = decode_quoted_printable(word.text, /*underscores_are_spaces=*/true);
    } else {
      // Unknown encoding: emit the token untouched rather than losing it.
      decoded = value.substr(word.start, word.length);
    }

    // Charsets other than UTF-8 and ASCII are passed through as bytes. Full
    // transcoding would need ICU; in practice Gmail normalises almost
    // everything to UTF-8 before it reaches us.
    (void)iequals(word.charset, "utf-8");

    out += decoded;
    cursor = word.start + word.length;
    previous_was_encoded = true;
  }

  return out;
}

std::vector<Address> parse_address_list(const std::string& header) {
  std::vector<Address> addresses;
  std::string current;
  bool in_quotes = false;
  bool in_angle = false;

  // Split on commas, but only those outside quoted strings and angle
  // brackets. `"Last, First" <a@b.com>` is ONE address; splitting naively
  // produces two broken ones.
  for (const char c : header) {
    if (c == '"') {
      in_quotes = !in_quotes;
      current += c;
    } else if (c == '<' && !in_quotes) {
      in_angle = true;
      current += c;
    } else if (c == '>' && !in_quotes) {
      in_angle = false;
      current += c;
    } else if (c == ',' && !in_quotes && !in_angle) {
      if (!trim(current).empty()) {
        addresses.push_back(parse_address(current));
      }
      current.clear();
    } else {
      current += c;
    }
  }
  if (!trim(current).empty()) {
    addresses.push_back(parse_address(current));
  }

  return addresses;
}

Address parse_address(const std::string& header) {
  const std::string value = trim(header);
  if (value.empty()) return {};

  Address address;

  const size_t open = value.rfind('<');
  const size_t close = value.rfind('>');
  if (open != std::string::npos && close != std::string::npos && close > open) {
    address.email = trim(value.substr(open + 1, close - open - 1));
    std::string name = trim(value.substr(0, open));
    // Strip surrounding quotes from a quoted display name.
    if (name.size() >= 2 && name.front() == '"' && name.back() == '"') {
      name = name.substr(1, name.size() - 2);
    }
    address.name = decode_encoded_words(name);
  } else {
    // Bare address with no display name.
    address.email = value;
  }

  return address;
}

std::string strip_reply_prefixes(const std::string& subject) {
  std::string value = trim(subject);
  bool stripped = true;

  while (stripped) {
    stripped = false;
    for (const char* prefix : {"re:", "fwd:", "fw:", "aw:", "re :"}) {
      const size_t len = std::string(prefix).size();
      if (value.size() >= len &&
          iequals(std::string_view(value).substr(0, len), prefix)) {
        value = trim(value.substr(len));
        stripped = true;
        break;
      }
    }
  }
  return value;
}

}  // namespace mailengine::mime
