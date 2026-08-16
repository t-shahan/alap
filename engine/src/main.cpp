/// @file main.cpp
/// @brief Entry point for the `mailengined` daemon and its setup commands.
///
/// Subcommands:
///   auth <account-id>    Run the interactive OAuth flow and store the refresh
///                        token in the Keychain.
///   token <account-id>   Mint a fresh access token (verifies stored refresh).
///   version
///
/// The sync loops themselves land in the next module.

#include <cstdlib>
#include <iostream>
#include <algorithm>
#include <array>
#include "mailengine/crypto.hpp"
#include <nlohmann/json.hpp>
#include <chrono>
#include <filesystem>
#include <iomanip>
#include <optional>
#include <atomic>
#include <map>
#include <memory>
#include <mutex>
#include <sstream>
#include <thread>
#include <string>

#include "mailengine/attachments.hpp"
#include "mailengine/gmail.hpp"
#include "mailengine/html.hpp"
#include "mailengine/keychain.hpp"
#include "mailengine/oauth.hpp"
#include "mailengine/outbox.hpp"
#include "mailengine/bench.hpp"
#include "mailengine/search.hpp"
#include "mailengine/store.hpp"
#include "mailengine/sync.hpp"
#include "mailengine/version.hpp"

namespace {

/// Reads an environment variable, returning empty when unset.
std::string env(const char* name) {
  const char* value = std::getenv(name);
  return value != nullptr ? std::string(value) : std::string{};
}

mailengine::OAuthConfig config_from_env() {
  return mailengine::OAuthConfig{
      .client_id = env("GOOGLE_CLIENT_ID"),
      .client_secret = env("GOOGLE_CLIENT_SECRET"),
  };
}

int usage() {
  std::cerr << "usage: mailengined <command>\n\n"
               "  connect [max]         authorize a NEW mailbox, register it and backfill\n"
               "                        (emits JSON progress; this is what the app spawns)\n"
               "  auth <account-id>     re-authorize an EXISTING account id\n"
               "  token <account-id>    mint an access token from the stored refresh token\n"
               "  profile <account-id>  show mailbox profile and history watermark\n"
               "  labels <account-id>   list Gmail labels\n"
               "  peek <account-id> [n] fetch and print the newest n messages\n"
               "  check <account-id> [n] parse-health report over n messages (no content)\n"
               "  sync <account-id> [query] [max] [workers]  backfill into Postgres\n"
               "  poll <account-id>     apply changes since the stored watermark\n"
               "  drain <account-id>    push queued local changes to Gmail\n"
               "  daemon [seconds]      supervise every connected account\n"
               "  search <account-id> <query>    full-text search the local index\n"
               "  reindex <account-id>  rebuild the search index from Postgres\n"
               "  resanitize <account-id>  sanitize HTML bodies stored before sanitising existed\n"
               "  bench-search [counts...]  measure search latency at scale\n"
               "  version\n";
  return 64;  // EX_USAGE
}


int cmd_profile(const std::string& account_id) {
  auto tokens = mailengine::TokenProvider(config_from_env(), account_id);
  mailengine::GmailClient gmail(tokens);

  auto profile = gmail.get_profile();
  if (!profile) {
    std::cerr << "error: " << profile.error().message << "\n";
    return 1;
  }
  std::cout << "  address    " << profile->email_address << "\n"
            << "  messages   " << profile->messages_total << "\n"
            << "  historyId  " << profile->history_id << "\n";
  return 0;
}

int cmd_labels(const std::string& account_id) {
  auto tokens = mailengine::TokenProvider(config_from_env(), account_id);
  mailengine::GmailClient gmail(tokens);

  auto labels = gmail.list_labels();
  if (!labels) {
    std::cerr << "error: " << labels.error().message << "\n";
    return 1;
  }
  std::cout << labels->size() << " labels\n";
  for (const auto& label : *labels) {
    std::cout << "  " << (label.type == "system" ? "[sys] " : "      ") << label.name
              << "  (" << label.id << ")\n";
  }
  return 0;
}

int cmd_peek(const std::string& account_id, int count) {
  auto tokens = mailengine::TokenProvider(config_from_env(), account_id);
  mailengine::GmailClient gmail(tokens);

  auto page = gmail.list_messages({}, "in:inbox", count);
  if (!page) {
    std::cerr << "error: " << page.error().message << "\n";
    return 1;
  }

  std::cout << "newest " << page->message_ids.size() << " inbox messages\n\n";
  for (const auto& id : page->message_ids) {
    auto message = gmail.get_message(id);
    if (!message) {
      std::cerr << "  ! " << id << ": " << message.error().message << "\n";
      continue;
    }
    const std::string who =
        message->from.name.empty() ? message->from.email : message->from.name;
    std::cout << (message->is_unread() ? "  * " : "    ") << who << "\n"
              << "      " << message->subject << "\n"
              << "      " << message->snippet.substr(0, 78) << "\n";
    if (!message->attachments.empty()) {
      std::cout << "      " << message->attachments.size() << " attachment(s)\n";
    }
    std::cout << "\n";
  }
  return 0;
}

/// Fetches a sample of real mail and reports parse health in aggregate.
///
/// Prints NO message content — only counts. Real inboxes are a far harsher
/// test of the MIME decoder than any fixture, and building the ingest pipeline
/// on a parser that silently drops bodies would be a bad trade.
int cmd_check(const std::string& account_id, int count) {
  auto tokens = mailengine::TokenProvider(config_from_env(), account_id);
  mailengine::GmailClient gmail(tokens);

  auto page = gmail.list_messages({}, {}, count);
  if (!page) {
    std::cerr << "error: " << page.error().message << "\n";
    return 1;
  }

  int parsed = 0, failed = 0;
  int undecoded_words = 0, non_ascii_subjects = 0, empty_subjects = 0;
  int no_body = 0, html_only = 0, text_only = 0, both_bodies = 0;
  int with_attachments = 0, inline_images = 0;
  int missing_from_name = 0, missing_rfc_id = 0;

  for (const auto& id : page->message_ids) {
    auto message = gmail.get_message(id);
    if (!message) {
      ++failed;
      std::cerr << "  ! parse failed: " << message.error().message << "\n";
      continue;
    }
    ++parsed;

    // A surviving "=?" means an encoded-word the decoder did not handle —
    // it would render as gibberish in the UI.
    if (message->subject.find("=?") != std::string::npos) ++undecoded_words;
    if (message->subject.empty()) ++empty_subjects;
    for (const unsigned char c : message->subject) {
      if (c > 127) { ++non_ascii_subjects; break; }
    }

    const bool has_text = !message->text_body.empty();
    const bool has_html = !message->html_body.empty();
    if (!has_text && !has_html) ++no_body;
    else if (has_text && has_html) ++both_bodies;
    else if (has_html) ++html_only;
    else ++text_only;

    if (!message->attachments.empty()) ++with_attachments;
    for (const auto& attachment : message->attachments) {
      if (attachment.is_inline) { ++inline_images; break; }
    }

    if (message->from.name.empty()) ++missing_from_name;
    if (message->rfc822_message_id.empty()) ++missing_rfc_id;
  }

  std::cout << "\n  sampled            " << page->message_ids.size() << "\n"
            << "  parsed             " << parsed << "\n"
            << "  parse failures     " << failed
            << (failed ? "   <-- investigate" : "") << "\n"
            << "\n  subjects\n"
            << "    non-ASCII        " << non_ascii_subjects
            << "   (decoder exercised)\n"
            << "    undecoded =?..?= " << undecoded_words
            << (undecoded_words ? "   <-- DECODER BUG" : "   ok") << "\n"
            << "    empty            " << empty_subjects << "\n"
            << "\n  bodies\n"
            << "    text + html      " << both_bodies << "\n"
            << "    html only        " << html_only << "\n"
            << "    text only        " << text_only << "\n"
            << "    NO body          " << no_body
            << (no_body ? "   <-- investigate" : "   ok") << "\n"
            << "\n  other\n"
            << "    with attachments " << with_attachments << "\n"
            << "    inline images    " << inline_images << "\n"
            << "    no sender name   " << missing_from_name << "\n"
            << "    no Message-ID    " << missing_rfc_id << "\n\n";
  return 0;
}

/// Path to the FTS5 index.
///
/// Application Support rather than the project directory, because the Swift
/// app reads this same file and must be able to find it regardless of its
/// working directory. Both sides compute the identical path.
std::string search_index_path() {
  const std::string configured = env("MAILENGINE_SEARCH_DB");
  if (!configured.empty()) return configured;

  const std::string home = env("HOME");
  const std::string dir = home + "/Library/Application Support/dev.local.mailapp";
  std::filesystem::create_directories(dir);
  return dir + "/search.db";
}

/// Opens the search index, reporting failure but not aborting: the index is
/// disposable, and sync is more important than search.
bool open_search(mailengine::SearchIndex& index) {
  if (auto opened = index.open(search_index_path()); !opened) {
    std::cerr << "warning: search index unavailable: " << opened.error().message
              << "\n";
    return false;
  }
  return true;
}

int cmd_search(const std::string& account_id, const std::string& query) {
  (void)account_id;
  mailengine::SearchIndex index;
  if (!open_search(index)) return 1;

  const auto began = std::chrono::steady_clock::now();
  auto found = index.search_fuzzy(query, 20);
  const auto elapsed = std::chrono::duration<double, std::milli>(
                           std::chrono::steady_clock::now() - began)
                           .count();
  if (!found) {
    std::cerr << "error: " << found.error().message << "\n";
    return 1;
  }

  std::cout << found->hits.size() << " thread(s) for \"" << query << "\"";
  if (found->corrected) {
    std::cout << "  -> showing results for \"" << found->corrected_query << "\"";
  }
  std::cout << "  (" << std::fixed << std::setprecision(2) << elapsed
            << " ms, index holds " << index.count().value_or(0) << " messages)\n\n";

  for (const auto& hit : found->hits) {
    std::cout << "  " << hit.subject << "\n      " << hit.thread_id << "\n";
  }
  return 0;
}

/// Rebuilds the FTS5 index from Postgres.
///
/// The index is disposable by design — deleting the file and running this is
/// always safe, and it is the only way to index a mailbox that was synced
/// before search existed.
int cmd_reindex(const std::string& account_id);

/// Connects to Postgres using ZERO_UPSTREAM_DB.
bool connect_store(mailengine::PostgresStore& store) {
  const std::string conninfo = env("ZERO_UPSTREAM_DB");
  if (conninfo.empty()) {
    std::cerr << "error: ZERO_UPSTREAM_DB is not set (source .env)\n";
    return false;
  }
  if (auto connected = store.connect(conninfo); !connected) {
    std::cerr << "error: " << connected.error().message << "\n";
    return false;
  }
  return true;
}

void print_stats(const mailengine::SyncStats& stats) {
  std::cout << "\n  fetched   " << stats.fetched << "\n"
            << "  written   " << stats.written << "\n"
            << "  skipped   " << stats.skipped << "  (already stored)\n"
            << "  deleted   " << stats.deleted << "\n"
            << "  failed    " << stats.failed << "\n"
            << "  historyId " << stats.history_id << "\n\n";
}

int cmd_sync(const std::string& account_id, const std::string& query, int64_t max,
             int workers) {
  auto tokens = mailengine::TokenProvider(config_from_env(), account_id);
  mailengine::GmailClient gmail(tokens);
  mailengine::PostgresStore store;
  if (!connect_store(store)) return 1;

  mailengine::SearchIndex index;
  const bool indexing = open_search(index);
  mailengine::Syncer syncer(gmail, store, account_id, indexing ? &index : nullptr);

  std::cout << "backfilling " << account_id;
  if (!query.empty()) std::cout << "  query=\"" << query << "\"";
  if (max > 0) std::cout << "  max=" << max;
  std::cout << "  workers=" << workers << "\n";

  int64_t last_shown = 0;
  const auto began = std::chrono::steady_clock::now();
  auto stats = syncer.backfill(
      query, max, true,
      [&](int64_t done, int64_t total) {
        if (done - last_shown >= 25 || done == total) {
          last_shown = done;
          const double seconds = std::chrono::duration<double>(
                                     std::chrono::steady_clock::now() - began)
                                     .count();
          const double rate = seconds > 0 ? done / seconds : 0;
          std::cout << "\r  " << done << " / " << total << "   " << std::fixed
                    << std::setprecision(1) << rate << " msg/s" << std::flush;
        }
      },
      workers);
  std::cout << "\n";

  if (!stats) {
    std::cerr << "error: " << stats.error().message << "\n";
    return 1;
  }
  print_stats(*stats);
  return 0;
}

int cmd_poll(const std::string& account_id) {
  auto tokens = mailengine::TokenProvider(config_from_env(), account_id);
  mailengine::GmailClient gmail(tokens);
  mailengine::PostgresStore store;
  if (!connect_store(store)) return 1;

  mailengine::SearchIndex index;
  const bool indexing = open_search(index);
  mailengine::Syncer syncer(gmail, store, account_id, indexing ? &index : nullptr);
  auto stats = syncer.incremental();
  if (!stats) {
    if (mailengine::Syncer::needs_full_resync(stats.error())) {
      std::cerr << "watermark expired; run `mailengined sync " << account_id << "`\n";
      return 2;
    }
    std::cerr << "error: " << stats.error().message << "\n";
    return 1;
  }
  print_stats(*stats);
  return 0;
}

int cmd_drain(const std::string& account_id) {
  auto tokens = mailengine::TokenProvider(config_from_env(), account_id);
  mailengine::GmailClient gmail(tokens);
  mailengine::PostgresStore store;
  if (!connect_store(store)) return 1;

  const mailengine::AttachmentStore blobs{mailengine::AttachmentStore::default_root()};
  mailengine::OutboxDrainer drainer(gmail, store, account_id, 5,
                                    {.sender = &gmail,
                                     .attachments = &gmail,
                                     .blobs = &blobs});
  auto stats = drainer.drain_once();
  if (!stats) {
    std::cerr << "error: " << stats.error().message << "\n";
    return 1;
  }
  std::cout << "  claimed  " << stats->claimed << "\n"
            << "  applied  " << stats->applied << "\n"
            << "  retrying " << stats->retrying << "\n"
            << "  failed   " << stats->failed
            << (stats->failed ? "   <-- visible in the app" : "") << "\n";
  return 0;
}

/// Runs both loops forever.
///
/// The outbox is drained BEFORE polling, so a change the user just made
/// reaches Gmail before we ask Gmail what changed. Reversing the order would
/// briefly show the pre-mutation state coming back from the server.
/// A per-account output stream that never interleaves with another worker's.
///
/// Several threads writing to std::cout shear their lines together — a
/// half-written "sync: 12 written" ends up spliced into another account's
/// line, and the log becomes unreadable exactly when something has gone wrong
/// and you need to read it.
///
/// Buffers until a newline, then takes the mutex and emits the whole line at
/// once, prefixed with the account it came from.
class LabelledStream : public std::ostream {
 public:
  LabelledStream(std::mutex& mutex, std::string label)
      : std::ostream(&buffer_), buffer_(mutex, std::move(label)) {
    // Without unitbuf, sync() runs only when the buffer is destroyed — and the
    // account loops never return, so nothing would ever be printed. Flushing
    // per insertion is fine because sync() holds back partial lines.
    setf(std::ios::unitbuf);
  }

