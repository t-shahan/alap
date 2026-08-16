/// @file search.cpp
/// @brief FTS5 index implementation.

#include "mailengine/search.hpp"

#include <sqlite3.h>

#include <cctype>
#include <sstream>
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
  )";
  char* error = nullptr;
  if (sqlite3_exec(db, schema, nullptr, nullptr, &error) != SQLITE_OK) {
    const std::string message = error != nullptr ? error : "unknown";
    sqlite3_free(error);
    return make_error("could not create FTS5 table: " + message);
  }

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
                        message.from.name + " " + message.from.email, body);
}

Result<void> SearchIndex::index_document(const std::string& account_id,
                                         const std::string& thread_id,
                                         const std::string& message_id,
                                         const std::string& subject,
                                         const std::string& sender,
                                         const std::string& body) {
  auto* db = static_cast<sqlite3*>(db_);
  if (db == nullptr) return make_error("search index not open");

  // FTS5 has no upsert, so replace by hand.
  {
    Stmt del(db, "DELETE FROM message_fts WHERE message_id = ?1");
    if (!del.ok()) return make_error("prepare delete failed");
    del.bind(1, message_id);
    sqlite3_step(del.get());
  }

  Stmt insert(db,
              "INSERT INTO message_fts "
              "(message_id, thread_id, account_id, subject, sender, body) "
              "VALUES (?1, ?2, ?3, ?4, ?5, ?6)");
  if (!insert.ok()) return make_error("prepare insert failed");

  insert.bind(1, message_id);
  insert.bind(2, thread_id);
  insert.bind(3, account_id);
  insert.bind(4, subject);
  insert.bind(5, sender);
  insert.bind(6, body);

  if (sqlite3_step(insert.get()) != SQLITE_DONE) {
    return make_error(std::string("index insert failed: ") + sqlite3_errmsg(db));
  }
  return {};
}

Result<void> SearchIndex::remove_message(const std::string& message_id) {
  auto* db = static_cast<sqlite3*>(db_);
  if (db == nullptr) return make_error("search index not open");

  Stmt del(db, "DELETE FROM message_fts WHERE message_id = ?1");
  if (!del.ok()) return make_error("prepare delete failed");
  del.bind(1, message_id);
  sqlite3_step(del.get());
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
                                                   int limit) {
  auto* db = static_cast<sqlite3*>(db_);
  if (db == nullptr) return make_error("search index not open");

  const std::string escaped = escape_query(query);
  if (escaped.empty()) {
    return std::vector<SearchHit>{};
  }

  // GROUP BY thread so a term matching three messages in one conversation
  // yields one result. bm25 weights subject 10x and sender 5x over body — a
  // match in the subject line is almost always what the user meant.
  //
  // The MATERIALIZED CTE is load-bearing, not stylistic. FTS5 auxiliary
  // functions like bm25() may only appear in a direct scan of the virtual
  // table; using one alongside GROUP BY fails with "unable to use function
  // bm25 in the requested context". SQLite would normally flatten a plain
  // subquery back into the outer statement and reintroduce the problem, so
  // MATERIALIZED forces the ranking to be computed first and grouped after.
  //
  // bm25 returns negative values where lower is better, so ORDER BY ascending
  // puts the best match first.
  Stmt select(db, R"(
      WITH hits AS MATERIALIZED (
        SELECT thread_id,
               message_id,
               subject,
               -- One weight PER COLUMN, in declaration order. The three
               -- UNINDEXED columns still occupy positions even though they can
               -- never match, so they take 0.0 placeholders:
               --   message_id, thread_id, account_id, subject, sender, body
               -- Omitting them silently shifts every weight and ranks by the
               -- wrong field.
               bm25(message_fts, 0.0, 0.0, 0.0, 10.0, 5.0, 1.0) AS score
        FROM message_fts
        WHERE message_fts MATCH ?1
      )
      SELECT thread_id, message_id, subject, min(score) AS best
      FROM hits
      GROUP BY thread_id
      ORDER BY best
      LIMIT ?2)");
  if (!select.ok()) {
    return make_error(std::string("prepare search failed: ") + sqlite3_errmsg(db));
  }
  select.bind(1, escaped);
  sqlite3_bind_int(select.get(), 2, limit);

  std::vector<SearchHit> hits;
  int step = sqlite3_step(select.get());
  while (step == SQLITE_ROW) {
    hits.push_back(SearchHit{
        .thread_id = select.column(0),
        .message_id = select.column(1),
        .subject = select.column(2),
        .rank = sqlite3_column_double(select.get(), 3),
    });
    step = sqlite3_step(select.get());
  }

  // Checking the terminal status matters: a `while (step() == SQLITE_ROW)`
  // loop treats an error as "no more rows" and returns an empty result set.
  // That is how the bm25 failure above presented — as zero matches rather
  // than as an error.
  if (step != SQLITE_DONE) {
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
  return {};
}

}  // namespace mailengine
