/// @file crypto.cpp
/// @brief PKCE primitives backed by CommonCrypto and Security.framework.

#include "mailengine/crypto.hpp"

#include <CommonCrypto/CommonDigest.h>
#include <Security/SecRandom.h>

#include <array>

namespace mailengine::crypto {
namespace {

constexpr std::string_view kBase64UrlAlphabet =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

/// Maps a base64 character back to its 6-bit value, or 0xFF when invalid.
/// Accepts both the URL-safe and standard alphabets.
constexpr uint8_t decode_char(char c) {
  if (c >= 'A' && c <= 'Z') return static_cast<uint8_t>(c - 'A');
  if (c >= 'a' && c <= 'z') return static_cast<uint8_t>(c - 'a' + 26);
  if (c >= '0' && c <= '9') return static_cast<uint8_t>(c - '0' + 52);
  if (c == '-' || c == '+') return 62;
  if (c == '_' || c == '/') return 63;
  return 0xFF;
}

}  // namespace

Result<std::vector<uint8_t>> random_bytes(size_t count) {
  std::vector<uint8_t> buffer(count);
  if (SecRandomCopyBytes(kSecRandomDefault, count, buffer.data()) != errSecSuccess) {
    return make_error("SecRandomCopyBytes failed");
  }
  return buffer;
}

std::vector<uint8_t> sha256(const std::string& input) {
  std::vector<uint8_t> digest(CC_SHA256_DIGEST_LENGTH);
  CC_SHA256(input.data(), static_cast<CC_LONG>(input.size()), digest.data());
  return digest;
}

std::string base64url_encode(const std::vector<uint8_t>& bytes) {
  std::string out;
  out.reserve((bytes.size() + 2) / 3 * 4);

  size_t i = 0;
  // Consume full 3-byte groups, each producing exactly 4 output characters.
  for (; i + 2 < bytes.size(); i += 3) {
    const uint32_t triple =
        (static_cast<uint32_t>(bytes[i]) << 16) |
        (static_cast<uint32_t>(bytes[i + 1]) << 8) |
        static_cast<uint32_t>(bytes[i + 2]);
    out += kBase64UrlAlphabet[(triple >> 18) & 0x3F];
    out += kBase64UrlAlphabet[(triple >> 12) & 0x3F];
    out += kBase64UrlAlphabet[(triple >> 6) & 0x3F];
    out += kBase64UrlAlphabet[triple & 0x3F];
  }

  // Handle the 1- or 2-byte tail. No '=' padding is emitted: base64url for
  // OAuth is unpadded.
  const size_t remaining = bytes.size() - i;
  if (remaining == 1) {
    const uint32_t triple = static_cast<uint32_t>(bytes[i]) << 16;
    out += kBase64UrlAlphabet[(triple >> 18) & 0x3F];
    out += kBase64UrlAlphabet[(triple >> 12) & 0x3F];
  } else if (remaining == 2) {
    const uint32_t triple = (static_cast<uint32_t>(bytes[i]) << 16) |
                            (static_cast<uint32_t>(bytes[i + 1]) << 8);
    out += kBase64UrlAlphabet[(triple >> 18) & 0x3F];
    out += kBase64UrlAlphabet[(triple >> 12) & 0x3F];
    out += kBase64UrlAlphabet[(triple >> 6) & 0x3F];
  }

  return out;
}

Result<std::string> base64url_decode(const std::string& encoded) {
  std::string out;
  out.reserve(encoded.size() * 3 / 4);

  uint32_t accumulator = 0;
  int bits = 0;

  for (const char c : encoded) {
    if (c == '=' || c == '\n' || c == '\r') {
      continue;  // padding and line breaks are both ignorable
    }
    const uint8_t value = decode_char(c);
    if (value == 0xFF) {
      return make_error(std::string("invalid base64 character: ") + c);
    }
    accumulator = (accumulator << 6) | value;
    bits += 6;
    // Emit a byte every time 8 or more bits have accumulated.
    if (bits >= 8) {
      bits -= 8;
      out += static_cast<char>((accumulator >> bits) & 0xFF);
    }
  }

  return out;
}

Result<std::string> generate_code_verifier() {
  // 32 bytes → 43 base64url characters, the RFC 7636 minimum.
  auto bytes = random_bytes(32);
  if (!bytes) {
    return bytes.error();
  }
  return base64url_encode(*bytes);
}

std::string derive_code_challenge(const std::string& verifier) {
  return base64url_encode(sha256(verifier));
}

}  // namespace mailengine::crypto
