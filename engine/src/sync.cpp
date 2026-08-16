/// @file sync.cpp
/// @brief Backfill and incremental ingestion.

#include "mailengine/sync.hpp"

#include <set>
#include <utility>

#include "mailengine/ids.hpp"

namespace mailengine {

Syncer::Syncer(GmailClient& gmail, PostgresStore& store, std::string account_id,
               SearchIndex* search)
    : gmail_(gmail),
      store_(store),
      account_id_(std::move(account_id)),
      search_(search) {}

bool Syncer::needs_full_resync(const Error& error) {
  // Gmail returns 404 when startHistoryId predates its retention window.
  return error.code == 404;
}

bool Syncer::ingest_one(const std::string& remote_id, bool write_body,
                        SyncStats& stats, std::set<std::string>& threads) {
  auto message = gmail_.get_message(remote_id);
  if (!message) {
    ++stats.failed;
    return false;
  }
  ++stats.fetched;

  auto written = store_.upsert_message(account_id_, *message, write_body);
  if (!written) {
    ++stats.failed;
    return false;
  }

  // Index for search. A failure here is logged but not fatal: the index is
  // disposable and rebuildable from Postgres, so losing a document must never
  // cost us the message itself.
  if (search_ != nullptr) {
    (void)search_->index_message(account_id_,
                                 ids::thread(account_id_, message->thread_id),
                                 ids::message(account_id_, message->id), *message);
  }

  ++stats.written;
  // Thread aggregates are recomputed once per thread at the end rather than
  // after every message — a 40-message thread would otherwise be recomputed
  // 40 times.
  threads.insert(ids::thread(account_id_, message->thread_id));
  return true;
}

Result<SyncStats> Syncer::backfill(const std::string& query, int64_t max_messages,
                                   bool write_bodies, const ProgressFn& on_progress) {
  SyncStats stats;

  // 1. Identify the mailbox and capture the watermark FIRST. Anything that
  //    arrives during the backfill will then be picked up by the next
  //    incremental run rather than falling through the gap.
  auto profile = gmail_.get_profile();
  if (!profile) {
    return profile.error();
  }
  stats.history_id = profile->history_id;

  auto account = store_.upsert_account(account_id_, profile->email_address);
  if (!account) {
    return account.error();
  }

  // 2. Labels must exist before messages, because message_label references
  //    them and links to unknown labels are silently skipped.
  auto labels = gmail_.list_labels();
  if (!labels) {
    return labels.error();
  }
  if (auto written = store_.upsert_labels(account_id_, *labels); !written) {
    return written.error();
  }

  // 3. Page through message ids, fetching each in full.
  std::set<std::string> touched_threads;
  std::string page_token;
  const int64_t total_estimate =
      max_messages > 0 ? max_messages : profile->messages_total;

  do {
    auto page = gmail_.list_messages(page_token, query, 100);
    if (!page) {
      return page.error();
    }

    for (const auto& remote_id : page->message_ids) {
      if (max_messages > 0 && stats.written + stats.skipped >= max_messages) {
        break;
      }

      // Resume support: a message already stored is skipped without a fetch,
      // which is what makes restarting a partial backfill cheap.
      auto exists = store_.has_message(account_id_, remote_id);
      if (exists && *exists) {
        ++stats.skipped;
        continue;
      }

      (void)ingest_one(remote_id, write_bodies, stats, touched_threads);

      if (on_progress) {
        on_progress(stats.written + stats.skipped, total_estimate);
      }
    }

    page_token = page->next_page_token;
    if (max_messages > 0 && stats.written + stats.skipped >= max_messages) {
      break;
    }
  } while (!page_token.empty());

  // 4. Recompute thread aggregates once per touched thread.
  for (const auto& thread_id : touched_threads) {
    (void)store_.refresh_thread(thread_id);
  }

  // 5. Only now advance the watermark. Setting it earlier would mean a crash
  //    mid-backfill left us believing we were caught up.
  if (auto written = store_.set_history_id(account_id_, stats.history_id); !written) {
    return written.error();
  }

  return stats;
}

Result<SyncStats> Syncer::incremental() {
  SyncStats stats;

  auto account = store_.get_account(account_id_);
  if (!account) {
    return account.error();
  }
  if (!account->has_value()) {
    return make_error("account " + account_id_ + " not in postgres; backfill first");
  }
  const std::string start = (*account)->last_history_id;
  if (start.empty()) {
    return make_error("no history watermark; backfill first");
  }

  std::set<std::string> touched_threads;
  std::set<std::string> changed_messages;
  std::string page_token;
  std::string newest_history_id = start;

  do {
    auto page = gmail_.list_history(start, page_token);
    if (!page) {
      // 404 here means the watermark aged out of Gmail's ~1 week window.
      return page.error();
    }
    if (!page->history_id.empty()) {
      newest_history_id = page->history_id;
    }

    for (const auto& change : page->changes) {
      if (change.message_id.empty()) continue;

      if (change.kind == HistoryChange::Kind::MessageDeleted) {
        if (auto deleted = store_.delete_message(account_id_, change.message_id);
            deleted) {
          ++stats.deleted;
        }
        if (search_ != nullptr) {
          (void)search_->remove_message(ids::message(account_id_, change.message_id));
        }
        if (!change.thread_id.empty()) {
          touched_threads.insert(ids::thread(account_id_, change.thread_id));
        }
        continue;
      }

      // Added messages and label changes both resolve to "re-fetch this
      // message and upsert it". Gmail's labelIds on a full fetch are
      // authoritative, so applying the delta by hand would add risk for no
      // benefit — and messages.get is only 5 quota units.
      changed_messages.insert(change.message_id);
    }

    page_token = page->next_page_token;
  } while (!page_token.empty());

  for (const auto& remote_id : changed_messages) {
    (void)ingest_one(remote_id, /*write_body=*/true, stats, touched_threads);
  }

  for (const auto& thread_id : touched_threads) {
    (void)store_.refresh_thread(thread_id);
  }

  if (auto written = store_.set_history_id(account_id_, newest_history_id); !written) {
    return written.error();
  }
  stats.history_id = newest_history_id;

  return stats;
}

}  // namespace mailengine
