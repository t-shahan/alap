/// @file sync.hpp
/// @brief The two ingest loops: full backfill and incremental catch-up.

#pragma once

#include <cstdint>
#include <functional>
#include <set>
#include <string>

#include "mailengine/gmail.hpp"
#include "mailengine/result.hpp"
#include "mailengine/search.hpp"
#include "mailengine/store.hpp"

namespace mailengine {

/// @brief Outcome of a sync run.
struct SyncStats {
  int64_t fetched = 0;
  int64_t written = 0;
  int64_t skipped = 0;   ///< already present — a resumed backfill
  int64_t deleted = 0;
  int64_t failed = 0;
  std::string history_id;  ///< watermark to resume from next time
};

/// @brief Progress callback: (processed, total_estimate).
using ProgressFn = std::function<void(int64_t, int64_t)>;

/// @brief Drives Gmail → Postgres ingestion.
///
/// Nothing here knows about Zero. Rows land in Postgres and logical
/// replication carries them the rest of the way.
class Syncer {
 public:
  /// @param search Optional FTS5 index, updated as messages are ingested.
  ///        Passing nullptr skips indexing — useful when rebuilding Postgres
  ///        without touching search, or vice versa.
  Syncer(GmailClient& gmail, PostgresStore& store, std::string account_id,
         SearchIndex* search = nullptr);

  /// @brief Full backfill.
  ///
  /// Resumable by construction: every ID is derived from Gmail's identifiers
  /// and every write is an upsert, so a message already stored is skipped and
  /// a crash costs only the messages in flight.
  ///
  /// The history watermark is captured BEFORE listing begins. A backfill of a
  /// large mailbox takes minutes, and mail arriving during it would otherwise
  /// fall into the gap between "listed" and "watermark set" and never sync.
  ///
  /// @param query Gmail search syntax to limit scope, e.g. `newer_than:30d`.
  ///        Empty means the whole mailbox.
  /// @param max_messages Stop after this many. 0 means no limit.
  /// @param write_bodies When false, only metadata is stored — the list view
  ///        becomes usable long before every body has downloaded.
  /// @param fetch_workers How many messages to fetch concurrently.
  ///
  ///        This is the single biggest lever on backfill time. Each
  ///        `messages.get` is a ~150ms network round trip, so serial fetching
  ///        runs at roughly 6 messages/sec regardless of how fast anything
  ///        else is — 80 minutes for a 31k mailbox while using about an eighth
  ///        of the available quota.
  ///
  ///        Measured against a real mailbox, 300 messages each:
  ///
  ///          1 worker    52.4s    5.7 msg/s
  ///          8 workers    8.4s   35.5 msg/s
  ///         16 workers    5.6s   53.8 msg/s
  ///         24 workers    4.7s   64.0 msg/s   (no failures)
  ///
  ///        16 is the default: near the top of the curve while leaving room
  ///        for the rate-limit retry path and for a poll loop running
  ///        alongside. Higher still works — 429s are retried with backoff — but
  ///        returns flatten.
  ///
  ///        Only the NETWORK is parallel. Postgres writes stay on the calling
  ///        thread, which keeps transaction and ordering logic single-threaded
  ///        and needs no extra connections.
  [[nodiscard]] Result<SyncStats> backfill(const std::string& query = {},
                                           int64_t max_messages = 0,
                                           bool write_bodies = true,
                                           const ProgressFn& on_progress = {},
                                           int fetch_workers = 16);

  /// @brief Applies everything that changed since the stored watermark.
  ///
  /// This is the mechanism that makes refresh fast: one `history.list` call
  /// costing 2 quota units, instead of re-listing tens of thousands of
  /// messages.
  ///
  /// Gmail retains roughly a week of history. When the watermark has aged out
  /// the API returns 404, and the caller must fall back to `backfill`.
  [[nodiscard]] Result<SyncStats> incremental();

  /// @brief True when `incremental` failed because the watermark expired.
  [[nodiscard]] static bool needs_full_resync(const Error& error);

 private:
  GmailClient& gmail_;
  PostgresStore& store_;
  std::string account_id_;
  SearchIndex* search_;

  /// Fetches, parses and stores one message. Returns false on failure.
  [[nodiscard]] bool ingest_one(const std::string& remote_id, bool write_body,
                                SyncStats& stats, std::set<std::string>& threads);
};

}  // namespace mailengine
