/// @file compose.hpp
/// @brief RFC 5322 message composition.
///
/// The Gmail API does not accept structured fields for sending — it takes a
/// complete, correctly-formed RFC 5322 message, base64url encoded. So sending
/// mail means building one by hand, and the details are unforgiving:
///
///   - lines end CRLF, not LF
///   - headers fold at 78 characters, and folding is whitespace-sensitive
///   - non-ASCII in headers must be RFC 2047 encoded-words; raw UTF-8 in a
///     Subject is rejected or mangled by many receiving servers
///   - a reply threads only if In-Reply-To and References are correct
///
/// Getting the threading headers wrong is the failure that looks fine locally
/// and breaks for the recipient: the reply arrives as a new conversation
/// instead of joining the existing one.

#pragma once

#include <string>
#include <vector>

#include "mailengine/mime.hpp"
#include "mailengine/result.hpp"

namespace mailengine::compose {

/// @brief Everything needed to build one outgoing message.
struct Draft {
  /// The authenticated account's own address.
  mime::Address from;
  std::vector<mime::Address> to;
  std::vector<mime::Address> cc;
  std::string subject;
  /// Plain-text body. HTML composition is not supported.
  std::string body;

  /// RFC 5322 Message-ID of the message being replied to, WITHOUT angle
  /// brackets. Empty for a new message.
  std::string in_reply_to;
  /// The original's References header plus its Message-ID, space separated
  /// and without brackets. Empty for a new message.
  std::vector<std::string> references;
};

/// @brief Builds a complete RFC 5322 message.
///
/// @param message_id_domain Domain for the generated Message-ID. Conventionally
///        the sender's domain, so the id is globally unique and traceable.
[[nodiscard]] Result<std::string> build(const Draft& draft,
                                        const std::string& message_id_domain = "mail.local");

/// @brief Formats one address as `Name <local@domain>`.
///
/// The display name is RFC 2047 encoded when it contains non-ASCII, and quoted
/// when it contains characters that would otherwise need escaping.
[[nodiscard]] std::string format_address(const mime::Address& address);

/// @brief Encodes a header value as an RFC 2047 encoded-word if it needs one.
///
/// Pure ASCII passes through untouched — encoding everything would be valid but
/// makes messages unreadable in the raw and is not what other clients do.
[[nodiscard]] std::string encode_header_value(const std::string& value);

/// @brief Folds a header line to the RFC 5322 limit of 78 characters.
///
/// Folds only at existing whitespace, since inserting a break anywhere else
/// changes the value.
[[nodiscard]] std::string fold_header(const std::string& name, const std::string& value);

/// @brief Formats a timestamp as an RFC 5322 date.
///
/// e.g. `Tue, 16 Aug 2026 13:08:00 +0000`. Always UTC, which avoids depending
/// on the machine's timezone database being correct.
[[nodiscard]] std::string format_date(int64_t epoch_seconds);

/// @brief Generates a globally unique Message-ID, without angle brackets.
[[nodiscard]] Result<std::string> generate_message_id(const std::string& domain);

/// @brief Builds the `Subject` for a reply, adding `Re:` only when absent.
///
/// Repeatedly prefixing produces the "Re: Re: Re:" chains everyone recognises,
/// so an existing prefix is detected case-insensitively and left alone.
[[nodiscard]] std::string reply_subject(const std::string& original);

}  // namespace mailengine::compose
