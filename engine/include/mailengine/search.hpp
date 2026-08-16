/// @file search.hpp
/// @brief SQLite FTS5 full-text index.
///
/// ## Why this exists outside Zero
///
/// ZQL has no text search — it is on Rocicorp's roadmap but unshipped. So
/// search is a separate subsystem, and the app uses a **two-stage** pattern:
///
///   1. FTS5 matches the query and returns thread ids (this file).
///   2. Those ids feed a reactive ZQL query, `threads.byIds`.
///
/// Stage two is what makes the results live. A plain FTS5 query returns a dead
/// snapshot; routing the ids back through Zero means that if new mail arrives
/// in a matching thread, or someone marks one read, the visible results update
/// on their own.
///
/// ## Why a separate database
///
/// The index lives in its own SQLite file rather than in Postgres, for three
/// reasons: Postgres full-text would replicate into zero-cache and bloat every
/// client's replica; FTS5 is dramatically better at this than `tsvector` for a
/// single-user local index; and the file can be deleted and rebuilt from
/// Postgres at any time, so it is disposable rather than precious.

#pragma once

#include <cstdint>
#include <string>
#include <vector>

#include "mailengine/gmail.hpp"
#include "mailengine/result.hpp"

namespace mailengine {

/// @brief How results are ordered, which is also a performance decision.
enum class SearchOrder {
  /// Newest matching message first.
  ///
  /// O(results), NOT O(corpus): the FTS rowid is the message timestamp, so
  /// SQLite walks the posting list backwards and stops as soon as it has
  /// enough. This is the default because it is both what mail users normally
  /// want and the only ordering that stays flat as the mailbox grows.
  Recency,

  /// Best bm25 score first.
  ///
  /// Requires scoring EVERY matching document — relevance ranking cannot know
  /// the top n without examining all candidates. Cost therefore grows with the
  /// number of matches, which for a common term means the whole mailbox. Use
  /// deliberately, not by default.
  Relevance,
};

/// @brief One search hit.
struct SearchHit {
  std::string thread_id;   ///< our composite id, ready for ZQL
  std::string message_id;
  std::string subject;
  /// Lower is better — FTS5's bm25 relevance score.
  double rank = 0;
};

/// @brief Owns the FTS5 index.
///
/// Not thread-safe. SQLite connections are per-thread.
class SearchIndex {
 public:
  SearchIndex();
  ~SearchIndex();
  SearchIndex(const SearchIndex&) = delete;
  SearchIndex& operator=(const SearchIndex&) = delete;
  /// Movable so an index can be returned from a factory or held in a
  /// container. A sqlite3* has exactly one owner, so copying is meaningless
  /// but transferring is not.
  SearchIndex(SearchIndex&& other) noexcept;
  SearchIndex& operator=(SearchIndex&& other) noexcept;

  /// @brief Opens (creating if needed) the index at `path`.
  [[nodiscard]] Result<void> open(const std::string& path);

  /// @brief Indexes one message, replacing any previous entry for it.
  ///
  /// FTS5 has no upsert, so this deletes then inserts. `thread_id` and
  /// `account_id` are the composite ids used in Postgres, so hits can be fed
  /// straight into ZQL without translation.
  [[nodiscard]] Result<void> index_message(const std::string& account_id,
                                           const std::string& thread_id,
                                           const std::string& message_id,
                                           const GmailMessage& message);

  /// @brief Indexes raw fields, replacing any previous entry.
  ///
  /// The entry point used when rebuilding from Postgres. `index_message` is a
  /// convenience wrapper over this for the ingest path.
  /// @param sent_at_ms Message timestamp. Becomes the FTS rowid, which is what
  ///        makes recency-ordered search early-terminating. Passing 0 falls
  ///        back to an auto-assigned rowid, and such documents sort as oldest.
  [[nodiscard]] Result<void> index_document(const std::string& account_id,
                                            const std::string& thread_id,
                                            const std::string& message_id,
                                            const std::string& subject,
                                            const std::string& sender,
                                            const std::string& body,
                                            int64_t sent_at_ms = 0);

  /// @brief Begins a bulk-indexing transaction.
  ///
  /// Without this, every `index_document` is its own implicit transaction and
  /// pays a WAL fsync — two, since it deletes then inserts. That is fine for
  /// the incremental path (a handful of messages) and catastrophic for a
  /// 31,000-message reindex, where fsync latency dwarfs the actual work.
  ///
  /// Callers must pair this with `commit_batch`. Not reentrant.
  [[nodiscard]] Result<void> begin_batch();

  /// @brief Commits a bulk-indexing transaction.
  [[nodiscard]] Result<void> commit_batch();

  /// @brief Removes a message from the index.
  [[nodiscard]] Result<void> remove_message(const std::string& message_id);

  /// @brief Searches, returning the best matching threads.
  ///
  /// `query` is user input and is escaped before reaching FTS5 — see
  /// `escape_query`. Results are deduplicated by thread, since matching three
  /// messages in one conversation should surface one result, not three.
  [[nodiscard]] Result<std::vector<SearchHit>> search(
      const std::string& query, int limit = 100,
      SearchOrder order = SearchOrder::Recency);

  /// @brief Number of indexed messages.
  [[nodiscard]] Result<int64_t> count();

  /// @brief Empties the index. It can always be rebuilt from Postgres.
  [[nodiscard]] Result<void> clear();

  /// @brief Escapes user input for FTS5's MATCH grammar.
  ///
  /// FTS5 treats `"`, `*`, `(`, `)`, `:`, `^`, `-`, AND, OR, NOT as operators.
  /// Passing raw user text through produces syntax errors on perfectly
  /// reasonable searches — an address containing `@`, or a subject with a
  /// hyphen. Each term is quoted, which makes it a literal, and a trailing `*`
  /// is added to the last term so results appear as you type.
  [[nodiscard]] static std::string escape_query(const std::string& query);

 private:
  /// Opaque `sqlite3*`.
  void* db_ = nullptr;
};

}  // namespace mailengine
