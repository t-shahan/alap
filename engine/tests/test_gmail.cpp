/// @file test_gmail.cpp
/// @brief Payload-tree flattening, tested against fixtures.
///
/// `parse_message_json` is deliberately separate from `GmailClient` so the
/// hard part — walking an arbitrarily nested MIME tree — can be tested without
/// a network or an account.

#include <gtest/gtest.h>

#include <string>

#include "mailengine/gmail.hpp"

using namespace mailengine;

namespace {

/// A plain single-part text message. "SGVsbG8sIHdvcmxk" is "Hello, world".
constexpr const char* kSimpleMessage = R"({
  "id": "18f0a1b2c3d4e5f6",
  "threadId": "18f0a1b2c3d4e5f0",
  "labelIds": ["INBOX", "UNREAD"],
  "snippet": "Hello, world",
  "internalDate": "1755300000000",
  "sizeEstimate": 2048,
  "payload": {
    "mimeType": "text/plain",
    "headers": [
      {"name": "From", "value": "Ada Okonkwo <ada@example.com>"},
      {"name": "To", "value": "dev@example.com"},
      {"name": "Subject", "value": "Design review"},
      {"name": "Message-ID", "value": "<abc123@mail.example.com>"}
    ],
    "body": {"size": 12, "data": "SGVsbG8sIHdvcmxk"}
  }
})";

/// multipart/alternative — the common HTML mail shape.
constexpr const char* kAlternativeMessage = R"({
  "id": "msg2",
  "threadId": "thread2",
  "labelIds": ["INBOX"],
  "internalDate": "1755300000000",
  "payload": {
    "mimeType": "multipart/alternative",
    "headers": [{"name": "Subject", "value": "Newsletter"}],
    "parts": [
      {"mimeType": "text/plain", "filename": "", "body": {"data": "cGxhaW4gdGV4dA"}},
      {"mimeType": "text/html", "filename": "", "body": {"data": "PGI-cmljaDwvYj4"}}
    ]
  }
})";

/// multipart/mixed wrapping an alternative plus a PDF attachment, which is
/// what a real message with an attachment looks like.
constexpr const char* kAttachmentMessage = R"({
  "id": "msg3",
  "threadId": "thread3",
  "labelIds": ["INBOX"],
  "internalDate": "1755300000000",
  "payload": {
    "mimeType": "multipart/mixed",
    "headers": [{"name": "Subject", "value": "Q3 spend"}],
    "parts": [
      {
        "mimeType": "multipart/alternative",
        "filename": "",
        "parts": [
          {"mimeType": "text/plain", "filename": "", "body": {"data": "Ym9keQ"}},
          {"mimeType": "text/html", "filename": "", "body": {"data": "PHA-Ym9keTwvcD4"}}
        ]
      },
      {
        "mimeType": "application/pdf",
        "filename": "breakdown.pdf",
        "body": {"attachmentId": "ANGjdJ_att_1", "size": 91234}
      },
      {
        "mimeType": "image/png",
        "filename": "logo.png",
        "headers": [
          {"name": "Content-ID", "value": "<logo@example.com>"},
          {"name": "Content-Disposition", "value": "inline; filename=logo.png"}
        ],
        "body": {"attachmentId": "ANGjdJ_att_2", "size": 4096}
      }
    ]
  }
})";

}  // namespace

TEST(ParseMessage, ExtractsCoreFields) {
  const auto message = parse_message_json(kSimpleMessage);
  ASSERT_TRUE(message.has_value()) << message.error().message;

  EXPECT_EQ(message->id, "18f0a1b2c3d4e5f6");
  EXPECT_EQ(message->thread_id, "18f0a1b2c3d4e5f0");
  EXPECT_EQ(message->subject, "Design review");
  EXPECT_EQ(message->from.name, "Ada Okonkwo");
  EXPECT_EQ(message->from.email, "ada@example.com");
  EXPECT_EQ(message->size_estimate, 2048);
}

TEST(ParseMessage, ParsesInternalDateFromString) {
  // Gmail sends internalDate as a STRING of epoch millis. Reading it as a
  // number yields 0, and every message silently lands at 1970.
  const auto message = parse_message_json(kSimpleMessage);
  ASSERT_TRUE(message.has_value());
  EXPECT_EQ(message->internal_date_ms, 1755300000000LL);
}

