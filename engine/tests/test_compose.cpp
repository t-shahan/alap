/// @file test_compose.cpp
/// @brief RFC 5322 composition.
///
/// These matter because the failure mode is invisible from the sending side: a
/// message with a mangled Subject or missing threading headers looks correct
/// in our own UI and is broken only for the recipient.

#include <gtest/gtest.h>

#include <string>

#include "mailengine/compose.hpp"
#include "mailengine/crypto.hpp"

using namespace mailengine;
using namespace mailengine::compose;

namespace {

Draft basicDraft() {
  Draft draft;
  draft.from = mime::Address{"Taylor", "me@example.com"};
  draft.to = {mime::Address{"Ada Okonkwo", "ada@example.com"}};
  draft.subject = "Design review";
  draft.body = "Hello there.";
  return draft;
}

bool contains(const std::string& haystack, const std::string& needle) {
  return haystack.find(needle) != std::string::npos;
}

/// Extracts one header's value from a built message.
std::string headerOf(const std::string& message, const std::string& name) {
  const size_t start = message.find(name + ": ");
  if (start == std::string::npos) return "";
  const size_t from = start + name.size() + 2;
  const size_t end = message.find("\r\n", from);
  return message.substr(from, end - from);
}

}  // namespace

// MARK: - Structure

TEST(Compose, ProducesHeadersThenBlankLineThenBody) {
  const auto message = build(basicDraft());
  ASSERT_TRUE(message.has_value()) << message.error().message;

  const size_t separator = message->find("\r\n\r\n");
  ASSERT_NE(separator, std::string::npos) << "no header/body separator";
  // Every header must precede the separator.
  EXPECT_LT(message->find("From: "), separator);
  EXPECT_LT(message->find("Subject: "), separator);
}

TEST(Compose, UsesCrlfLineEndings) {
  const auto message = build(basicDraft());
  ASSERT_TRUE(message.has_value());
  // A bare LF anywhere in the headers is a protocol violation.
  const size_t separator = message->find("\r\n\r\n");
  const std::string headers = message->substr(0, separator);
  for (size_t i = 0; i < headers.size(); ++i) {
    if (headers[i] == '\n') {
      EXPECT_GT(i, 0u);
      EXPECT_EQ(headers[i - 1], '\r') << "bare LF at " << i;
    }
  }
}

TEST(Compose, IncludesRequiredHeaders) {
  const auto message = build(basicDraft());
  ASSERT_TRUE(message.has_value());

  for (const char* required : {"From:", "To:", "Subject:", "Date:", "Message-ID:",
                               "MIME-Version:", "Content-Type:"}) {
    EXPECT_TRUE(contains(*message, required)) << required;
  }
}

TEST(Compose, BodyIsBase64AndDecodesBack) {
  auto draft = basicDraft();
  draft.body = "Hello there.";
  const auto message = build(draft);
  ASSERT_TRUE(message.has_value());

  const size_t separator = message->find("\r\n\r\n");
  std::string body = message->substr(separator + 4);
  // Strip the CRLF wrapping before decoding.
  std::string joined;
  for (const char c : body) {
    if (c != '\r' && c != '\n') joined += c;
  }
  const auto decoded = crypto::base64url_decode(joined);
  ASSERT_TRUE(decoded.has_value());
  EXPECT_EQ(*decoded, "Hello there.");
}

TEST(Compose, RejectsDraftsThatCannotBeSent) {
  Draft noFrom = basicDraft();
  noFrom.from = {};
  EXPECT_FALSE(build(noFrom).has_value());

  Draft noRecipient = basicDraft();
  noRecipient.to.clear();
  EXPECT_FALSE(build(noRecipient).has_value());
}

// MARK: - Addresses

TEST(FormatAddress, PlainAddressHasNoBrackets) {
  EXPECT_EQ(format_address(mime::Address{"", "a@b.com"}), "a@b.com");
}

TEST(FormatAddress, NameAndAddress) {
  EXPECT_EQ(format_address(mime::Address{"Ada", "ada@example.com"}),
            "Ada <ada@example.com>");
}

TEST(FormatAddress, QuotesNamesContainingSpecials) {
  // An unquoted comma would split this into two recipients.
  const auto formatted = format_address(mime::Address{"Okonkwo, Ada", "ada@example.com"});
  EXPECT_EQ(formatted, "\"Okonkwo, Ada\" <ada@example.com>");
}

TEST(FormatAddress, EncodesNonAsciiNames) {
  const auto formatted = format_address(mime::Address{"José", "jose@example.com"});
  EXPECT_TRUE(contains(formatted, "=?UTF-8?B?"));
  // An encoded-word must NOT be wrapped in quotes — the quotes would decode as
  // part of the name.
  EXPECT_FALSE(contains(formatted, "\"=?"));
}

// MARK: - Header encoding

TEST(EncodeHeader, LeavesAsciiAlone) {
  EXPECT_EQ(encode_header_value("Design review"), "Design review");
}

TEST(EncodeHeader, EncodesNonAscii) {
  const auto encoded = encode_header_value("Café meeting");
  EXPECT_TRUE(contains(encoded, "=?UTF-8?B?"));
  EXPECT_TRUE(contains(encoded, "?="));
  // The raw bytes must be gone; many servers mangle 8-bit header text.
  EXPECT_FALSE(contains(encoded, "é"));
}