 private:
  class Buffer : public std::stringbuf {
   public:
    Buffer(std::mutex& mutex, std::string label)
        : mutex_(mutex), label_(std::move(label)) {}

    int sync() override {
      const std::string text = str();
      // Emit only through the last newline. A line assembled from several <<
      // operations must not be torn apart and labelled twice, so anything
      // after the final newline stays buffered until its newline arrives.
      const size_t last = text.rfind('\n');
      if (last == std::string::npos) {
        return 0;
      }

      {
        const std::lock_guard<std::mutex> guard(mutex_);
        // Prefix every line, not just the first: a multi-line burst from one
        // account is otherwise indistinguishable from another account's.
        size_t start = 0;
        while (start <= last) {
          const size_t newline = text.find('\n', start);
          std::cout << "[" << label_ << "] "
                    << text.substr(start, newline - start) << "\n";
          start = newline + 1;
        }
        std::cout.flush();
      }

      str(text.substr(last + 1));
      // Keep writing at the end of the retained remainder.
      pubseekoff(0, std::ios::end, std::ios::out);
      return 0;
    }

   private:
    std::mutex& mutex_;
    std::string label_;
  };

  Buffer buffer_;
};

/// Runs one account's sync and outbox loops until the process ends.
///
/// Each account gets its own thread, and therefore its own PGconn, GmailClient
/// and curl handle — `PostgresStore` is explicitly one connection per thread,
/// and a CURL* may only be used by one thread at a time. Sharing either would
/// be a data race rather than a slowdown.
///
/// The alternative, round-robin over accounts in a single loop, means one
/// account with a slow backfill stalls every other account's mail.
int run_account_loop(const std::string& account_id, int interval_seconds,
                     std::ostream& out, const std::atomic<bool>& running) {
  auto tokens = mailengine::TokenProvider(config_from_env(), account_id);
  mailengine::GmailClient gmail(tokens);
  mailengine::PostgresStore store;
  if (!connect_store(store)) return 1;

  mailengine::SearchIndex index;
  const bool indexing = open_search(index);
  mailengine::Syncer syncer(gmail, store, account_id, indexing ? &index : nullptr);
  const mailengine::AttachmentStore blobs{mailengine::AttachmentStore::default_root()};
  mailengine::OutboxDrainer drainer(gmail, store, account_id, 5,
                                    {.sender = &gmail,
                                     .attachments = &gmail,
                                     .blobs = &blobs});

  // Subscribe before the first drain, so a row committed while we were still
  // starting up cannot slip through the gap between the two.
  const bool live = store.listen("outbox").has_value();
  if (!live) {
    out << "warning: NOTIFY unavailable; falling back to polling only\n";
  }

  out << "daemon started for " << account_id << "  (poll every "
            << interval_seconds << "s"
            << (live ? ", waking instantly on new work" : "")
            << ", Ctrl-C to stop)\n";

  // Gmail is only polled on the timer. A NOTIFY means one of OUR rows is
  // waiting, and asking Gmail what changed would not help — it would just burn
  // quota on every click.
  auto next_poll = std::chrono::steady_clock::now();

  while (running.load()) {
    if (auto drained = drainer.drain_once(); drained) {
      if (drained->applied > 0 || drained->failed > 0) {
        out << "  outbox: applied " << drained->applied << ", failed "
                  << drained->failed << "\n";
      }
    } else {
      out << "  outbox error: " << drained.error().message << "\n";
    }

    const auto now = std::chrono::steady_clock::now();
    if (now >= next_poll) {
      next_poll = now + std::chrono::seconds(interval_seconds);

      if (auto polled = syncer.incremental(); polled) {
        if (polled->written > 0 || polled->deleted > 0) {
          out << "  sync: " << polled->written << " written, "
                    << polled->deleted << " deleted\n";
        }
      } else if (mailengine::Syncer::needs_full_resync(polled.error())) {
        out << "  watermark expired; run `mailengined sync " << account_id
                  << "`\n";
        return 2;
      } else {
        out << "  sync error: " << polled.error().message << "\n";
      }
    }

    // Sleep until either a NOTIFY arrives or the next Gmail poll is due,
    // whichever comes first. The timeout is what keeps this a backstop rather
    // than a dependency: a dropped notification costs latency, never work.
    const auto remaining = std::chrono::duration_cast<std::chrono::milliseconds>(
        next_poll - std::chrono::steady_clock::now());
    const int timeout_ms =
        static_cast<int>(std::max<int64_t>(remaining.count(), 0));

    if (!live) {
      std::this_thread::sleep_for(std::chrono::milliseconds(timeout_ms));
      continue;
    }

    if (auto woke = store.wait_for_notification(timeout_ms); !woke) {
      out << "  notify error: " << woke.error().message << "\n";
      // Do not spin on a broken connection.
      std::this_thread::sleep_for(std::chrono::seconds(1));
    }
  }
}

int cmd_reindex(const std::string& account_id) {
  mailengine::PostgresStore store;
  if (!connect_store(store)) return 1;

  mailengine::SearchIndex index;
  if (!open_search(index)) return 1;
  // Only THIS account's documents. The index is shared by every mailbox, and
  // clearing all of it here used to be harmless when there was one account —
  // with two, reindexing one silently emptied search for the other.
  if (auto cleared = index.clear_account(account_id); !cleared) {
    std::cerr << "error: " << cleared.error().message << "\n";
    return 1;
  }

  auto rows = store.query(
      R"(SELECT m.id, m.thread_id, m.subject, m.from_name, m.from_email,
                COALESCE(b.text_body, m.snippet),
                (EXTRACT(EPOCH FROM m.sent_at) * 1000)::bigint
         FROM message m
         LEFT JOIN message_body b ON b.message_id = m.id
         WHERE m.account_id = $1)",
      {account_id});
  if (!rows) {
    std::cerr << "error: " << rows.error().message << "\n";
    return 1;
  }

