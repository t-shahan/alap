/// @file mime.hpp
/// @brief RFC 2047 header decoding and RFC 5322 address parsing.
///
/// Gmail's API pre-parses the MIME *structure*, but header VALUES arrive
/// exactly as they appeared on the wire. That means non-ASCII subjects and
/// display names are still encoded-words:
///
///     Subject: =?UTF-8?B?SGVsbG8sIHdvcmxk?=
///     From: =?ISO-8859-1?Q?Andr=E9?= <andre@example.com>
///
/// Rendering those raw is the single most visible "this app is broken" bug in
/// an email client, so decoding lives here and is tested hard.

#pragma once

#include <string>
#include <vector>

namespace mailengine::mime {

/// @brief A parsed mail participant.
struct Address {
  /// Display name, already decoded and unquoted. May be empty.
  std::string name;
  std::string email;
};

/// @brief Decodes any RFC 2047 encoded-words within a header value.
///
/// Handles both `B` (base64) and `Q` (quoted-printable) encodings. Text
/// outside encoded-words is passed through unchanged, and undecodable input is
/// returned as-is rather than throwing — a mangled subject beats no message.
///
/// Per RFC 2047, whitespace *between* two adjacent encoded-words is removed,
/// which is how multi-word non-ASCII subjects reassemble correctly.
[[nodiscard]] std::string decode_encoded_words(const std::string& value);

/// @brief Decodes a quoted-printable body or header segment.
/// @param underscores_are_spaces True in RFC 2047 `Q` segments, where `_`
///        means space; false for message bodies.
[[nodiscard]] std::string decode_quoted_printable(const std::string& input,
                                                  bool underscores_are_spaces = false);

/// @brief Parses an address-list header such as `To:` or `Cc:`.
///
/// Handles the forms that actually occur:
///   - `user@example.com`
///   - `Name <user@example.com>`
///   - `"Last, First" <user@example.com>`  (comma inside quotes is not a
///     separator — splitting naively on commas is the classic bug here)
///   - encoded-word display names
[[nodiscard]] std::vector<Address> parse_address_list(const std::string& header);

/// @brief Parses a single address, e.g. the `From:` header.
/// @return The address, or an empty one when nothing parseable is present.
[[nodiscard]] Address parse_address(const std::string& header);

/// @brief Strips leading `Re:`, `Fwd:` and friends for thread-subject display.
[[nodiscard]] std::string strip_reply_prefixes(const std::string& subject);

}  // namespace mailengine::mime