TEST(ParseMessage, StripsAngleBracketsFromMessageId) {
  const auto message = parse_message_json(kSimpleMessage);
  ASSERT_TRUE(message.has_value());
  EXPECT_EQ(message->rfc822_message_id, "abc123@mail.example.com");
}

TEST(ParseMessage, ExposesLabelPredicates) {
  const auto message = parse_message_json(kSimpleMessage);
  ASSERT_TRUE(message.has_value());

  EXPECT_TRUE(message->has_label("INBOX"));
  EXPECT_TRUE(message->is_unread());
  EXPECT_FALSE(message->is_starred());
  EXPECT_FALSE(message->is_draft());
}

TEST(ParseMessage, DecodesSinglePartBody) {
  const auto message = parse_message_json(kSimpleMessage);
  ASSERT_TRUE(message.has_value());
  EXPECT_EQ(message->text_body, "Hello, world");
  EXPECT_TRUE(message->html_body.empty());
}

TEST(ParseMessage, TakesBothPartsOfMultipartAlternative) {
  const auto message = parse_message_json(kAlternativeMessage);
  ASSERT_TRUE(message.has_value()) << message.error().message;

  EXPECT_EQ(message->text_body, "plain text");
  EXPECT_EQ(message->html_body, "<b>rich</b>");
}

TEST(ParseMessage, FindsBodiesNestedInsideMultipartMixed) {
  // The body lives two levels down, under mixed → alternative.
  const auto message = parse_message_json(kAttachmentMessage);
  ASSERT_TRUE(message.has_value()) << message.error().message;

  EXPECT_EQ(message->text_body, "body");
  EXPECT_EQ(message->html_body, "<p>body</p>");
}

TEST(ParseMessage, CollectsAttachmentMetadata) {
  const auto message = parse_message_json(kAttachmentMessage);
  ASSERT_TRUE(message.has_value());
  ASSERT_EQ(message->attachments.size(), 2u);

  const auto& pdf = message->attachments[0];
  EXPECT_EQ(pdf.filename, "breakdown.pdf");
  EXPECT_EQ(pdf.mime_type, "application/pdf");
  EXPECT_EQ(pdf.size_bytes, 91234);
  EXPECT_EQ(pdf.attachment_id, "ANGjdJ_att_1");
  EXPECT_FALSE(pdf.is_inline);
}

TEST(ParseMessage, MarksInlineImagesAndUnwrapsContentId) {
  const auto message = parse_message_json(kAttachmentMessage);
  ASSERT_TRUE(message.has_value());
  ASSERT_EQ(message->attachments.size(), 2u);

  const auto& logo = message->attachments[1];
  EXPECT_TRUE(logo.is_inline);
  // html_body references this as `cid:logo@example.com`, so the brackets must
  // come off or the lookup never matches.
  EXPECT_EQ(logo.content_id, "logo@example.com");
}

TEST(ParseMessage, DoesNotTreatAttachmentsAsBodyText) {
  const auto message = parse_message_json(kAttachmentMessage);
  ASSERT_TRUE(message.has_value());
  // A PDF's bytes must never end up rendered as the message body.
  EXPECT_EQ(message->text_body, "body");
}

TEST(ParseMessage, RejectsInvalidJson) {
  const auto message = parse_message_json("{not json");
  EXPECT_FALSE(message.has_value());
}

TEST(ParseMessage, RejectsMessageWithoutId) {
  const auto message = parse_message_json(R"({"threadId": "t1"})");
  EXPECT_FALSE(message.has_value());
}

TEST(ParseMessage, ToleratesMissingPayload) {
  // messages.list with format=minimal returns no payload at all.
  const auto message = parse_message_json(R"({"id":"m1","threadId":"t1"})");
  ASSERT_TRUE(message.has_value()) << message.error().message;
  EXPECT_EQ(message->id, "m1");
  EXPECT_TRUE(message->subject.empty());
}

TEST(ParseMessage, DecodesEncodedSubjectEndToEnd) {
  const std::string json = R"({
    "id": "m1", "threadId": "t1", "internalDate": "0",
    "payload": {"headers": [{"name":"Subject","value":"=?UTF-8?B?5pel5pys6Kqe?="}]}
  })";
  const auto message = parse_message_json(json);
  ASSERT_TRUE(message.has_value());
  EXPECT_EQ(message->subject, "日本語");
}