  if (auto begun = index.begin_batch(); !begun) {
    std::cerr << "error: " << begun.error().message << "\n";
    return 1;
  }

  int64_t indexed = 0;
  for (const auto& row : *rows) {
    if (row.size() < 7) continue;
    // The timestamp becomes the FTS rowid, which is what makes recency-ordered
    // search early-terminating. Omitting it silently degrades every query.
    const int64_t sent_at_ms = row[6].empty() ? 0 : std::stoll(row[6]);
    if (index
            .index_document(account_id, row[1], row[0], row[2],
                            row[3] + " " + row[4], row[5], sent_at_ms)
            .has_value()) {
      ++indexed;
    }
  }

  if (auto committed = index.commit_batch(); !committed) {
    std::cerr << "error: " << committed.error().message << "\n";
    return 1;
  }

  std::cout << "  indexed " << indexed << " messages\n";
  return 0;
}

/// Measures search latency across corpus sizes.
///
/// Each size gets a throwaway on-disk index, because :memory: would understate
/// real latency — the production index is a file and pays page-cache costs.
int cmd_bench_search(const std::vector<int64_t>& sizes) {
  const auto queries = mailengine::bench::sample_queries();
  std::cout << "\n  " << queries.size() << " query shapes x 20 repetitions each\n\n";

  for (const int64_t size : sizes) {
    const std::string path = "/tmp/mailengine_bench_" + std::to_string(size) + ".db";
    std::filesystem::remove(path);
    std::filesystem::remove(path + "-wal");
    std::filesystem::remove(path + "-shm");

    mailengine::SearchIndex index;
    if (auto opened = index.open(path); !opened) {
      std::cerr << "error: " << opened.error().message << "\n";
      return 1;
    }

    const auto build_began = std::chrono::steady_clock::now();
    if (auto filled = mailengine::bench::populate(index, size); !filled) {
      std::cerr << "error: " << filled.error().message << "\n";
      return 1;
    }
    const auto build_ms = std::chrono::duration<double, std::milli>(
                              std::chrono::steady_clock::now() - build_began)
                              .count();

    const auto recency = mailengine::bench::measure(index, queries, 20,
                                                   mailengine::SearchOrder::Recency);
    const auto relevance = mailengine::bench::measure(index, queries, 20,
                                                     mailengine::SearchOrder::Relevance);
    mailengine::bench::print(std::to_string(size) + " recency", recency);
    mailengine::bench::print(std::to_string(size) + " relevance", relevance);

    std::error_code ec;
    const auto bytes = std::filesystem::file_size(path, ec);
    std::cout << "                         index " << (ec ? 0 : bytes / 1024 / 1024)
              << " MB, built in " << static_cast<int64_t>(build_ms) << " ms, "
              << recency.total_hits / std::max<int64_t>(recency.queries, 1)
              << " hits/query avg\n";

    std::filesystem::remove(path);
    std::filesystem::remove(path + "-wal");
    std::filesystem::remove(path + "-shm");
  }
  std::cout << "\n";
  return 0;
}

