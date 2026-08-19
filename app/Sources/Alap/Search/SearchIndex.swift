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
  private static let log = Logger(subsystem: AppIdentity.bundleID, category: "search")

  private var db: OpaquePointer?

  /// Location shared with the engine's `search_index_path()`.
  ///
  /// Application Support rather than the project directory: the app's working
  /// directory is arbitrary, so a relative path would resolve differently for
  /// each process.
  static var defaultPath: String {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return AppIdentity.applicationSupport.appendingPathComponent("search.db").path
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

  /// Total messages in the index.
  ///
  /// `COUNT(*)` on an FTS5 table walks it, which at ~32k rows is single-digit
  /// milliseconds. That is cheap once and ruinous per render, so the store
  /// caches the answer and refreshes it alongside a delivery — never from a
  /// view body.
  ///
  /// Returns nil rather than zero when the index is unavailable: "0 messages"
  /// over a full mailbox is a worse reading than no reading.
  func messageCount() -> Int? {
    guard let db, isAvailable else { return nil }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, "SELECT count(*) FROM message_fts", -1, &statement, nil)
            == SQLITE_OK
    else { return nil }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
    return Int(sqlite3_column_int64(statement, 0))
  }

  /// Returns matching thread ids, newest first.
  ///
  /// ## Why recency and not relevance
  ///
  /// bm25 relevance ranking must score EVERY matching document — you cannot
  /// know the top 100 without examining all candidates — so its cost grows
  /// with the mailbox. Measured on a synthetic corpus: 180ms at 200k messages.
  ///
  /// `ORDER BY rowid DESC LIMIT n` lets SQLite walk the posting list backwards
  /// and stop as soon as it has enough, because the engine stores each
  /// message's timestamp AS its rowid. Cost becomes O(results) rather than
  /// O(corpus): 2.96ms at 200k. It is also what a mail user normally wants.
  func threadIDs(matching query: String, limit: Int = 100) -> [String] {
    let exact = rawThreadIDs(matching: query, limit: limit)
    guard exact.count < Self.fuzzyThreshold else { return exact }

    // FUZZY FALLBACK, reached only when the exact query found almost nothing.
    // A correctly spelled query never pays for this, which is what keeps
    // typing instant.
    guard let corrected = correctedQuery(for: query), corrected != query else {
      return exact
    }
    let fuzzy = rawThreadIDs(matching: corrected, limit: limit)
    return fuzzy.count > exact.count ? fuzzy : exact
  }

  /// Below this many results, term correction is attempted.
  private static let fuzzyThreshold = 5

  private func rawThreadIDs(matching query: String, limit: Int) -> [String] {
    guard let db, isAvailable else { return [] }
    let escaped = Self.escape(query)
    guard !escaped.isEmpty else { return [] }

    // Over-fetch, then deduplicate by thread here. Doing it in SQL would need
    // GROUP BY, which defeats the early termination this whole design rests on.
    let window = min(limit * 4, 2000)
    let sql = """
      SELECT thread_id FROM message_fts
      WHERE message_fts MATCH ?1
      ORDER BY rowid DESC
      LIMIT ?2
      """

    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
      Self.log.error("search prepare failed: \(String(cString: sqlite3_errmsg(db)), privacy: .public)")
      return []
    }
    defer { sqlite3_finalize(statement) }

    sqlite3_bind_text(statement, 1, escaped, -1, Self.transient)
    sqlite3_bind_int(statement, 2, Int32(window))

    var ids: [String] = []
    var seen = Set<String>()
    while sqlite3_step(statement) == SQLITE_ROW {
      guard let text = sqlite3_column_text(statement, 0) else { continue }
      let id = String(cString: text)
      // Rows arrive newest-first, so the first sighting of a thread is the one
      // to keep.
      if seen.insert(id).inserted {
        ids.append(id)
        if ids.count >= limit { break }
      }
    }
    return ids
  }

  /// Rewrites a query using the closest terms that actually appear in the
  /// index, or nil when nothing is close enough.
  ///
  /// Mirrors the engine's `search_fuzzy`. Candidates come from FTS5's own
  /// vocabulary table, so a correction can never suggest a word that would
  /// match nothing.
  private func correctedQuery(for query: String) -> String? {
    let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
    guard !terms.isEmpty else { return nil }

    var rebuilt: [String] = []
    var changed = false
    for term in terms {
      // Short words tolerate one edit, longer ones two — otherwise a 4-letter
      // word matches half the dictionary.
      // Mirrors the engine: longer words tolerate more edits, because a
      // porter-stemmed vocabulary entry can sit several characters from what
      // the user typed ("meeting" is stored as "meet").
      let bound = term.count <= 4 ? 1 : (term.count <= 7 ? 2 : 3)
      if let best = closestTerm(to: term, maxDistance: bound) {
        rebuilt.append(best)
        changed = true
      } else {
        rebuilt.append(term)
      }
    }
    return changed ? rebuilt.joined(separator: " ") : nil
  }

  private func closestTerm(to term: String, maxDistance: Int) -> String? {
    guard let db else { return nil }

    // Filter by length in SQL and order by document frequency: a typo is far
    // more likely to be a misspelling of a common word than a rare one.
    let sql = """
      SELECT term FROM spell_term
      WHERE length(term) BETWEEN ?1 AND ?2
      ORDER BY cnt DESC
      LIMIT 20000
      """
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
    defer { sqlite3_finalize(statement) }

    sqlite3_bind_int(statement, 1, Int32(max(1, term.count - maxDistance)))
    sqlite3_bind_int(statement, 2, Int32(term.count + maxDistance))

    let lowered = term.lowercased()
    var best: (score: Int, term: String)?
    while sqlite3_step(statement) == SQLITE_ROW {
      guard let text = sqlite3_column_text(statement, 0) else { continue }
      let candidate = String(cString: text)
      let distance = Self.editDistance(lowered, candidate, maxDistance: maxDistance)
      guard distance > 0, distance <= maxDistance else { continue }

      // Distance dominates, shared prefix breaks ties. Typos preserve opening
      // characters, which is what rescues stemmed vocabulary entries.
      let prefix = zip(lowered, candidate).prefix { $0 == $1 }.count
      let score = distance * 10 - prefix
      if best == nil || score < best!.score {
        best = (score, candidate)
      }
    }
    return best?.term
  }

  /// Bounded Levenshtein distance.
  ///
  /// Returns `maxDistance + 1` as soon as the true distance is known to exceed
  /// the bound, so most vocabulary candidates are rejected almost immediately.
  static func editDistance(_ a: String, _ b: String, maxDistance: Int) -> Int {
    let lhs = Array(a.utf8), rhs = Array(b.utf8)
    if abs(lhs.count - rhs.count) > maxDistance { return maxDistance + 1 }

    // Two rows, not a full matrix: only the previous row is ever needed.
    var previous = Array(0...rhs.count)
    var current = [Int](repeating: 0, count: rhs.count + 1)

    for i in 1...max(lhs.count, 1) where !lhs.isEmpty {
      current[0] = i
      var rowBest = i
      for j in 1...max(rhs.count, 1) where !rhs.isEmpty {
        let cost = lhs[i - 1] == rhs[j - 1] ? 0 : 1
        current[j] = min(current[j - 1] + 1, previous[j] + 1, previous[j - 1] + cost)
        rowBest = min(rowBest, current[j])
      }
      // Later rows can only increase the distance.
      if rowBest > maxDistance { return maxDistance + 1 }
      swap(&previous, &current)
    }
    return previous[rhs.count]
  }

  /// SQLite copies the bound bytes, so Swift strings need not outlive the call.
  private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

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
