/// @file sync.hpp
/// @brief The two ingest loops: full backfill and incremental catch-up.

#pragma once

#include <cstdint>
#include <functional>
#include <set>
#include <string>

#include "mailengine/gmail.hpp"
#include "mailengine/result.hpp"
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
  Syncer(GmailClient& gmail, PostgresStore& store, std::string account_id);

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
  [[nodiscard]] Result<SyncStats> backfill(const std::string& query = {},
                                           int64_t max_messages = 0,
                                           bool write_bodies = true,
                                           const ProgressFn& on_progress = {});

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

  /// Fetches, parses and stores one message. Returns false on failure.
  [[nodiscard]] bool ingest_one(const std::string& remote_id, bool write_body,
                                SyncStats& stats, std::set<std::string>& threads);
};

}  // namespace mailengine