/// Sanitises HTML bodies already in Postgres.
///
/// Everything ingested before the sanitiser existed is stored raw. The schema
/// says otherwise, so this brings existing rows in line with the guarantee.
int cmd_resanitize(const std::string& account_id) {
  mailengine::PostgresStore store;
  if (!connect_store(store)) return 1;

  auto rows = store.query(
      R"(SELECT b.message_id, b.html_body
         FROM message_body b
         WHERE b.account_id = $1 AND b.html_body IS NOT NULL AND b.html_body <> '')",
      {account_id});
  if (!rows) {
    std::cerr << "error: " << rows.error().message << "\n";
    return 1;
  }

  int64_t changed = 0;
  int64_t blocked_images = 0;
  int64_t with_active_content = 0;

  for (const auto& row : *rows) {
    if (row.size() < 2) continue;
    const auto sanitised = mailengine::html::sanitize(row[1]);
    blocked_images += sanitised.blocked_remote_images;
    if (sanitised.removed_active_content) ++with_active_content;
    if (sanitised.html == row[1]) continue;

    if (store.exec("UPDATE message_body SET html_body = $2 WHERE message_id = $1",
                   {row[0], sanitised.html})
            .has_value()) {
      ++changed;
    }
  }

  std::cout << "  examined  " << rows->size() << "\n"
            << "  rewritten " << changed << "\n"
            << "  messages carrying active content " << with_active_content << "\n"
            << "  remote images blocked " << blocked_images << "\n";
  return 0;
}

