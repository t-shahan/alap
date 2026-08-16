/// @file test_mime.cpp
/// @brief Header decoding and address parsing.
///
/// Every case here is drawn from mail that actually exists. Encoded-word and
/// address-list bugs are the most visible failures in a mail client — a
/// mangled subject line is the first thing a user sees.

#include <gtest/gtest.h>

#include "mailengine/mime.hpp"

using namespace mailengine::mime;

// MARK: - RFC 2047 encoded words

TEST(EncodedWords, PassesPlainAsciiThrough) {
  EXPECT_EQ(decode_encoded_words("Design review moved to Thursday"),
            "Design review moved to Thursday");
}

TEST(EncodedWords, DecodesBase64) {
  EXPECT_EQ(decode_encoded_words("=?UTF-8?B?SGVsbG8sIHdvcmxk?="), "Hello, world");
}

TEST(EncodedWords, DecodesQuotedPrintable) {
  // `_` means space inside a Q segment — a rule unique to RFC 2047.
  EXPECT_EQ(decode_encoded_words("=?UTF-8?Q?Hello=2C_world?="), "Hello, world");
}

TEST(EncodedWords, DecodesNonAsciiNames) {
  // "André" in ISO-8859-1 quoted-printable.
  EXPECT_EQ(decode_encoded_words("=?ISO-8859-1?Q?Andr=E9?="), "Andr\xE9");
}

TEST(EncodedWords, DecodesUtf8MultiByte) {
  // "日本語" UTF-8 base64.
  EXPECT_EQ(decode_encoded_words("=?UTF-8?B?5pel5pys6Kqe?="), "日本語");
}

TEST(EncodedWords, PreservesSurroundingLiteralText) {
  EXPECT_EQ(decode_encoded_words("Re: =?UTF-8?B?SGVsbG8=?= (urgent)"),
            "Re: Hello (urgent)");
}

TEST(EncodedWords, DropsWhitespaceBetweenAdjacentWords) {
  // RFC 2047: whitespace separating two encoded-words is not part of the text.
  // Long non-ASCII subjects are split across several words, and keeping the
  // separator inserts spurious spaces mid-word.
  EXPECT_EQ(decode_encoded_words("=?UTF-8?B?SGVsbG8s?= =?UTF-8?B?IHdvcmxk?="),
            "Hello, world");
}

TEST(EncodedWords, KeepsWhitespaceBetweenWordAndLiteral) {
  EXPECT_EQ(decode_encoded_words("=?UTF-8?B?SGVsbG8=?= world"), "Hello world");
}

TEST(EncodedWords, LeavesMalformedTokensIntact) {
  // Better a visibly odd subject than a crash or an empty one.
  EXPECT_EQ(decode_encoded_words("=?UTF-8?B?not-terminated"),
            "=?UTF-8?B?not-terminated");
  EXPECT_EQ(decode_encoded_words("=?=?="), "=?=?=");
}

TEST(EncodedWords, HandlesEmptyInput) {
  EXPECT_EQ(decode_encoded_words(""), "");
}

// MARK: - Quoted printable

TEST(QuotedPrintable, DecodesHexEscapes) {
  EXPECT_EQ(decode_quoted_printable("caf=C3=A9"), "café");
}

TEST(QuotedPrintable, JoinsSoftLineBreaks) {
  // A trailing '=' before a newline means "this line was wrapped", and both
  // the '=' and the break disappear.
  EXPECT_EQ(decode_quoted_printable("long=\r\nline"), "longline");
  EXPECT_EQ(decode_quoted_printable("long=\nline"), "longline");
}

TEST(QuotedPrintable, LeavesUnderscoresAloneInBodies) {
  // Underscore means space ONLY inside RFC 2047 Q segments, never in bodies.
  EXPECT_EQ(decode_quoted_printable("a_b", /*underscores_are_spaces=*/false), "a_b");
  EXPECT_EQ(decode_quoted_printable("a_b", /*underscores_are_spaces=*/true), "a b");
}

TEST(QuotedPrintable, PassesThroughMalformedEscapes) {
  EXPECT_EQ(decode_quoted_printable("100=ZZ"), "100=ZZ");
}

// MARK: - Address parsing

TEST(ParseAddress, HandlesBareAddress) {
  const auto address = parse_address("ada@example.com");
  EXPECT_EQ(address.email, "ada@example.com");
  EXPECT_EQ(address.name, "");
}

TEST(ParseAddress, HandlesNameAndAngleBrackets) {
  const auto address = parse_address("Ada Okonkwo <ada@example.com>");
  EXPECT_EQ(address.name, "Ada Okonkwo");
  EXPECT_EQ(address.email, "ada@example.com");
}

TEST(ParseAddress, StripsQuotesFromDisplayName) {
  const auto address = parse_address("\"Okonkwo, Ada\" <ada@example.com>");
  EXPECT_EQ(address.name, "Okonkwo, Ada");
  EXPECT_EQ(address.email, "ada@example.com");
}

TEST(ParseAddress, DecodesEncodedDisplayName) {
  const auto address = parse_address("=?UTF-8?B?SGVsbG8=?= <hi@example.com>");
  EXPECT_EQ(address.name, "Hello");
  EXPECT_EQ(address.email, "hi@example.com");
}

TEST(ParseAddress, ToleratesEmptyHeader) {
  const auto address = parse_address("");
  EXPECT_EQ(address.email, "");
  EXPECT_EQ(address.name, "");
}

TEST(ParseAddressList, SplitsMultipleAddresses) {
  const auto list = parse_address_list(
      "Ada <ada@example.com>, Marcus <marcus@example.com>");
  ASSERT_EQ(list.size(), 2u);
  EXPECT_EQ(list[0].email, "ada@example.com");
  EXPECT_EQ(list[1].name, "Marcus");
}

TEST(ParseAddressList, DoesNotSplitOnCommaInsideQuotes) {
  // The classic bug: naive comma splitting turns one address into two broken
  // ones whenever a display name is "Last, First".
  const auto list = parse_address_list(
      "\"Okonkwo, Ada\" <ada@example.com>, marcus@example.com");
  ASSERT_EQ(list.size(), 2u);
  EXPECT_EQ(list[0].name, "Okonkwo, Ada");
  EXPECT_EQ(list[0].email, "ada@example.com");
  EXPECT_EQ(list[1].email, "marcus@example.com");
}

TEST(ParseAddressList, HandlesEmptyHeader) {
  EXPECT_TRUE(parse_address_list("").empty());
}

TEST(ParseAddressList, IgnoresTrailingSeparator) {
  const auto list = parse_address_list("a@example.com, ");
  ASSERT_EQ(list.size(), 1u);
  EXPECT_EQ(list[0].email, "a@example.com");
}

// MARK: - Subject normalisation

TEST(StripReplyPrefixes, RemovesSingleAndRepeatedPrefixes) {
  EXPECT_EQ(strip_reply_prefixes("Re: Design review"), "Design review");
  EXPECT_EQ(strip_reply_prefixes("Re: Fwd: Re: Design review"), "Design review");
}

TEST(StripReplyPrefixes, IsCaseInsensitive) {
  EXPECT_EQ(strip_reply_prefixes("RE: Design review"), "Design review");
  EXPECT_EQ(strip_reply_prefixes("fwd: Design review"), "Design review");
}

TEST(StripReplyPrefixes, LeavesUnprefixedSubjectsAlone) {
  EXPECT_EQ(strip_reply_prefixes("Design review"), "Design review");
  // Must not eat a subject that merely starts with those letters.
  EXPECT_EQ(strip_reply_prefixes("Recipe ideas"), "Recipe ideas");
}
