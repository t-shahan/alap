/// @file search.cpp
/// @brief FTS5 index implementation.

#include "mailengine/search.hpp"

#include <sqlite3.h>

#include <algorithm>
#include <cctype>
#include <sstream>
#include <unordered_set>
#include <utility>

namespace mailengine {
namespace {

/// RAII owner for a prepared statement.
class Stmt {
 public:
  Stmt(sqlite3* db, const std::string& sql) {
    prepared_ = sqlite3_prepare_v2(db, sql.c_str(), -1, &stmt_, nullptr) == SQLITE_OK;
  }
  ~Stmt() {
    if (stmt_ != nullptr) sqlite3_finalize(stmt_);
  }
  Stmt(const Stmt&) = delete;
  Stmt& operator=(const Stmt&) = delete;

  [[nodiscard]] bool ok() const noexcept { return prepared_; }
  [[nodiscard]] sqlite3_stmt* get() const noexcept { return stmt_; }

  /// Binds a text parameter. SQLITE_TRANSIENT because the source string may
  /// not outlive the call.
  void bind(int index, const std::string& value) {
    sqlite3_bind_text(stmt_, index, value.c_str(), -1, SQLITE_TRANSIENT);
  }

  [[nodiscard]] std::string column(int index) const {
    const auto* text = sqlite3_column_text(stmt_, index);
    return text != nullptr ? reinterpret_cast<const char*>(text) : "";
  }

 private:
  sqlite3_stmt* stmt_ = nullptr;
  bool prepared_ = false;
};

}  // namespace

SearchIndex::SearchIndex() = default;

SearchIndex::SearchIndex(SearchIndex&& other) noexcept
    : db_(std::exchange(other.db_, nullptr)) {}

SearchIndex& SearchIndex::operator=(SearchIndex&& other) noexcept {
  if (this != &other) {
    if (db_ != nullptr) sqlite3_close(static_cast<sqlite3*>(db_));
    db_ = std::exchange(other.db_, nullptr);
  }
  return *this;
}

SearchIndex::~SearchIndex() {
  if (db_ != nullptr) {
    sqlite3_close(static_cast<sqlite3*>(db_));
  }
}

Result<void> SearchIndex::open(const std::string& path) {
  sqlite3* db = nullptr;
  if (sqlite3_open(path.c_str(), &db) != SQLITE_OK) {
    const std::string message = db != nullptr ? sqlite3_errmsg(db) : "unknown";
    sqlite3_close(db);
    return make_error("could not open search index: " + message);
  }
  db_ = db;

  // WAL lets the Swift app read the index while the engine is writing to it —
  // which is the entire point, since search happens in the UI and indexing
  // happens in the daemon.
  sqlite3_exec(db, "PRAGMA journal_mode=WAL", nullptr, nullptr, nullptr);
  sqlite3_exec(db, "PRAGMA synchronous=NORMAL", nullptr, nullptr, nullptr);

  // porter stemming so "meeting" matches "meetings"; unicode61 with diacritic
  // folding so "cafe" matches "café".
  const char* schema = R"(
    CREATE VIRTUAL TABLE IF NOT EXISTS message_fts USING fts5(
      message_id UNINDEXED,
      thread_id  UNINDEXED,
      account_id UNINDEXED,
      subject,
      sender,
      body,
      tokenize = 'porter unicode61 remove_diacritics 2'
    );

    -- Maps message_id to the FTS rowid.
    --
    -- Without this, replacing a document means
    -- `DELETE FROM message_fts WHERE message_id = ?`, and UNINDEXED columns
    -- are stored but NOT indexed — so every insert full-scans the whole index
    -- and building it becomes O(n^2). Measured: 5x the documents took 38x the
    -- time. A real primary key here makes replacement O(log n).
    CREATE TABLE IF NOT EXISTS doc_rowid (
      message_id TEXT PRIMARY KEY,
      fts_rowid  INTEGER NOT NULL
    );
  )";
  char* error = nullptr;
  if (sqlite3_exec(db, schema, nullptr, nullptr, &error) != SQLITE_OK) {
    const std::string message = error != nullptr ? error : "unknown";
    sqlite3_free(error);
    return make_error("could not create FTS5 table: " + message);
  }

