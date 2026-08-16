/// @file compose.cpp
/// @brief RFC 5322 message construction.

#include "mailengine/compose.hpp"

#include <algorithm>
#include <cctype>
#include <ctime>
#include <sstream>

#include "mailengine/crypto.hpp"

namespace mailengine::compose {
namespace {

/// RFC 5322 recommends lines stay under 78 characters.
constexpr size_t kMaxLineLength = 78;

bool is_ascii(const std::string& value) {
  return std::all_of(value.begin(), value.end(), [](char c) {
    return static_cast<unsigned char>(c) < 0x80;
  });
}

/// True when a display name needs quoting per RFC 5322's `specials`.
bool needs_quoting(const std::string& name) {
  return name.find_first_of("()<>[]:;@\\,.\"") != std::string::npos;
}

std::string join(const std::vector<std::string>& parts, const std::string& sep) {
  std::string out;
  for (const auto& part : parts) {
    if (!out.empty()) out += sep;
    out += part;
  }
  return out;
}

}  // namespace

std::string encode_header_value(const std::string& value) {
  // Pure ASCII is left alone. Encoding unconditionally would be legal but makes
  // the raw message unreadable and is not what other clients do.
  if (is_ascii(value)) {
    return value;
  }
  // Base64 rather than quoted-printable: for text that is mostly non-ASCII, Q
  // encoding expands nearly every byte to three characters.
  const std::vector<uint8_t> bytes(value.begin(), value.end());
  return "=?UTF-8?B?" + crypto::base64_encode(bytes) + "?=";
}

std::string format_address(const mime::Address& address) {
  if (address.name.empty()) {
    return address.email;
  }
  const std::string encoded = encode_header_value(address.name);

  // A quoted string cannot contain an encoded-word — the quotes would become
  // part of the decoded text — so only unencoded names are quoted.
  if (encoded == address.name && needs_quoting(address.name)) {
    std::string escaped;
    for (const char c : address.name) {
      if (c == '"' || c == '\\') escaped += '\\';
      escaped += c;
    }
    return "\"" + escaped + "\" <" + address.email + ">";
  }
  return encoded + " <" + address.email + ">";
}

std::string fold_header(const std::string& name, const std::string& value) {
  std::string line = name + ": ";
  if (line.size() + value.size() <= kMaxLineLength) {
    return line + value;
  }

  std::string out = line;
  size_t column = line.size();
  std::istringstream stream(value);
  std::string word;
  bool first = true;

  while (stream >> word) {
    // Folding is only legal at existing whitespace; a break anywhere else
    // would alter the value.
    if (!first && column + 1 + word.size() > kMaxLineLength) {
      out += "\r\n ";  // continuation lines begin with whitespace
      column = 1;
    } else if (!first) {
      out += ' ';
      column += 1;
    }
    out += word;
    column += word.size();
    first = false;
  }
  return out;
}

std::string format_date(int64_t epoch_seconds) {
  const std::time_t time = static_cast<std::time_t>(epoch_seconds);
  std::tm utc{};
  gmtime_r(&time, &utc);

  // Explicit English day and month names: RFC 5322 requires them, and strftime
  // would emit localised ones under a non-English locale.
  static const char* days[] = {"Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"};
  static const char* months[] = {"Jan", "Feb", "Mar", "Apr", "May", "Jun",
                                 "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"};

  char buffer[64];
  std::snprintf(buffer, sizeof(buffer), "%s, %02d %s %04d %02d:%02d:%02d +0000",
                days[utc.tm_wday], utc.tm_mday, months[utc.tm_mon],
                utc.tm_year + 1900, utc.tm_hour, utc.tm_min, utc.tm_sec);
  return buffer;
}

Result<std::string> generate_message_id(const std::string& domain) {
  auto random = crypto::random_bytes(16);
  if (!random) {
    return random.error();
  }
  return crypto::base64url_encode(*random) + "@" + domain;
}

std::string reply_subject(const std::string& original) {
  const std::string trimmed = original.substr(original.find_first_not_of(" \t") == std::string::npos
                                                  ? 0
                                                  : original.find_first_not_of(" \t"));
  // Detect an existing prefix case-insensitively, otherwise every round trip
  // adds another "Re:".
  if (trimmed.size() >= 3) {
    const std::string head = trimmed.substr(0, 3);
    if ((head[0] == 'R' || head[0] == 'r') && (head[1] == 'E' || head[1] == 'e') &&
        head[2] == ':') {
      return trimmed;
    }
  }
  return "Re: " + trimmed;
}

Result<std::string> build(const Draft& draft, const std::string& message_id_domain) {
  if (draft.from.email.empty()) {
    return make_error("draft has no From address");
  }
  if (draft.to.empty() && draft.cc.empty()) {
    return make_error("draft has no recipients");
  }

  auto message_id = generate_message_id(message_id_domain);
  if (!message_id) {
    return message_id.error();
  }

  std::vector<std::string> to_list;
  for (const auto& address : draft.to) to_list.push_back(format_address(address));
  std::vector<std::string> cc_list;
  for (const auto& address : draft.cc) cc_list.push_back(format_address(address));

  std::string out;
  const auto header = [&out](const std::string& name, const std::string& value) {
    if (value.empty()) return;
    out += fold_header(name, value) + "\r\n";
  };

  header("From", format_address(draft.from));
  header("To", join(to_list, ", "));
  header("Cc", join(cc_list, ", "));
  header("Subject", encode_header_value(draft.subject));
  header("Date", format_date(static_cast<int64_t>(std::time(nullptr))));
  header("Message-ID", "<" + *message_id + ">");

  // Threading. In-Reply-To names the immediate parent; References is the whole
  // ancestry. Clients use one or both, so both are sent — omitting them makes
  // the reply arrive as a brand-new conversation for the recipient even though
  // it looks correct locally.
  if (!draft.in_reply_to.empty()) {
    header("In-Reply-To", "<" + draft.in_reply_to + ">");
  }
  if (!draft.references.empty()) {
    std::vector<std::string> bracketed;
    for (const auto& reference : draft.references) {
      bracketed.push_back("<" + reference + ">");
    }
    header("References", join(bracketed, " "));
  }

  header("MIME-Version", "1.0");
  header("Content-Type", "text/plain; charset=UTF-8");
  // Base64 sidesteps line-length and 8-bit issues entirely. Quoted-printable
  // would be more readable in the raw but needs careful soft-break handling.
  header("Content-Transfer-Encoding", "base64");

  out += "\r\n";  // blank line separates headers from body

  const std::vector<uint8_t> body_bytes(draft.body.begin(), draft.body.end());
  const std::string encoded = crypto::base64_encode(body_bytes);
  // Base64 bodies wrap at 76 characters per RFC 2045.
  for (size_t i = 0; i < encoded.size(); i += 76) {
    out += encoded.substr(i, 76) + "\r\n";
  }

  return out;
}

}  // namespace mailengine::compose
