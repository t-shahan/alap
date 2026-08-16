/// @file outbox.cpp
/// @brief Outbox drainer implementation.

#include "mailengine/outbox.hpp"

#include <nlohmann/json.hpp>
#include <utility>

namespace mailengine {
namespace {

using nlohmann::json;

/// Reads a JSON array of strings, tolerating absence.
std::vector<std::string> string_array(const json& root, const char* key) {
  std::vector<std::string> values;
  if (!root.contains(key) || !root[key].is_array()) {
    return values;
  }
  for (const auto& entry : root[key]) {
    if (entry.is_string()) {
      values.push_back(entry.get<std::string>());
    }
  }
  return values;
}

}  // namespace

OutboxDisposition classify_attempt(bool succeeded, int error_code, int attempts,
                                   int max_attempts) {
  if (succeeded) {
    return OutboxDisposition::Applied;
  }
  // Gmail rejected the request itself; another identical attempt fails the
  // same way. 429 is excluded — it is a rate limit, not a bad request.
  const bool client_error =
      error_code >= 400 && error_code < 500 && error_code != 429;

  // Not all 5xx are transient. 501 Not Implemented and 505 HTTP Version Not
  // Supported describe a capability the server will never have, so retrying is
  // pointless. `apply` also uses 501 for ops we have not built yet, and
  // without this those rows would bounce through every attempt before failing.
  const bool permanent_server_error = error_code == 501 || error_code == 505;

  if (client_error || permanent_server_error || attempts >= max_attempts) {
    return OutboxDisposition::Failed;
  }
  return OutboxDisposition::Retry;
}

OutboxDrainer::OutboxDrainer(LabelWriter& gmail, PostgresStore& store,
                             std::string account_id, int max_attempts)
    : gmail_(gmail),
      store_(store),
      account_id_(std::move(account_id)),
      max_attempts_(max_attempts) {}

Result<void> OutboxDrainer::apply(const PostgresStore::OutboxItem& item) {
  const json payload = json::parse(item.payload, nullptr, false);
  if (payload.is_discarded()) {
    // Malformed payload can never succeed, however many times it is retried.
    return make_error("outbox payload is not valid JSON", 400);
  }

  // `modify_labels` and `mark_read` are both label operations — Gmail has no
  // separate "archive" or "mark read" verb. The mutators already encode the
  // difference in addLabelIds/removeLabelIds, so both land here.
  if (item.op == "modify_labels" || item.op == "mark_read") {
    const auto message_ids = string_array(payload, "messageIds");
    const auto add_labels = string_array(payload, "addLabelIds");
    const auto remove_labels = string_array(payload, "removeLabelIds");

    if (message_ids.empty()) {
      // Nothing to do. Treat as applied rather than retrying forever.
      return Result<void>{};
    }
    return gmail_.batch_modify(message_ids, add_labels, remove_labels);
  }

  if (item.op == "send") {
    return make_error("send is not implemented yet", 501);
  }
  if (item.op == "delete_forever") {
    return make_error("delete_forever is not implemented yet", 501);
  }

  return make_error("unknown outbox op: " + item.op, 400);
}

Result<DrainStats> OutboxDrainer::drain_once(int limit) {
  DrainStats stats;

  auto claimed = store_.claim_outbox(account_id_, limit);
  if (!claimed) {
    return claimed.error();
  }
  stats.claimed = static_cast<int64_t>(claimed->size());

  for (const auto& item : *claimed) {
    auto applied = apply(item);
    if (applied) {
      if (auto completed = store_.complete_outbox(item.id); !completed) {
        return completed.error();
      }
      ++stats.applied;
      continue;
    }

    const bool permanent =
        classify_attempt(false, applied.error().code, item.attempts, max_attempts_) ==
        OutboxDisposition::Failed;

    if (auto recorded =
            store_.fail_outbox(item.id, applied.error().message, permanent);
        !recorded) {
      return recorded.error();
    }

    if (permanent) {
      ++stats.failed;
    } else {
      ++stats.retrying;
    }
  }

  return stats;
}

}  // namespace mailengine