  // Persist the bm25 weights as the table's rank function. This is what lets
  // queries say `ORDER BY rank LIMIT n`, which FTS5 can satisfy with early
  // termination — it stops as soon as it has n results rather than scoring
  // every match. Passing weights inline to bm25() in the ORDER BY instead
  // forces a full scan.
  //
  // One weight per column, including the three UNINDEXED ones, which can never
  // match and so take 0.0.
  sqlite3_exec(db,
               "INSERT INTO message_fts(message_fts, rank) "
               "VALUES('rank', 'bm25(0.0, 0.0, 0.0, 10.0, 5.0, 1.0)')",
               nullptr, nullptr, nullptr);

  return {};
}

Result<void> SearchIndex::index_message(const std::string& account_id,
                                        const std::string& thread_id,
                                        const std::string& message_id,
                                        const GmailMessage& message) {
  // Index the plain-text body when available; HTML is mostly markup and
  // pollutes the index with tag names and inline CSS.
  const std::string& body =
      !message.text_body.empty() ? message.text_body : message.snippet;
  return index_document(account_id, thread_id, message_id, message.subject,
                        message.from.name + " " + message.from.email, body,
                        message.internal_date_ms);
}

Result<void> SearchIndex::index_document(const std::string& account_id,
                                         const std::string& thread_id,
                                         const std::string& message_id,
                                         const std::string& subject,
                                         const std::string& sender,
                                         const std::string& body,
                                         int64_t sent_at_ms) {
  auto* db = static_cast<sqlite3*>(db_);
  if (db == nullptr) return make_error("search index not open");

  // FTS5 has no upsert, so replace by hand — but delete by ROWID, looked up
  // through the indexed side table, not by scanning an UNINDEXED column.
  {
    Stmt lookup(db, "SELECT fts_rowid FROM doc_rowid WHERE message_id = ?1");
    if (!lookup.ok()) return make_error("prepare rowid lookup failed");
    lookup.bind(1, message_id);
    if (sqlite3_step(lookup.get()) == SQLITE_ROW) {
      const sqlite3_int64 rowid = sqlite3_column_int64(lookup.get(), 0);
      Stmt del(db, "DELETE FROM message_fts WHERE rowid = ?1");
      if (!del.ok()) return make_error("prepare delete failed");
      sqlite3_bind_int64(del.get(), 1, rowid);
      sqlite3_step(del.get());
    }
  }

  // The rowid IS the timestamp. That is what lets `ORDER BY rowid DESC LIMIT n`
  // return the newest matches without scoring the whole corpus. Two messages
  // can share a millisecond, so on collision we step forward to the next free
  // slot — a one-millisecond ordering error is irrelevant, a failed insert is
  // not.
  int64_t rowid = sent_at_ms;
  bool inserted = false;
  for (int attempt = 0; attempt < 1000 && !inserted; ++attempt) {
    Stmt insert(db,
                "INSERT INTO message_fts "
                "(rowid, message_id, thread_id, account_id, subject, sender, body) "
                "VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)");
    if (!insert.ok()) return make_error("prepare insert failed");

    if (rowid > 0) {
      sqlite3_bind_int64(insert.get(), 1, rowid + attempt);
    } else {
      sqlite3_bind_null(insert.get(), 1);  // let SQLite assign
    }
    insert.bind(2, message_id);
    insert.bind(3, thread_id);
    insert.bind(4, account_id);
    insert.bind(5, subject);
    insert.bind(6, sender);
    insert.bind(7, body);

    const int status = sqlite3_step(insert.get());
    if (status == SQLITE_DONE) {
      inserted = true;
    } else if (status != SQLITE_CONSTRAINT || rowid <= 0) {
      return make_error(std::string("index insert failed: ") + sqlite3_errmsg(db));
    }
  }
  if (!inserted) {
    return make_error("could not find a free rowid for " + message_id);
  }

  Stmt remember(db,
                "INSERT INTO doc_rowid(message_id, fts_rowid) VALUES(?1, ?2) "
                "ON CONFLICT(message_id) DO UPDATE SET fts_rowid = excluded.fts_rowid");
  if (!remember.ok()) return make_error("prepare rowid record failed");
  remember.bind(1, message_id);
  sqlite3_bind_int64(remember.get(), 2, sqlite3_last_insert_rowid(db));
  if (sqlite3_step(remember.get()) != SQLITE_DONE) {
    return make_error(std::string("rowid record failed: ") + sqlite3_errmsg(db));
  }
  return {};
}

