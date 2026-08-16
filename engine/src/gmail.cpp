/// @file gmail.cpp
/// @brief Gmail API client and payload-tree flattening.

#include "mailengine/gmail.hpp"

#include <nlohmann/json.hpp>
#include <algorithm>
#include <chrono>
#include <thread>

#include "mailengine/crypto.hpp"
#include "mailengine/html.hpp"
#include "mailengine/keychain.hpp"

namespace mailengine {
namespace {

using nlohmann::json;

constexpr const char* kApiBase = "https://gmail.googleapis.com/gmail/v1/users/me";
constexpr int kMaxRetries = 5;

/// Case-insensitive header lookup over Gmail's `headers: [{name, value}]`.
std::string header_value(const json& headers, std::string_view wanted) {
  if (!headers.is_array()) return {};
  for (const auto& header : headers) {
    const std::string name = header.value("name", "");
    if (name.size() != wanted.size()) continue;
    if (std::equal(name.begin(), name.end(), wanted.begin(), [](char a, char b) {
          return std::tolower(static_cast<unsigned char>(a)) ==
                 std::tolower(static_cast<unsigned char>(b));
        })) {
      return header.value("value", "");
    }
  }
  return {};
}

/// Recursively walks the MIME part tree, collecting bodies and attachments.
///
/// Gmail nests parts arbitrarily. A typical message with an attachment is:
///
///   multipart/mixed
///     multipart/alternative
///       text/plain
///       text/html
///     application/pdf   (attachment)
///
/// The rules applied here:
///   - a part with a filename is an attachment, never a body
///   - text/plain and text/html fill their respective body slots
///   - the FIRST of each type wins, so a quoted reply nested deeper does not
///     overwrite the actual message body
void walk_parts(const json& part, GmailMessage& out) {
  const std::string mime_type = part.value("mimeType", "");
  const std::string filename = part.value("filename", "");
  const json& body = part.contains("body") ? part["body"] : json::object();
  const json& headers = part.contains("headers") ? part["headers"] : json::array();

  const bool has_attachment_id = body.contains("attachmentId");

  // A non-empty filename marks an attachment. Inline images also carry one,
  // distinguished by a Content-ID and an inline disposition.
  if (!filename.empty() || has_attachment_id) {
    GmailAttachment attachment;
    attachment.attachment_id = body.value("attachmentId", "");
    attachment.filename = mime::decode_encoded_words(filename);
    attachment.mime_type = mime_type;
    attachment.size_bytes = body.value("size", 0);

    std::string content_id = header_value(headers, "Content-ID");
    // Content-ID is wrapped in angle brackets; cid: URLs reference the inside.
    if (content_id.size() >= 2 && content_id.front() == '<' && content_id.back() == '>') {
      content_id = content_id.substr(1, content_id.size() - 2);
    }
    attachment.content_id = content_id;

    const std::string disposition = header_value(headers, "Content-Disposition");
    attachment.is_inline = disposition.find("inline") != std::string::npos ||
                           !attachment.content_id.empty();

    out.attachments.push_back(std::move(attachment));
    return;  // attachments never contribute body text
  }

  if (body.contains("data")) {
    const std::string encoded = body.value("data", "");
    auto decoded = crypto::base64url_decode(encoded);
    if (decoded) {
      if (mime_type == "text/plain" && out.text_body.empty()) {
        out.text_body = *decoded;
      } else if (mime_type == "text/html" && out.html_body.empty()) {
        out.html_body = *decoded;
      }
    }
  }

  if (part.contains("parts") && part["parts"].is_array()) {
    for (const auto& child : part["parts"]) {
      walk_parts(child, out);
    }
  }
}

}  // namespace

bool GmailMessage::has_label(std::string_view label) const {
  return std::find(label_ids.begin(), label_ids.end(), label) != label_ids.end();
}

// MARK: - Parsing

Result<GmailMessage> parse_message_json(const std::string& body) {
  const json root = json::parse(body, nullptr, false);
  if (root.is_discarded()) {
    return make_error("messages.get returned invalid JSON");
  }

  GmailMessage message;
  message.id = root.value("id", "");
  message.thread_id = root.value("threadId", "");
  // Gmail HTML-escapes the snippet, so "Next week&#39;s menu" arrives verbatim
  // and would render with the raw entity visible in a native list.
  message.snippet = html::unescape_entities(root.value("snippet", ""));
  message.size_estimate = root.value("sizeEstimate", 0);

  if (message.id.empty()) {
    return make_error("message JSON carried no id");
  }

  // internalDate is a STRING of epoch milliseconds, not a number — a
  // json.value<int64_t>() here silently yields 0.
  if (root.contains("internalDate")) {
    const auto& value = root["internalDate"];
    message.internal_date_ms =
        value.is_string() ? std::stoll(value.get<std::string>()) : value.get<int64_t>();
  }

  if (root.contains("labelIds") && root["labelIds"].is_array()) {
    for (const auto& label : root["labelIds"]) {
      message.label_ids.push_back(label.get<std::string>());
    }
  }

  if (root.contains("payload")) {
    const json& payload = root["payload"];
    const json& headers =
        payload.contains("headers") ? payload["headers"] : json::array();

    message.subject = mime::decode_encoded_words(header_value(headers, "Subject"));
    message.from = mime::parse_address(header_value(headers, "From"));
    message.to = mime::parse_address_list(header_value(headers, "To"));
    message.cc = mime::parse_address_list(header_value(headers, "Cc"));
    message.bcc = mime::parse_address_list(header_value(headers, "Bcc"));

    std::string rfc_id = header_value(headers, "Message-ID");
    if (rfc_id.size() >= 2 && rfc_id.front() == '<' && rfc_id.back() == '>') {
      rfc_id = rfc_id.substr(1, rfc_id.size() - 2);
    }
    message.rfc822_message_id = rfc_id;

    walk_parts(payload, message);
  }

  return message;
}

// MARK: - TokenProvider

TokenProvider::TokenProvider(OAuthConfig config, std::string account_id)
    : oauth_(std::move(config)), account_id_(std::move(account_id)) {}

Result<std::string> TokenProvider::access_token() {
  // Held across the refresh so concurrent workers cannot each mint their own
  // token; the first to arrive refreshes and the rest reuse the result.
  const std::lock_guard<std::mutex> lock(mutex_);

  if (!cached_.access_token.empty() && !cached_.needs_refresh()) {
    return cached_.access_token;
  }

  const Keychain keychain;
  auto refresh_token = keychain.load(account_id_);
  if (!refresh_token) {
    return make_error("no stored credential for " + account_id_ +
                      "; run `mailengined auth " + account_id_ + "`");
  }

  auto tokens = oauth_.refresh(*refresh_token);
  if (!tokens) {
    return tokens.error();
  }
  cached_ = *tokens;
  return cached_.access_token;
}

// MARK: - GmailClient

GmailClient::GmailClient(TokenProvider& tokens) : tokens_(tokens) {}

namespace {

/// True for failures that are worth retrying rather than surfacing.
///
/// Rate limits are a normal part of a large backfill, and 5xx is transient.
/// Everything else is a real failure: returning immediately keeps genuine bugs
/// from being buried under five silent retries.
bool is_retryable(long status, const std::string& body) {
  if (status == 429 || status >= 500) return true;
  return status == 403 && body.find("ateLimitExceeded") != std::string::npos;
}

}  // namespace

Result<std::string> GmailClient::api_post(const std::string& path,
                                          const std::string& json_body) {
  for (int attempt = 0; attempt < kMaxRetries; ++attempt) {
    auto token = tokens_.access_token();
    if (!token) {
      return token.error();
    }

    auto response = http_.post(kApiBase + path, json_body, "application/json",
                               {{"Authorization", "Bearer " + *token}});
    if (!response) {
      return response.error();
    }
    if (response->ok()) {
      return response->body;
    }
    if (!is_retryable(response->status, response->body)) {
      return make_error("gmail POST " + path + " failed: " + response->body,
                        static_cast<int>(response->status));
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(250 << attempt));
  }
  return make_error("gmail POST " + path + " exhausted retries");
}

Result<void> GmailClient::batch_modify(
    const std::vector<std::string>& remote_message_ids,
    const std::vector<std::string>& add_label_ids,
    const std::vector<std::string>& remove_label_ids) {
  if (remote_message_ids.empty()) {
    return Result<void>{};  // nothing to do is success, not an error
  }
  if (remote_message_ids.size() > 1000) {
    return make_error("batchModify accepts at most 1000 ids per call");
  }

  json request;
  request["ids"] = remote_message_ids;
  request["addLabelIds"] = add_label_ids;
  request["removeLabelIds"] = remove_label_ids;

  // batchModify answers 204 No Content on success, so an empty body here is
  // the expected outcome rather than a sign something went wrong.
  auto response = api_post("/messages/batchModify", request.dump());
  if (!response) {
    return response.error();
  }
  return Result<void>{};
}

Result<std::string> GmailClient::send_message(const std::string& raw_message,
                                              const std::string& thread_id) {
  if (raw_message.empty()) {
    return make_error("cannot send an empty message");
  }

  json request;
  // Gmail wants the whole message base64URL encoded — the URL-safe alphabet,
  // even though the message's own MIME bodies use standard base64.
  const std::vector<uint8_t> bytes(raw_message.begin(), raw_message.end());
  request["raw"] = crypto::base64url_encode(bytes);
  if (!thread_id.empty()) {
    request["threadId"] = thread_id;
  }

  auto response = api_post("/messages/send", request.dump());
  if (!response) {
    return response.error();
  }

  const auto root = json::parse(*response, nullptr, false);
  if (root.is_discarded()) {
    return make_error("send response was not valid JSON");
  }
  return root.value("id", std::string{});
}

Result<std::string> GmailClient::get_attachment(
    const std::string& remote_message_id,
    const std::string& remote_attachment_id) {
  if (remote_message_id.empty() || remote_attachment_id.empty()) {
    return make_error("attachment id and message id are both required", 400);
  }

  // Both ids are interpolated into a URL, so both are escaped. Gmail's own ids
  // are URL-safe in practice, but these arrive via Postgres and the cost of
  // being wrong here is a malformed request against someone else's mailbox.
  auto response =
      api_get("/messages/" + HttpClient::url_encode(remote_message_id) +
              "/attachments/" + HttpClient::url_encode(remote_attachment_id));
  if (!response) {
    return response.error();
  }

  const auto root = json::parse(*response, nullptr, false);
  if (root.is_discarded()) {
    return make_error("attachment response was not valid JSON");
  }

  const auto encoded = root.value("data", std::string{});
  if (encoded.empty()) {
    // A zero-byte attachment is legal, but Gmail omits `data` entirely when
    // the id is stale — which happens when a message is re-synced and its
    // attachment ids are reissued. Treat it as retryable-after-resync rather
    // than silently storing an empty file.
    return make_error("attachment response carried no data", 404);
  }

  // Gmail encodes attachment payloads with the URL-safe alphabet, the same as
  // message bodies.
  auto decoded = crypto::base64url_decode(encoded);
  if (!decoded) {
    return decoded.error();
  }

  // `size` is Gmail's own count of the decoded bytes. Disagreement means a
  // truncated transfer, and storing it would poison a content-addressed store
  // with a blob whose digest is authoritative but whose content is wrong.
  if (root.contains("size") && root["size"].is_number()) {
    const auto expected = root["size"].get<int64_t>();
    if (expected != static_cast<int64_t>(decoded->size())) {
      return make_error("attachment size mismatch: expected " +
                        std::to_string(expected) + " bytes, decoded " +
                        std::to_string(decoded->size()));
    }
  }

  return decoded;
}

Result<std::string> GmailClient::api_get(const std::string& path) {
  for (int attempt = 0; attempt < kMaxRetries; ++attempt) {
    auto token = tokens_.access_token();
    if (!token) {
      return token.error();
    }

    auto response = http_.get(kApiBase + path,
                              {{"Authorization", "Bearer " + *token}});
    if (!response) {
      return response.error();
    }

    if (response->ok()) {
      return response->body;
    }

    if (!is_retryable(response->status, response->body)) {
      return make_error("gmail " + path + " failed: " + response->body,
                        static_cast<int>(response->status));
    }

    // Exponential backoff: 250ms, 500ms, 1s, 2s...
    std::this_thread::sleep_for(std::chrono::milliseconds(250 << attempt));
  }

  return make_error("gmail " + path + " exhausted retries");
}

Result<std::vector<GmailLabel>> GmailClient::list_labels() {
  auto body = api_get("/labels");
  if (!body) {
    return body.error();
  }

  const json root = json::parse(*body, nullptr, false);
  if (root.is_discarded() || !root.contains("labels")) {
    return make_error("labels response malformed");
  }

  std::vector<GmailLabel> labels;
  for (const auto& entry : root["labels"]) {
    labels.push_back(GmailLabel{
        .id = entry.value("id", ""),
        .name = entry.value("name", ""),
        .type = entry.value("type", "user"),
    });
  }
  return labels;
}

Result<GmailProfile> GmailClient::get_profile() {
  auto body = api_get("/profile");
  if (!body) {
    return body.error();
  }

  const json root = json::parse(*body, nullptr, false);
  if (root.is_discarded()) {
    return make_error("profile response malformed");
  }

  return GmailProfile{
      .email_address = root.value("emailAddress", ""),
      .history_id = root.value("historyId", ""),
      .messages_total = root.value("messagesTotal", 0),
  };
}

Result<MessagePage> GmailClient::list_messages(const std::string& page_token,
                                               const std::string& query,
                                               int max_results) {
  std::string path = "/messages?maxResults=" + std::to_string(max_results);
  // Gmail EXCLUDES spam and trash from messages.list unless asked. Leaving it
  // off meant the Trash mailbox was permanently empty and trashing a message
  // moved it somewhere the user could not look at or recover it from — the app
  // showed a Trash folder it could never populate.
  //
  // The labels themselves are already synced per message, so including these
  // costs one flag rather than any new plumbing: a message carrying TRASH
  // simply lands in the Trash mailbox like any other label.
  path += "&includeSpamTrash=true";
  if (!page_token.empty()) {
    path += "&pageToken=" + HttpClient::url_encode(page_token);
  }
  if (!query.empty()) {
    path += "&q=" + HttpClient::url_encode(query);
  }

  auto body = api_get(path);
  if (!body) {
    return body.error();
  }

  const json root = json::parse(*body, nullptr, false);
  if (root.is_discarded()) {
    return make_error("messages.list response malformed");
  }

  MessagePage page;
  page.next_page_token = root.value("nextPageToken", "");
  // An empty mailbox omits "messages" entirely rather than sending [].
  if (root.contains("messages") && root["messages"].is_array()) {
    for (const auto& entry : root["messages"]) {
      page.message_ids.push_back(entry.value("id", ""));
    }
  }
  return page;
}

Result<GmailMessage> GmailClient::get_message(const std::string& message_id) {
  auto body = api_get("/messages/" + message_id + "?format=full");
  if (!body) {
    return body.error();
  }
  return parse_message_json(*body);
}

Result<HistoryPage> GmailClient::list_history(const std::string& start_history_id,
                                              const std::string& page_token) {
  std::string path = "/history?startHistoryId=" + start_history_id;
  if (!page_token.empty()) {
    path += "&pageToken=" + HttpClient::url_encode(page_token);
  }

  auto body = api_get(path);
  if (!body) {
    // 404 means the watermark has aged out of Gmail's ~1 week of history and
    // the caller must fall back to a full resync.
    return body.error();
  }

  const json root = json::parse(*body, nullptr, false);
  if (root.is_discarded()) {
    return make_error("history.list response malformed");
  }

  HistoryPage page;
  page.next_page_token = root.value("nextPageToken", "");
  page.history_id = root.value("historyId", "");

  if (!root.contains("history") || !root["history"].is_array()) {
    return page;  // nothing changed
  }

  const auto collect = [&](const json& records, HistoryChange::Kind kind) {
    if (!records.is_array()) return;
    for (const auto& record : records) {
      const json& message = record.contains("message") ? record["message"] : record;
      HistoryChange change;
      change.kind = kind;
      change.message_id = message.value("id", "");
      change.thread_id = message.value("threadId", "");
      if (record.contains("labelIds") && record["labelIds"].is_array()) {
        for (const auto& label : record["labelIds"]) {
          change.label_ids.push_back(label.get<std::string>());
        }
      }
      page.changes.push_back(std::move(change));
    }
  };

  for (const auto& entry : root["history"]) {
    if (entry.contains("messagesAdded")) {
      collect(entry["messagesAdded"], HistoryChange::Kind::MessageAdded);
    }
    if (entry.contains("messagesDeleted")) {
      collect(entry["messagesDeleted"], HistoryChange::Kind::MessageDeleted);
    }
    if (entry.contains("labelsAdded")) {
      collect(entry["labelsAdded"], HistoryChange::Kind::LabelsAdded);
    }
    if (entry.contains("labelsRemoved")) {
      collect(entry["labelsRemoved"], HistoryChange::Kind::LabelsRemoved);
    }
  }

  return page;
}

}  // namespace mailengine