int cmd_auth(const std::string& account_id) {
  const mailengine::OAuthClient client(config_from_env());

  std::cout << "Opening your browser to authorize " << account_id << "…\n";
  auto result = client.authorize_interactively();
  if (!result) {
    std::cerr << "error: " << result.error().message << "\n";
    return 1;
  }

  const mailengine::Keychain keychain;
  if (auto stored = keychain.store(account_id, result->tokens.refresh_token); !stored) {
    std::cerr << "error: could not store refresh token: " << stored.error().message
              << "\n";
    return 1;
  }

  // The access token is deliberately not printed or persisted — it lives only
  // in memory for the life of a sync run.
  std::cout << "✓ authorized " << result->email_address << "\n"
            << "  refresh token stored in Keychain under account " << account_id
            << "\n";
  return 0;
}

int cmd_token(const std::string& account_id) {
  const mailengine::Keychain keychain;
  auto refresh_token = keychain.load(account_id);
  if (!refresh_token) {
    std::cerr << "error: " << refresh_token.error().message
              << "\n(run `mailengined auth " << account_id << "` first)\n";
    return 1;
  }

  const mailengine::OAuthClient client(config_from_env());
  auto tokens = client.refresh(*refresh_token);
  if (!tokens) {
    std::cerr << "error: " << tokens.error().message << "\n";
    return 1;
  }

  const auto lifetime = std::chrono::duration_cast<std::chrono::minutes>(
      tokens->expires_at - std::chrono::system_clock::now());
  std::cout << "✓ access token minted (valid " << lifetime.count() << " min, "
            << tokens->access_token.size() << " chars)\n";
  return 0;
}