Result<void> SearchIndex::begin_batch() {
  auto* db = static_cast<sqlite3*>(db_);
  if (db == nullptr) return make_error("search index not open");
  char* error = nullptr;
  if (sqlite3_exec(db, "BEGIN", nullptr, nullptr, &error) != SQLITE_OK) {
    const std::string message = error != nullptr ? error : "unknown";
    sqlite3_free(error);
    return make_error("begin batch failed: " + message);
  }
  return {};
}

Result<void> SearchIndex::commit_batch() {
  auto* db = static_cast<sqlite3*>(db_);
  if (db == nullptr) return make_error("search index not open");
  char* error = nullptr;
  if (sqlite3_exec(db, "COMMIT", nullptr, nullptr, &error) != SQLITE_OK) {
    const std::string message = error != nullptr ? error : "unknown";
    sqlite3_free(error);
    return make_error("commit batch failed: " + message);
  }
  return {};
}

Result<void> SearchIndex::remove_message(const std::string& message_id) {
  auto* db = static_cast<sqlite3*>(db_);
  if (db == nullptr) return make_error("search index not open");

  Stmt lookup(db, "SELECT fts_rowid FROM doc_rowid WHERE message_id = ?1");
  if (!lookup.ok()) return make_error("prepare rowid lookup failed");
  lookup.bind(1, message_id);
  if (sqlite3_step(lookup.get()) != SQLITE_ROW) {
    return {};  // not indexed; nothing to do
  }
  const sqlite3_int64 rowid = sqlite3_column_int64(lookup.get(), 0);

  Stmt del(db, "DELETE FROM message_fts WHERE rowid = ?1");
  if (!del.ok()) return make_error("prepare delete failed");
  sqlite3_bind_int64(del.get(), 1, rowid);
  sqlite3_step(del.get());

  Stmt forget(db, "DELETE FROM doc_rowid WHERE message_id = ?1");
  if (forget.ok()) {
    forget.bind(1, message_id);
    sqlite3_step(forget.get());
  }
  return {};
}

std::string SearchIndex::escape_query(const std::string& query) {
  // Split on whitespace, quote each term, and prefix-match the last one.
  //
  // Quoting is what makes user input safe: inside double quotes FTS5 treats
  // everything as a literal, so `foo@bar.com`, `re:`, and `cost-benefit` all
  // work instead of raising a syntax error. Any embedded quote is doubled,
  // which is FTS5's own escape.
  std::istringstream stream(query);
  std::string term;
  std::vector<std::string> terms;

  while (stream >> term) {
    std::string escaped;
    escaped.reserve(term.size() + 2);
    for (const char c : term) {
      if (c == '"') escaped += '"';  // double it
      escaped += c;
    }
    if (!escaped.empty()) {
      terms.push_back("\"" + escaped + "\"");
    }
  }

  if (terms.empty()) return {};

  // Prefix-match the final term so results narrow as the user types. FTS5
  // requires the `*` outside the closing quote.
  terms.back() += "*";

  std::string result;
  for (const auto& value : terms) {
    if (!result.empty()) result += " AND ";
    result += value;
  }
  return result;
}

