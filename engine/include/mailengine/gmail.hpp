/// @file gmail.hpp
/// @brief Gmail API client and message model.

#pragma once

#include <cstdint>
#include <memory>
#include <optional>
#include <string>
#include <vector>

#include "mailengine/http.hpp"
#include "mailengine/mime.hpp"
#include "mailengine/oauth.hpp"
#include "mailengine/result.hpp"

namespace mailengine {

/// @brief A Gmail label. Gmail has no folders — archive means removing INBOX.
struct GmailLabel {
  std::string id;    ///< e.g. "INBOX", "Label_42"
  std::string name;  ///< display name
  std::string type;  ///< "system" or "user"
};

/// @brief Mailbox-level state.
struct GmailProfile {
  std::string email_address;
  /// Opaque, monotonically increasing. The watermark for incremental sync.
  std::string history_id;
  int64_t messages_total = 0;
};

/// @brief Attachment metadata. Bytes are fetched separately and on demand.
struct GmailAttachment {
  std::string attachment_id;
  std::string filename;
  std::string mime_type;
  int64_t size_bytes = 0;
  std::string content_id;  ///< set for inline images referenced by cid:
  bool is_inline = false;
};

/// @brief A message, flattened from Gmail's payload tree into our schema.
struct GmailMessage {
  std::string id;
  std::string thread_id;
  std::string rfc822_message_id;
  std::vector<std::string> label_ids;
  std::string snippet;
  int64_t internal_date_ms = 0;
  int64_t size_estimate = 0;

  mime::Address from;
  std::vector<mime::Address> to;
  std::vector<mime::Address> cc;
  std::vector<mime::Address> bcc;
  std::string subject;

  std::string text_body;
  std::string html_body;
  std::vector<GmailAttachment> attachments;

  /// @brief True when the message still carries the given label.
  [[nodiscard]] bool has_label(std::string_view label) const;

  [[nodiscard]] bool is_unread() const { return has_label("UNREAD"); }
  [[nodiscard]] bool is_starred() const { return has_label("STARRED"); }
  [[nodiscard]] bool is_draft() const { return has_label("DRAFT"); }
};

/// @brief One page of message identifiers.
struct MessagePage {
  std::vector<std::string> message_ids;
  /// Empty when this is the last page.
  std::string next_page_token;
};

/// @brief A single change from `users.history.list`.
struct HistoryChange {
  enum class Kind { MessageAdded, MessageDeleted, LabelsAdded, LabelsRemoved };

  Kind kind = Kind::MessageAdded;
  std::string message_id;
  std::string thread_id;
  /// Populated for LabelsAdded / LabelsRemoved.
  std::vector<std::string> label_ids;
};

/// @brief Result of an incremental sync poll.
struct HistoryPage {
  std::vector<HistoryChange> changes;
  std::string next_page_token;
  /// The watermark to persist once this page is applied.
  std::string history_id;
};

/// @brief Supplies a valid access token, refreshing when needed.
///
/// Access tokens last an hour. Rather than making every call site handle
/// expiry, this caches the current token and mints a new one from the stored
/// refresh token when it is within a minute of expiring.
class TokenProvider {
 public:
  TokenProvider(OAuthConfig config, std::string account_id);

  /// @brief Returns a valid bearer token, refreshing if necessary.
  [[nodiscard]] Result<std::string> access_token();

 private:
  OAuthClient oauth_;
  std::string account_id_;
  TokenSet cached_;
};

/// @brief The single write operation the outbox drainer needs.
///
/// Extracted as an interface purely for dependency inversion: it lets the
/// drainer's failure-classification logic be tested against a fake that
/// returns programmed errors, with no network and no account. That logic
/// decides whether a user's archive is retried or permanently abandoned, so it
/// deserves real coverage.
class LabelWriter {
 public:
  virtual ~LabelWriter() = default;

  /// @see GmailClient::batch_modify
  [[nodiscard]] virtual Result<void> batch_modify(
      const std::vector<std::string>& remote_message_ids,
      const std::vector<std::string>& add_label_ids,
      const std::vector<std::string>& remove_label_ids) = 0;
};

/// @brief Read-side Gmail API surface.
///
/// ## Rate limits
///
/// Gmail bills in quota units per user per second. `messages.get` is 5 units,
/// `messages.list` is 5, `history.list` is 2, against a 250 unit/second budget.
/// A 429 or 403 rateLimitExceeded is retried with exponential backoff, which
/// is a normal part of a large backfill rather than an error.
class GmailClient : public LabelWriter {
 public:
  GmailClient(TokenProvider& tokens);

  /// @brief Lists every label in the mailbox.
  [[nodiscard]] Result<std::vector<GmailLabel>> list_labels();

  /// @brief Reads the profile, including the current historyId.
  [[nodiscard]] Result<GmailProfile> get_profile();

  /// @brief Lists message ids, newest first.
  /// @param page_token Empty for the first page.
  /// @param query Optional Gmail search syntax, e.g. "in:inbox".
  [[nodiscard]] Result<MessagePage> list_messages(const std::string& page_token = {},
                                                  const std::string& query = {},
                                                  int max_results = 100);

  /// @brief Fetches and parses one message in full.
  [[nodiscard]] Result<GmailMessage> get_message(const std::string& message_id);

  /// @brief Adds and/or removes labels across many messages in one call.
  ///
  /// This is the single write primitive Gmail exposes for the operations we
  /// care about. Archive is `removeLabelIds: ["INBOX"]`; mark-read is
  /// `removeLabelIds: ["UNREAD"]`; star is `addLabelIds: ["STARRED"]`.
  ///
  /// Naturally idempotent — adding a label already present, or removing one
  /// already absent, is a no-op. That is what makes outbox retries safe.
  ///
  /// @param remote_message_ids Gmail message ids. Max 1000 per call.
  [[nodiscard]] Result<void> batch_modify(
      const std::vector<std::string>& remote_message_ids,
      const std::vector<std::string>& add_label_ids,
      const std::vector<std::string>& remove_label_ids) override;

  /// @brief Lists changes since `start_history_id`.
  ///
  /// This is the mechanism that makes refresh fast: instead of re-scanning the
  /// mailbox, ask only what changed. Gmail keeps roughly a week of history, so
  /// a `404 notFound` here means the watermark is too old and a full resync is
  /// required.
  [[nodiscard]] Result<HistoryPage> list_history(const std::string& start_history_id,
                                                 const std::string& page_token = {});

 private:
  TokenProvider& tokens_;
  HttpClient http_;

  /// Issues an authenticated GET, retrying on rate limits and 5xx.
  [[nodiscard]] Result<std::string> api_get(const std::string& path);

  /// Issues an authenticated JSON POST, with the same retry policy.
  [[nodiscard]] Result<std::string> api_post(const std::string& path,
                                             const std::string& json_body);
};

/// @brief Converts a Gmail `messages.get` JSON body into a `GmailMessage`.
///
/// Exposed separately from the client so it can be tested against fixtures
/// without any network. This is where the payload tree is walked.
[[nodiscard]] Result<GmailMessage> parse_message_json(const std::string& json);

}  // namespace mailengine
