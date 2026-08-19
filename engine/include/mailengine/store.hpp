/// @file store.hpp
/// @brief Postgres writer — the engine's only output.
///
/// This is the seam the entire architecture rests on. The engine writes rows
/// here and knows nothing about Zero; logical replication carries those rows
/// to zero-cache, which computes per-query diffs for connected clients. That
/// is why the SwiftUI app updates without the engine ever being aware it
/// exists.
///
/// ## Idempotency
///
/// Every row ID is a deterministic function of provider-side identifiers (see
/// `ids.hpp`), so re-fetching a message always produces the same primary key.
/// Every write is an upsert. A crash mid-backfill is therefore safe to resume:
/// re-processing a message is a no-op rather than a duplicate.

#pragma once

#include <cstdint>
#include <functional>
#include <memory>
#include <optional>
#include <string>
#include <vector>

#include "mailengine/gmail.hpp"
#include "mailengine/result.hpp"

namespace mailengine {

/// @brief Account identity as stored in Postgres.
struct StoredAccount {
  std::string id;
  std::string email_address;
  /// Empty when the mailbox has never been synced — the caller must backfill.
  std::string last_history_id;
};

/// @brief Owns a libpq connection and writes the mail schema.
///
/// Not thread-safe: one `PGconn` serves one thread. The ingest pool gives each
/// worker its own store.
class PostgresStore {
 public:
  PostgresStore();
  ~PostgresStore();
  PostgresStore(const PostgresStore&) = delete;
  PostgresStore& operator=(const PostgresStore&) = delete;

  /// @brief Connects using a libpq connection string.
  /// @param conninfo e.g. `postgres://user@localhost:5432/mailapp`
  [[nodiscard]] Result<void> connect(const std::string& conninfo);

  /// @brief Creates or updates the account row.
  /// @return The account as stored, including its sync watermark.
  [[nodiscard]] Result<StoredAccount> upsert_account(const std::string& account_id,
                                                     const std::string& email_address,
                                                     const std::string& color = "#4aa3a2");

  /// @brief Reads an account, or nullopt when it does not exist.
  [[nodiscard]] Result<std::optional<StoredAccount>> get_account(
      const std::string& account_id);

  /// @brief Replaces the account's label set.
  [[nodiscard]] Result<void> upsert_labels(const std::string& account_id,
                                           const std::vector<GmailLabel>& labels);

  /// @brief Writes one message and everything hanging off it.
  ///
  /// Performs, in a single transaction: the thread row, the message row, its
  /// body, its label links, and its attachment metadata. Labels are treated as
  /// authoritative — links absent from `message` are deleted, which is how an
  /// archive performed in the Gmail web UI propagates to us.
  ///
  /// @param write_body When false, skips `message_body`. Backfill runs
  ///        metadata-first so the UI is usable in seconds rather than after
  ///        the whole mailbox has downloaded.
  [[nodiscard]] Result<void> upsert_message(const std::string& account_id,
                                            const GmailMessage& message,
                                            bool write_body = true);

  /// @brief Recomputes a thread's denormalised aggregates from its messages.
  ///
  /// `message_count`, `unread_count`, `last_message_at`, `subject`, `snippet`
  /// and `participants` are all materialised on `thread` because ZQL has no
  /// aggregates. Recomputing from the messages is cheaper to reason about than
  /// maintaining every counter incrementally, and cannot drift.
  [[nodiscard]] Result<void> refresh_thread(const std::string& thread_id);

  /// @brief Removes a message and its dependents.
  [[nodiscard]] Result<void> delete_message(const std::string& account_id,
                                            const std::string& remote_message_id);

  /// @brief Removes an account and everything belonging to it.
  ///
  /// Every table that references `account` does so `ON DELETE CASCADE`, so this
  /// one statement clears the mailbox: threads, messages, bodies, labels,
  /// attachments and any queued outbox work. Deliberately irreversible — the
  /// point of disconnecting is that the mail is no longer on this machine.
  ///
  /// It does NOT touch the Keychain. The credential is the caller's to remove,
  /// and removing it first is what makes a half-finished disconnect safe: an
  /// account whose token is gone cannot sync, whereas rows deleted with a live
  /// token would simply come back on the next poll.
  [[nodiscard]] Result<void> delete_account(const std::string& account_id);

  /// @brief Advances the incremental-sync watermark.
  [[nodiscard]] Result<void> set_history_id(const std::string& account_id,
                                            const std::string& history_id);

  /// @brief Number of messages already stored, for resume and progress.
  [[nodiscard]] Result<int64_t> count_messages(const std::string& account_id);

  /// @brief True when this message is already stored.
  [[nodiscard]] Result<bool> has_message(const std::string& account_id,
                                         const std::string& remote_message_id);

  /// @brief One claimed outbox row.
  struct OutboxItem {
    std::string id;
    std::string op;       ///< matches the outbox_op enum
    std::string payload;  ///< raw JSONB
    int attempts = 0;
  };