/// Downloads one attachment by its row id, for diagnosing the fetch path in
/// isolation from the outbox.
int cmd_attachment(const std::string& account_id, const std::string& attachment_id) {
  mailengine::PostgresStore store;
  if (!connect_store(store)) return 1;

  auto row = store.attachment_for_download(attachment_id);
  if (!row) {
    std::cerr << "error: " << row.error().message << "\n";
    return 1;
  }

  auto tokens = mailengine::TokenProvider(config_from_env(), account_id);
  mailengine::GmailClient gmail(tokens);
  const mailengine::AttachmentStore blobs{mailengine::AttachmentStore::default_root()};

  std::cout << "  " << row->filename << "  (" << row->mime_type << ", "
            << row->size_bytes << " bytes)\n";

  const auto started = std::chrono::steady_clock::now();
  auto bytes = gmail.get_attachment(row->remote_message_id, row->remote_attachment_id);
  if (!bytes) {
    std::cerr << "error: " << bytes.error().message << "\n";
    return 1;
  }
  const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
      std::chrono::steady_clock::now() - started);

  auto blob = blobs.put(*bytes);
  if (!blob) {
    std::cerr << "error: " << blob.error().message << "\n";
    return 1;
  }

  if (auto recorded = store.record_attachment_download(
          attachment_id, blob->content_hash, blob->path, blob->size_bytes);
      !recorded) {
    std::cerr << "error: " << recorded.error().message << "\n";
    return 1;
  }

  std::cout << "  downloaded " << blob->size_bytes << " bytes in "
            << elapsed.count() << "ms"
            << (blob->newly_written ? "" : "  (already stored)") << "\n"
            << "  " << blob->path << "\n";
  return 0;
}

/// A stable account id derived from the mailbox address.
///
/// Deterministic on purpose: connecting the same Gmail twice must land on the
/// same row rather than duplicating the entire mailbox. `upsert_account`
/// already refuses to reset `last_history_id`, so a reconnect resumes instead
/// of triggering a full backfill.
///
/// Hashed rather than using the address itself because this id is a prefix of
/// every message, attachment and label id in the system — it ends up in the
/// search index, in logs, and in outbox payloads. There is no reason for the
/// user's address to travel through all of that.
std::string account_id_for(const std::string& email_address) {
  std::string normalised;
  normalised.reserve(email_address.size());
  for (const char c : email_address) {
    normalised += static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
  }
  const auto digest = mailengine::crypto::hex_encode(
      mailengine::crypto::sha256(normalised));
  return "acct_" + digest.substr(0, 12);
}

