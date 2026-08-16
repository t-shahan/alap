/// @file outbox.hpp
/// @brief Drains the transactional outbox into the Gmail API.
///
/// ## Why this exists
///
/// Zero mutators must never perform network I/O — they are fast, local,
/// transactional Postgres operations. So archiving a thread writes two things
/// in ONE transaction: the label change the user sees, and a row in `outbox`
/// recording the remote intent.
///
/// This drainer is the other half. It claims pending rows, calls Gmail, and
/// marks them done. That split is what makes optimistic UI honest rather than
/// a lie: the interface updates within a frame, and the remote effect is
/// durable, retryable and idempotent even across a crash.
///
/// ## Failure semantics
///
/// A transient failure returns the row to `pending` for another attempt. A
/// permanent one marks it `failed`, which surfaces in the app through the
/// `outbox.unresolved` query — so an archive that can never be applied is
/// visible to the user rather than silently lost.

#pragma once

#include <cstdint>
#include <string>

#include "mailengine/gmail.hpp"
#include "mailengine/result.hpp"
#include "mailengine/store.hpp"

namespace mailengine {

/// @brief Outcome of one drain pass.
struct DrainStats {
  int64_t claimed = 0;
  int64_t applied = 0;
  int64_t retrying = 0;  ///< transient failures, returned to pending
  int64_t failed = 0;    ///< permanent failures, now visible in the UI
};

/// @brief What should happen to a claimed row after an attempt.
enum class OutboxDisposition {
  Applied,  ///< succeeded; mark done
  Retry,    ///< transient; return to pending for another attempt
  Failed,   ///< permanent; mark failed and surface in the UI
};

/// @brief Decides a row's fate after an attempt.
///
/// Pure, so the branch table can be tested exhaustively. The important call:
/// a 4xx below 429 means Gmail rejected the request itself — a bad label id, a
/// deleted message, an unimplemented op — and retrying cannot help. Failing
/// immediately keeps a genuine bug from hiding behind five silent retries.
///
/// @param error_code 0 when the attempt succeeded.
[[nodiscard]] OutboxDisposition classify_attempt(bool succeeded, int error_code,
                                                 int attempts, int max_attempts);

/// @brief Applies queued local mutations to Gmail.
class OutboxDrainer {
 public:
  /// @param max_attempts Attempts before a row is considered permanently
  ///        failed. Five with exponential backoff spans a few minutes, which
  ///        comfortably covers a transient network outage.
  OutboxDrainer(LabelWriter& gmail, PostgresStore& store, std::string account_id,
                int max_attempts = 5);

  /// @brief Claims and applies up to `limit` pending operations.
  ///
  /// Safe to run concurrently with other drainers: claiming uses
  /// `FOR UPDATE SKIP LOCKED`, so no two ever take the same row.
  [[nodiscard]] Result<DrainStats> drain_once(int limit = 20);

  /// @brief Executes one claimed operation against the API.
  ///
  /// Public so it can be tested directly; `drain_once` additionally requires a
  /// live Postgres, whereas this needs only a `LabelWriter`.
  [[nodiscard]] Result<void> apply(const PostgresStore::OutboxItem& item);

 private:
  LabelWriter& gmail_;
  PostgresStore& store_;
  std::string account_id_;
  int max_attempts_;
};

}  // namespace mailengine