Result<std::vector<SearchHit>> SearchIndex::search(const std::string& query,
                                                   int limit, SearchOrder order) {
  auto* db = static_cast<sqlite3*>(db_);
  if (db == nullptr) return make_error("search index not open");

  const std::string escaped = escape_query(query);
  if (escaped.empty()) {
    return std::vector<SearchHit>{};
  }

  // `ORDER BY rank LIMIT n` is the ONLY shape FTS5 can satisfy with early
  // termination: it walks the posting lists in score order and stops once it
  // has n rows. The previous version wrapped bm25() in a MATERIALIZED CTE so
  // it could GROUP BY thread, which forced every matching document to be
  // scored before anything was discarded — query time then grew linearly with
  // the mailbox (177ms at 50k messages).
  //
  // Deduplication by thread therefore happens HERE, in C++, over an
  // over-fetched window. Threads average well under 4 messages, so fetching
  // 4x the requested limit almost always yields a full page of distinct
  // threads while keeping the SQL early-terminating.
  const int window = std::min(limit * 4, 2000);

  // Recency walks the posting list backwards and stops early; relevance must
  // score everything. See SearchOrder.
  const char* sql =
      order == SearchOrder::Recency
          ? R"(SELECT thread_id, message_id, subject, 0.0
               FROM message_fts
               WHERE message_fts MATCH ?1
               ORDER BY rowid DESC
               LIMIT ?2)"
          : R"(SELECT thread_id, message_id, subject, rank
               FROM message_fts
               WHERE message_fts MATCH ?1
               ORDER BY rank
               LIMIT ?2)";

  Stmt select(db, sql);
  if (!select.ok()) {
    return make_error(std::string("prepare search failed: ") + sqlite3_errmsg(db));
  }
  select.bind(1, escaped);
  sqlite3_bind_int(select.get(), 2, window);

  std::vector<SearchHit> hits;
  std::unordered_set<std::string> seen_threads;

  int step = sqlite3_step(select.get());
  while (step == SQLITE_ROW) {
    std::string thread_id = select.column(0);
    // Rows arrive best-first, so the first sighting of a thread is its best
    // message and later ones are redundant.
    if (seen_threads.insert(thread_id).second) {
      hits.push_back(SearchHit{
          .thread_id = std::move(thread_id),
          .message_id = select.column(1),
          .subject = select.column(2),
          .rank = sqlite3_column_double(select.get(), 3),
      });
      if (static_cast<int>(hits.size()) >= limit) break;
    }
    step = sqlite3_step(select.get());
  }

  // A `while (step() == SQLITE_ROW)` loop treats an error as "no more rows"
  // and silently returns an empty result set. That is how an earlier bm25
  // misuse presented — as zero matches rather than as a failure.
  if (step != SQLITE_ROW && step != SQLITE_DONE) {
    return make_error(std::string("search failed: ") + sqlite3_errmsg(db));
  }
  return hits;
}

Result<int64_t> SearchIndex::count() {
  auto* db = static_cast<sqlite3*>(db_);
  if (db == nullptr) return make_error("search index not open");

  Stmt select(db, "SELECT count(*) FROM message_fts");
  if (!select.ok()) return make_error("prepare count failed");
  if (sqlite3_step(select.get()) != SQLITE_ROW) return static_cast<int64_t>(0);
  return static_cast<int64_t>(sqlite3_column_int64(select.get(), 0));
}

Result<void> SearchIndex::clear() {
  auto* db = static_cast<sqlite3*>(db_);
  if (db == nullptr) return make_error("search index not open");
  sqlite3_exec(db, "DELETE FROM message_fts", nullptr, nullptr, nullptr);
  sqlite3_exec(db, "DELETE FROM doc_rowid", nullptr, nullptr, nullptr);
  return {};
}

}  // namespace mailengine