TEST(Compose, EncodesNonAsciiSubject) {
  auto draft = basicDraft();
  draft.subject = "Réunion";
  const auto message = build(draft);
  ASSERT_TRUE(message.has_value());
  EXPECT_TRUE(contains(headerOf(*message, "Subject"), "=?UTF-8?B?"));
}

// MARK: - Folding

TEST(FoldHeader, ShortHeadersAreNotFolded) {
  const auto folded = fold_header("Subject", "Short");
  EXPECT_EQ(folded, "Subject: Short");
  EXPECT_FALSE(contains(folded, "\r\n"));
}

TEST(FoldHeader, LongHeadersFoldAtWhitespace) {
  const std::string value =
      "this is a very long subject line that certainly exceeds the seventy eight "
      "character limit imposed by RFC 5322 and therefore has to be folded";
  const auto folded = fold_header("Subject", value);

  ASSERT_TRUE(contains(folded, "\r\n"));
  // Continuation lines MUST begin with whitespace or the header ends early.
  size_t pos = folded.find("\r\n");
  while (pos != std::string::npos) {
    ASSERT_LT(pos + 2, folded.size());
    EXPECT_TRUE(folded[pos + 2] == ' ' || folded[pos + 2] == '\t')
        << "continuation line does not start with whitespace";
    pos = folded.find("\r\n", pos + 2);
  }
}

TEST(FoldHeader, FoldingPreservesEveryWord) {
  const std::string value =
      "alpha bravo charlie delta echo foxtrot golf hotel india juliet kilo lima "
      "mike november oscar papa quebec";
  const auto folded = fold_header("Subject", value);

  for (const char* word : {"alpha", "juliet", "quebec", "november"}) {
    EXPECT_TRUE(contains(folded, word)) << word;
  }
}

// MARK: - Dates

TEST(FormatDate, MatchesRfc5322Shape) {
  // 2026-08-16T13:08:00Z
  const auto formatted = format_date(1786964880);
  // e.g. "Sun, 16 Aug 2026 13:08:00 +0000"
  EXPECT_TRUE(contains(formatted, "Aug 2026"));
  EXPECT_TRUE(contains(formatted, "+0000"));
  EXPECT_EQ(formatted.find(','), 3u) << "day name must be three letters";
}

// MARK: - Threading
//
// The headers that decide whether a reply joins the conversation or starts a
// new one for the recipient.

TEST(Compose, OmitsThreadingHeadersForANewMessage) {
  const auto message = build(basicDraft());
  ASSERT_TRUE(message.has_value());
  EXPECT_FALSE(contains(*message, "In-Reply-To:"));
  EXPECT_FALSE(contains(*message, "References:"));
}

TEST(Compose, IncludesThreadingHeadersForAReply) {
  auto draft = basicDraft();
  draft.in_reply_to = "parent@example.com";
  draft.references = {"root@example.com", "parent@example.com"};

  const auto message = build(draft);
  ASSERT_TRUE(message.has_value());

  EXPECT_EQ(headerOf(*message, "In-Reply-To"), "<parent@example.com>");
  const auto references = headerOf(*message, "References");
  EXPECT_TRUE(contains(references, "<root@example.com>"));
  EXPECT_TRUE(contains(references, "<parent@example.com>"));
}

TEST(Compose, MessageIdIsBracketedAndUnique) {
  const auto first = build(basicDraft());
  const auto second = build(basicDraft());
  ASSERT_TRUE(first.has_value());
  ASSERT_TRUE(second.has_value());

  const auto a = headerOf(*first, "Message-ID");
  const auto b = headerOf(*second, "Message-ID");
  EXPECT_EQ(a.front(), '<');
  EXPECT_EQ(a.back(), '>');
  EXPECT_NE(a, b) << "Message-ID must be unique per message";
}

// MARK: - Reply subject

TEST(ReplySubject, AddsPrefixWhenAbsent) {
  EXPECT_EQ(reply_subject("Design review"), "Re: Design review");
}

TEST(ReplySubject, DoesNotStackPrefixes) {
  // Otherwise a few round trips produce "Re: Re: Re: Re:".
  EXPECT_EQ(reply_subject("Re: Design review"), "Re: Design review");
  EXPECT_EQ(reply_subject("RE: Design review"), "RE: Design review");
  EXPECT_EQ(reply_subject("re: Design review"), "re: Design review");
}

TEST(ReplySubject, HandlesEmptySubject) {
  EXPECT_EQ(reply_subject(""), "Re: ");
}

// MARK: - Base64 variants

TEST(Base64, StandardIsPaddedAndUsesTheStandardAlphabet) {
  const std::vector<uint8_t> bytes = {0xFB, 0xFF, 0xBE};
  const auto standard = crypto::base64_encode(bytes);
  // Standard base64 pads and may contain + or /; base64url does neither.
  EXPECT_EQ(crypto::base64_encode({'a'}), "YQ==");
  EXPECT_EQ(crypto::base64_encode({'a', 'b'}), "YWI=");
  EXPECT_EQ(crypto::base64_encode({'a', 'b', 'c'}), "YWJj");
  EXPECT_NE(standard, crypto::base64url_encode(bytes));
}