/// Colours new accounts get, in order.
///
/// Must stay in step with `AccountPalette.choices` in AccountViews.swift — the
/// picker offers these, so a colour assigned here that is absent there shows as
/// no selected swatch.
///
/// Built on the same cool axis as the app icon rather than the iOS system
/// palette used before: those hues are tuned to sit on white at full
/// saturation and read as loud plastic dots against a navy sidebar. These are
/// desaturated and mid-lightness, legible on all three themes.
///
/// Order is the assignment order, so the first two must be maximally
/// distinguishable — teal and clay differ in warmth as well as hue, so they
/// separate on lightness alone if hue perception fails.
constexpr std::array<const char*, 8> kAccountColours = {
    "#4aa3a2", "#c2705a", "#5b7ba8", "#7d9a6d",
    "#8a6a9e", "#c39a4e", "#b5697f", "#6f7d8c",
};

/// Emits one JSON line of progress.
///
/// The app spawns this command and reads stdout, so progress is structured
/// rather than prose: a half-parsed human sentence is how a connect flow ends
/// up silently reporting success for a mailbox that never synced.
void emit(const nlohmann::json& event) {
  std::cout << event.dump() << std::endl;
}

/// Connects a new mailbox: authorise, register, and backfill.
int cmd_connect(int64_t max_messages) {
  const mailengine::OAuthClient client(config_from_env());

  emit({{"event", "authorizing"}});
  auto authorized = client.authorize_interactively();
  if (!authorized) {
    emit({{"event", "error"}, {"message", authorized.error().message}});
    return 1;
  }

  const std::string email = authorized->email_address;
  const std::string account_id = account_id_for(email);
  emit({{"event", "authorized"}, {"email", email}, {"accountId", account_id}});

  // The refresh token goes to the Keychain and NEVER to Postgres: anything in
  // Postgres replicates to every client through zero-cache.
  const mailengine::Keychain keychain;
  if (auto stored = keychain.store(account_id, authorized->tokens.refresh_token);
      !stored) {
    emit({{"event", "error"}, {"message", stored.error().message}});
    return 1;
  }

  mailengine::PostgresStore store;
  if (!connect_store(store)) {
    emit({{"event", "error"}, {"message", "could not connect to postgres"}});
    return 1;
  }

  auto existing = store.list_accounts();
  if (!existing) {
    emit({{"event", "error"}, {"message", existing.error().message}});
    return 1;
  }
  const char* colour = kAccountColours[existing->size() % kAccountColours.size()];

  if (auto account = store.upsert_account(account_id, email, colour); !account) {
    emit({{"event", "error"}, {"message", account.error().message}});
    return 1;
  }

  emit({{"event", "syncing"}, {"accountId", account_id}});

  mailengine::TokenProvider tokens(config_from_env(), account_id);
  mailengine::GmailClient gmail(tokens);
  mailengine::SearchIndex index;
  const bool indexing = open_search(index);
  mailengine::Syncer syncer(gmail, store, account_id, indexing ? &index : nullptr);

  // Progress is streamed rather than reported at the end: a first backfill of
  // a real mailbox takes minutes, and a connect flow that shows nothing for
  // that long is indistinguishable from one that has hung.
  auto stats = syncer.backfill(
      /*query=*/"", max_messages, /*write_bodies=*/true,
      [](int64_t done, int64_t total) {
        emit({{"event", "progress"}, {"done", done}, {"total", total}});
      },
      /*fetch_workers=*/16);
  if (!stats) {
    // The account row and Keychain entry are deliberately left in place. The
    // mailbox IS connected; only the first backfill failed, and the daemon
    // will resume it. Tearing everything down would turn a network blip into
    // "please authorise again".
    emit({{"event", "error"},
          {"message", stats.error().message},
          {"accountId", account_id},
          {"recoverable", true}});
    return 1;
  }

  emit({{"event", "done"},
        {"accountId", account_id},
        {"email", email},
        {"messages", stats->written}});
  return 0;
}

