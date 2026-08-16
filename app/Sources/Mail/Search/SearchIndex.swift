import Foundation
import OSLog
import SQLite3

/// Read-only access to the FTS5 index the C++ engine maintains.
///
/// ## The two-stage pattern
///
/// ZQL has no full-text search, so search is split:
///
///   1. **Here.** FTS5 matches the query and returns thread ids. Sub-millisecond,
///      entirely local, no network.
///   2. **Zero.** Those ids feed the reactive `threads.byIds` query.
///
/// Stage two is what makes results *live*. Returning rows straight out of
/// SQLite would give a dead snapshot; routing the ids back through Zero means
/// a new message in a matching thread, or a thread being marked read, updates
/// the visible results without re-running the search.
///
/// ## Why reading another process's database is safe here
///
/// The engine opens this file in WAL mode, which permits concurrent readers
/// alongside a writer. This connection is opened read-only, so the UI can
/// never corrupt or block indexing.
/// Not actor-isolated. `MailStore` is `@MainActor` and owns the only instance,
/// so access is already serialised; marking this `@MainActor` too would make
/// `deinit` nonisolated and unable to close the connection under Swift 6's
/// strict concurrency rules.
final class SearchIndex {
  private static let log = Logger(subsystem: "dev.local.mailapp", category: "search")

  private var db: OpaquePointer?

  /// Location shared with the engine's `search_index_path()`.
  ///
  /// Application Support rather than the project directory: the app's working
  /// directory is arbitrary, so a relative path would resolve differently for
  /// each process.
  static var defaultPath: String {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return base.appendingPathComponent("dev.local.mailapp/search.db").path
  }

  /// True when the index file exists and opened successfully.
  private(set) var isAvailable = false

  init(path: String = SearchIndex.defaultPath) {
    guard FileManager.default.fileExists(atPath: path) else {
      Self.log.info("no search index at \(path, privacy: .public); run `mailengined reindex`")
      return
    }
    // SQLITE_OPEN_READONLY guarantees the UI cannot interfere with the engine.
    if sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK {
      isAvailable = true
    } else {
      Self.log.error("could not open search index at \(path, privacy: .public)")
      sqlite3_close(db)
      db = nil
    }
  }

  deinit {
    if let db { sqlite3_close(db) }
  }

  /// Returns matching thread ids, best first.
  ///
  /// Ids are our composite `account|threadId` form, ready to hand to ZQL
  /// without translation — which is exactly why the engine stores them that
  /// way rather than storing Gmail's raw ids.
  func threadIDs(matching query: String, limit: Int = 100) -> [String] {
    guard let db, isAvailable else { return [] }

    let escaped = Self.escape(query)
    guard !escaped.isEmpty else { return [] }

    // Mirrors the engine's query. The MATERIALIZED CTE is required: FTS5
    // auxiliary functions like bm25() cannot appear alongside GROUP BY, and
    // SQLite would otherwise flatten a plain subquery and reintroduce that.
    let sql = """
      WITH hits AS MATERIALIZED (
        SELECT thread_id, bm25(message_fts, 0.0, 0.0, 0.0, 10.0, 5.0, 1.0) AS score
        FROM message_fts
        WHERE message_fts MATCH ?1
      )
      SELECT thread_id, min(score) AS best
      FROM hits
      GROUP BY thread_id
      ORDER BY best
      LIMIT ?2
      """

    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
      Self.log.error("search prepare failed: \(String(cString: sqlite3_errmsg(db)), privacy: .public)")
      return []
    }
    defer { sqlite3_finalize(statement) }

    // SQLITE_TRANSIENT: SQLite copies the bytes, so the Swift string need not
    // outlive the call.
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    sqlite3_bind_text(statement, 1, escaped, -1, transient)
    sqlite3_bind_int(statement, 2, Int32(limit))

    var ids: [String] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      if let text = sqlite3_column_text(statement, 0) {
        ids.append(String(cString: text))
      }
    }
    return ids
  }

  /// Escapes user input for FTS5's MATCH grammar.
  ///
  /// Must stay in step with the engine's `SearchIndex::escape_query`. Quoting
  /// each term makes it a literal, so an email address, a hyphenated word, or
  /// a stray `AND` searches for itself instead of raising a syntax error. The
  /// last term gets a `*` so results narrow as the user types.
  static func escape(_ query: String) -> String {
    let terms = query
      .split(whereSeparator: \.isWhitespace)
      .map { term in "\"\(term.replacingOccurrences(of: "\"", with: "\"\""))\"" }

    guard !terms.isEmpty else { return "" }

    var escaped = terms
    escaped[escaped.count - 1] += "*"
    return escaped.joined(separator: " AND ")
  }
}
