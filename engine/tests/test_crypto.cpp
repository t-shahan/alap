/// @file test_crypto.cpp
/// @brief Tests for the PKCE primitives.
///
/// These matter more than they look. A base64url encoder that emits padding,
/// or uses the standard `+/` alphabet, produces a challenge Google silently
/// rejects — and the failure surfaces as an opaque `invalid_grant` much later
/// in the flow.

#include <gtest/gtest.h>

#include <set>

#include "mailengine/crypto.hpp"

using namespace mailengine;

TEST(Base64Url, EncodesKnownVectors) {
  // RFC 4648 test vectors, minus padding.
  const auto encode = [](std::string s) {
    return crypto::base64url_encode(std::vector<uint8_t>(s.begin(), s.end()));
  };
  EXPECT_EQ(encode(""), "");
  EXPECT_EQ(encode("f"), "Zg");
  EXPECT_EQ(encode("fo"), "Zm8");
  EXPECT_EQ(encode("foo"), "Zm9v");
  EXPECT_EQ(encode("foob"), "Zm9vYg");
  EXPECT_EQ(encode("fooba"), "Zm9vYmE");
  EXPECT_EQ(encode("foobar"), "Zm9vYmFy");
}

TEST(Base64Url, NeverEmitsPaddingOrUnsafeCharacters) {
  // Bytes chosen to produce '+' and '/' under the standard alphabet.
  const std::vector<uint8_t> bytes = {0xFB, 0xFF, 0xBE, 0xFF};
  const std::string encoded = crypto::base64url_encode(bytes);

  EXPECT_EQ(encoded.find('='), std::string::npos) << encoded;
  EXPECT_EQ(encoded.find('+'), std::string::npos) << encoded;
  EXPECT_EQ(encoded.find('/'), std::string::npos) << encoded;
}

TEST(Base64Url, RoundTripsArbitraryBytes) {
  std::vector<uint8_t> bytes;
  for (int i = 0; i < 256; ++i) {
    bytes.push_back(static_cast<uint8_t>(i));
  }
  const std::string encoded = crypto::base64url_encode(bytes);
  const auto decoded = crypto::base64url_decode(encoded);

  ASSERT_TRUE(decoded.has_value()) << decoded.error().message;
  ASSERT_EQ(decoded->size(), bytes.size());
  for (size_t i = 0; i < bytes.size(); ++i) {
    EXPECT_EQ(static_cast<uint8_t>((*decoded)[i]), bytes[i]) << "at index " << i;
  }
}

TEST(Base64Url, DecodesStandardAlphabetToo) {
  // Gmail bodies are base64url, but some headers use standard base64.
  const auto decoded = crypto::base64url_decode("Zm9vYmFy");
  ASSERT_TRUE(decoded.has_value());
  EXPECT_EQ(*decoded, "foobar");
}

TEST(Base64Url, RejectsInvalidCharacters) {
  const auto decoded = crypto::base64url_decode("abc$def");
  EXPECT_FALSE(decoded.has_value());
}

TEST(Sha256, MatchesKnownDigest) {
  // SHA-256("abc"), the canonical NIST vector.
  const auto digest = crypto::sha256("abc");
  ASSERT_EQ(digest.size(), 32u);
  EXPECT_EQ(digest[0], 0xBA);
  EXPECT_EQ(digest[1], 0x78);
  EXPECT_EQ(digest[2], 0x16);
  EXPECT_EQ(digest[31], 0xAD);
}

TEST(Pkce, VerifierMeetsRfc7636LengthRules) {
  const auto verifier = crypto::generate_code_verifier();
  ASSERT_TRUE(verifier.has_value()) << verifier.error().message;

  EXPECT_GE(verifier->size(), 43u);
  EXPECT_LE(verifier->size(), 128u);

  // Every character must be in the unreserved set A-Z a-z 0-9 - . _ ~
  for (const char c : *verifier) {
    const bool unreserved = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
                            (c >= '0' && c <= '9') || c == '-' || c == '.' ||
                            c == '_' || c == '~';
    EXPECT_TRUE(unreserved) << "illegal verifier character: " << c;
  }
}

TEST(Pkce, VerifiersAreUnique) {
  // A predictable verifier defeats PKCE entirely, so assert the generator is
  // not returning a constant or a poorly-seeded sequence.
  std::set<std::string> seen;
  for (int i = 0; i < 50; ++i) {
    auto verifier = crypto::generate_code_verifier();
    ASSERT_TRUE(verifier.has_value());
    seen.insert(*verifier);
  }
  EXPECT_EQ(seen.size(), 50u);
}

TEST(Pkce, ChallengeIsDeterministicAndMatchesRfcExample) {
  // RFC 7636 Appendix B.
  const std::string verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk";
  const std::string challenge = crypto::derive_code_challenge(verifier);

  EXPECT_EQ(challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM");
  EXPECT_EQ(challenge, crypto::derive_code_challenge(verifier));
}

TEST(Random, ProducesRequestedLength) {
  const auto bytes = crypto::random_bytes(16);
  ASSERT_TRUE(bytes.has_value());
  EXPECT_EQ(bytes->size(), 16u);
}