/// Supervises every connected account.
///
/// Accounts are discovered from Postgres rather than passed on the command
/// line, so connecting a new mailbox does not require restarting the daemon —
/// it is picked up on the next supervision sweep.
int cmd_daemon(int interval_seconds) {
  mailengine::PostgresStore directory;
  if (!connect_store(directory)) return 1;

  // Output from several threads interleaves into one terminal, so each worker
  // buffers a full line and takes a mutex to emit it. Writing directly to
  // std::cout would shear lines together and make the log unreadable.
  std::mutex output_mutex;

  /// One supervised account.
  struct Worker {
    std::shared_ptr<std::atomic<bool>> running;
    std::thread thread;
  };
  std::map<std::string, Worker> workers;

  // How often the account list is re-read. Connecting a mailbox must not
  // require restarting the daemon — the connect flow runs its own backfill, so
  // without this the new account would appear fully synced and then quietly
  // stop receiving mail, which is worse than an obvious failure.
  constexpr int kSweepSeconds = 15;
  bool announced = false;

  while (true) {
    auto accounts = directory.list_accounts();
    if (!accounts) {
      std::cerr << "error: " << accounts.error().message << "\n";
      return 1;
    }

    // Start anything new.
    for (const auto& account : *accounts) {
      if (workers.count(account.id) != 0) continue;

      std::cout << (announced ? "+ now supervising " : "  ") << account.id << "  "
                << account.email_address << "\n";
      std::cout.flush();

      auto running = std::make_shared<std::atomic<bool>>(true);
      std::thread thread([&output_mutex, running, id = account.id,
                          email = account.email_address, interval_seconds] {
        LabelledStream out(output_mutex, email);
        run_account_loop(id, interval_seconds, out, *running);
      });
      workers.emplace(account.id,
                      Worker{.running = running, .thread = std::move(thread)});
    }

    // Stop anything that has gone away. A disconnected account whose thread
    // kept running would keep re-populating a mailbox the user removed.
    for (auto it = workers.begin(); it != workers.end();) {
      const bool still_connected =
          std::any_of(accounts->begin(), accounts->end(),
                      [&](const auto& account) { return account.id == it->first; });
      if (still_connected) {
        ++it;
        continue;
      }
      std::cout << "- stopping " << it->first << "\n";
      std::cout.flush();
      it->second.running->store(false);
      // Detached rather than joined: the worker may be mid-request, and
      // blocking the supervisor on a network timeout would stall every other
      // account's supervision behind it.
      it->second.thread.detach();
      it = workers.erase(it);
    }

    if (!announced) {
      if (workers.empty()) {
        std::cerr << "no accounts connected. Run `mailengined connect` first.\n";
        return 1;
      }
      std::cout << "daemon supervising " << workers.size() << " account"
                << (workers.size() == 1 ? "" : "s") << ", sweeping every "
                << kSweepSeconds << "s for new ones\n";
      std::cout.flush();
      announced = true;
    }

    std::this_thread::sleep_for(std::chrono::seconds(kSweepSeconds));
  }
}

}  // namespace

int main(int argc, char** argv) {
  if (argc < 2) {
    return usage();
  }
  const std::string command = argv[1];

  if (command == "version") {
    std::cout << "mailengined " << mailengine::version() << "\n";
    return 0;
  }
  if (command == "auth") {
    if (argc < 3) return usage();
    return cmd_auth(argv[2]);
  }
  if (command == "token") {
    if (argc < 3) return usage();
    return cmd_token(argv[2]);
  }
  if (command == "profile") {
    if (argc < 3) return usage();
    return cmd_profile(argv[2]);
  }
  if (command == "labels") {
    if (argc < 3) return usage();
    return cmd_labels(argv[2]);
  }
  if (command == "sync") {
    if (argc < 3) return usage();
    return cmd_sync(argv[2], argc > 3 ? argv[3] : "",
                    argc > 4 ? std::atoll(argv[4]) : 0,
                    argc > 5 ? std::atoi(argv[5]) : 16);
  }
  if (command == "poll") {
    if (argc < 3) return usage();
    return cmd_poll(argv[2]);
  }
  if (command == "drain") {
    if (argc < 3) return usage();
    return cmd_drain(argv[2]);
  }
  if (command == "connect") {
    return cmd_connect(argc > 2 ? std::atoll(argv[2]) : 0);
  }
  if (command == "daemon") {
    // No account argument: the daemon supervises every connected account.
    // A bare number is still accepted as the poll interval.
    return cmd_daemon(argc > 2 ? std::atoi(argv[2]) : 15);
  }
  if (command == "attachment") {
    if (argc < 4) return usage();
    return cmd_attachment(argv[2], argv[3]);
  }
  if (command == "bench-search") {
    std::vector<int64_t> sizes;
    for (int i = 2; i < argc; ++i) sizes.push_back(std::atoll(argv[i]));
    if (sizes.empty()) sizes = {1000, 10000, 50000, 200000};
    return cmd_bench_search(sizes);
  }
  if (command == "resanitize") {
    if (argc < 3) return usage();
    return cmd_resanitize(argv[2]);
  }
  if (command == "reindex") {
    if (argc < 3) return usage();
    return cmd_reindex(argv[2]);
  }
  if (command == "search") {
    if (argc < 4) return usage();
    return cmd_search(argv[2], argv[3]);
  }
  if (command == "check") {
    if (argc < 3) return usage();
    return cmd_check(argv[2], argc > 3 ? std::atoi(argv[3]) : 40);
  }
  if (command == "peek") {
    if (argc < 3) return usage();
    return cmd_peek(argv[2], argc > 3 ? std::atoi(argv[3]) : 5);
  }

  return usage();
}
