/// @file crypto.hpp
/// @brief Cryptographic primitives needed for OAuth 2.0 PKCE.

#pragma once

#include <cstdint>
#include <string>
#include <vector>

#include "mailengine/result.hpp"

namespace mailengine::crypto {

/// @brief Fills a buffer with cryptographically secure random bytes.
///
/// Backed by `SecRandomCopyBytes`. Do NOT substitute `std::mt19937` here — a
/// predictable PKCE verifier defeats the entire mechanism, since an attacker
/// who can guess it can exchange an intercepted authorization code.
[[nodiscard]] Result<std::vector<uint8_t>> random_bytes(size_t count);

/// @brief SHA-256 digest of `input`.
[[nodiscard]] std::vector<uint8_t> sha256(const std::string& input);

/// @brief Encodes bytes as base64url without padding (RFC 4648 §5).
///
/// This is the variant OAuth requires: `+` becomes `-`, `/` becomes `_`, and
/// trailing `=` is stripped. Plain base64 will be rejected by Google.
[[nodiscard]] std::string base64url_encode(const std::vector<uint8_t>& bytes);

/// @brief Encodes bytes as STANDARD base64 with padding (RFC 4648 §4).
///
/// Distinct from `base64url_encode`: MIME bodies and RFC 2047 encoded-words use
/// the `+/` alphabet and require `=` padding, while OAuth requires the URL-safe
/// unpadded form. Using the wrong one produces mail that other clients cannot
/// decode.
[[nodiscard]] std::string base64_encode(const std::vector<uint8_t>& bytes);

/// @brief Decodes base64url, tolerating missing padding.
///
/// Also accepts standard base64 (`+` and `/`), because Gmail message bodies
/// arrive base64url-encoded but some headers use the standard alphabet.
[[nodiscard]] Result<std::string> base64url_decode(const std::string& encoded);

/// @brief Generates a PKCE code verifier: 43–128 chars of unreserved ASCII.
///
/// Produced by base64url-encoding 32 random bytes, which yields 43 characters.
[[nodiscard]] Result<std::string> generate_code_verifier();

/// @brief Derives the S256 code challenge from a verifier.
///
/// challenge = base64url(SHA256(ASCII(verifier)))
///
/// The verifier is sent only on the final token exchange, over TLS directly to
/// Google. Only the challenge travels through the browser, so intercepting the
/// redirect does not yield anything usable.
[[nodiscard]] std::string derive_code_challenge(const std::string& verifier);

}  // namespace mailengine::crypto