  /// @brief Everything needed to download one attachment.
  struct PendingAttachment {
    std::string id;                    ///< attachment row id
    std::string remote_message_id;     ///< Gmail message id
    std::string remote_attachment_id;  ///< Gmail attachment id
    std::string filename;              ///< display name only, never a path
    std::string mime_type;
    int64_t size_bytes = 0;
    std::string content_hash;  ///< empty until downloaded
    std::string local_path;    ///< empty until downloaded
  };

  /// @brief Loads an attachment row and its message's Gmail id.
  ///
  /// The join is necessary because Gmail addresses attachments as
  /// `messages/{messageId}/attachments/{id}` — the attachment id alone is not
  /// addressable.
  [[nodiscard]] Result<PendingAttachment> attachment_for_download(
      const std::string& attachment_id);

  /// @brief Records a completed download.
  ///
  /// Writes the path but NOT the bytes: the blob lives in a content-addressed
  /// cache on disk, because everything in Postgres is replicated into
  /// zero-cache's SQLite replica and diffed on every sync.
  [[nodiscard]] Result<void> record_attachment_download(
      const std::string& attachment_id, const std::string& content_hash,
      const std::string& local_path, int64_t size_bytes);

  /// @brief Claims the single-daemon lock, or reports it already held.
  ///
  /// A Postgres session-level advisory lock: it is released automatically when
  /// the connection drops, including if the process is killed, so a crashed
  /// daemon never leaves the lock stuck. No file to clean up, no stale pid.
  ///
  /// Needed because the app now launches the daemon itself. Anyone who also
  /// runs one from a terminal would otherwise have two processes polling the
  /// same mailbox and draining the same outbox.
  [[nodiscard]] Result<bool> try_claim_daemon_lock();

  /// @brief Repoints stored attachment paths after the cache directory moves.
  ///
  /// `local_path` holds ABSOLUTE paths. Moving the cache without this leaves
  /// every downloaded attachment looking un-downloaded, and the app would
  /// quietly re-fetch hundreds of megabytes it already has on disk.
  ///
  /// @return How many rows were rewritten.
  [[nodiscard]] Result<int64_t> rewrite_attachment_paths(
      const std::string& old_prefix, const std::string& new_prefix);

  /// @brief Every connected account, in sidebar order.
  ///
  /// Disconnected accounts are excluded: `disconnected_at` marks an account
  /// the user removed, and syncing it would silently re-populate a mailbox
  /// they deliberately took away.
  [[nodiscard]] Result<std::vector<StoredAccount>> list_accounts();

  /// @brief Subscribes to a Postgres NOTIFY channel.
  ///
  /// The daemon otherwise learns about new work only when its poll interval
  /// elapses, which makes a click feel like it did nothing for up to that long.
  /// Downloading an attachment made that indefensible: the user is waiting.
  [[nodiscard]] Result<void> listen(const std::string& channel);

  /// @brief Blocks until a notification arrives or `timeout_ms` elapses.
  ///
  /// @return True if a notification arrived, false on timeout. Both are normal;
  ///         the timeout is what preserves periodic polling as a backstop, so a
  ///         missed NOTIFY delays work rather than losing it.
  [[nodiscard]] Result<bool> wait_for_notification(int timeout_ms);

  /// @brief Atomically claims up to `limit` pending operations.
  ///
  /// Uses `FOR UPDATE SKIP LOCKED`, so several drainers can run concurrently
  /// without ever handing the same row to two of them — and a drainer that
  /// dies mid-flight leaves its rows recoverable rather than locked forever.
  [[nodiscard]] Result<std::vector<OutboxItem>> claim_outbox(
      const std::string& account_id, int limit = 20);

  /// @brief Marks a claimed operation as applied.
  [[nodiscard]] Result<void> complete_outbox(const std::string& outbox_id);

  /// @brief Records a failure.
  /// @param permanent When true the row becomes `failed` and stops retrying;
  ///        otherwise it returns to `pending` for another attempt.
  [[nodiscard]] Result<void> fail_outbox(const std::string& outbox_id,
                                         const std::string& error,
                                         bool permanent);

  /// @brief Runs `fn` inside a transaction, rolling back if it fails.
  [[nodiscard]] Result<void> transaction(const std::function<Result<void>()>& fn);

  /// @brief Executes a statement with positional parameters.
  ///
  /// Parameters are always bound, never interpolated — libpq escapes them, so
  /// a subject line containing a quote cannot alter the statement.
  [[nodiscard]] Result<void> exec(const std::string& sql,
                                  const std::vector<std::string>& params = {});

  /// @brief Executes a statement and returns its rows as strings.
  [[nodiscard]] Result<std::vector<std::vector<std::string>>> query(
      const std::string& sql, const std::vector<std::string>& params = {});

 private:
  /// Opaque `PGconn*`, kept as void* so libpq-fe.h stays out of this header.
  void* conn_ = nullptr;
};

}  // namespace mailengine
