/// @file store.cpp
/// @brief libpq implementation of PostgresStore.

#include "mailengine/store.hpp"

#include <libpq-fe.h>
#include <sys/select.h>

#include <cerrno>
#include <cstring>

#include <nlohmann/json.hpp>

#include "mailengine/html.hpp"
#include "mailengine/ids.hpp"

namespace mailengine {
namespace {

using nlohmann::json;

/// RAII owner for a PGresult.
///
/// Every PQexec-family call allocates a result that must be PQclear'd, on both
/// the success and failure paths. A guard removes every early-return leak.
class ResultGuard {
 public:
  explicit ResultGuard(PGresult* result) : result_(result) {}
  ~ResultGuard() {
    if (result_ != nullptr) PQclear(result_);
  }
  ResultGuard(const ResultGuard&) = delete;
  ResultGuard& operator=(const ResultGuard&) = delete;

  [[nodiscard]] PGresult* get() const noexcept { return result_; }
  [[nodiscard]] ExecStatusType status() const { return PQresultStatus(result_); }

 private:
  PGresult* result_;
};

/// Formats epoch milliseconds as a Postgres timestamptz literal.
///
/// Passing the value as `to_timestamp($n / 1000.0)` in SQL avoids any
/// client-side timezone handling — Postgres does the conversion, and the
/// column is timestamptz so it stores UTC regardless of server locale.
std::string millis_to_string(int64_t millis) {
  return std::to_string(millis);
}

/// Serialises addresses to the JSONB shape the schema and SwiftUI expect.
std::string addresses_to_json(const std::vector<mime::Address>& addresses) {
  json array = json::array();
  for (const auto& address : addresses) {
    array.push_back({{"name", address.name}, {"email", address.email}});
  }
  return array.dump();
}

}  // namespace

PostgresStore::PostgresStore() = default;

PostgresStore::~PostgresStore() {
  if (conn_ != nullptr) {
    PQfinish(static_cast<PGconn*>(conn_));
  }
}

Result<void> PostgresStore::connect(const std::string& conninfo) {
  PGconn* conn = PQconnectdb(conninfo.c_str());
  if (PQstatus(conn) != CONNECTION_OK) {
    const std::string message = PQerrorMessage(conn);
    PQfinish(conn);
    return make_error("postgres connect failed: " + message);
  }
  conn_ = conn;
  return {};
}

Result<void> PostgresStore::exec(const std::string& sql,
                                 const std::vector<std::string>& params) {
  auto* conn = static_cast<PGconn*>(conn_);
  if (conn == nullptr) {
    return make_error("not connected to postgres");
  }

  // libpq wants an array of C strings. Empty strings are passed through as
  // empty, not NULL — the schema uses NOT NULL DEFAULT '' where that matters.
  std::vector<const char*> values;
  values.reserve(params.size());
  for (const auto& param : params) {
    values.push_back(param.c_str());
  }

  const ResultGuard result(PQexecParams(
      conn, sql.c_str(), static_cast<int>(params.size()), nullptr,
      values.empty() ? nullptr : values.data(), nullptr, nullptr, 0));

  const ExecStatusType status = result.status();
  if (status != PGRES_COMMAND_OK && status != PGRES_TUPLES_OK) {
    return make_error(std::string("query failed: ") + PQerrorMessage(conn));
  }
  return {};
}

Result<void> PostgresStore::transaction(const std::function<Result<void>()>& fn) {
  if (auto begun = exec("BEGIN"); !begun) {
    return begun.error();
  }
  auto outcome = fn();
  if (!outcome) {
    (void)exec("ROLLBACK");
    return outcome.error();
  }
  return exec("COMMIT");
}

Result<StoredAccount> PostgresStore::upsert_account(const std::string& account_id,
                                                    const std::string& email_address,
                                                    const std::string& color) {
  // ON CONFLICT DO UPDATE deliberately does NOT touch last_history_id: a
  // re-authorization must not silently reset the sync watermark and trigger a
  // full 31k-message backfill.
  auto written = exec(
      R"(INSERT INTO account (id, email_address, display_name, provider, color)
         VALUES ($1, $2, $2, 'gmail', $3)
         ON CONFLICT (id) DO UPDATE
           SET email_address = EXCLUDED.email_address,
               disconnected_at = NULL)",
      {account_id, email_address, color});
  if (!written) {
    return written.error();
  }

  auto account = get_account(account_id);
  if (!account) {
    return account.error();
  }
  if (!account->has_value()) {
    return make_error("account vanished immediately after upsert");
  }
  return **account;
}

Result<std::optional<StoredAccount>> PostgresStore::get_account(
    const std::string& account_id) {
  auto* conn = static_cast<PGconn*>(conn_);
  if (conn == nullptr) {
    return make_error("not connected to postgres");
  }

  const char* values[] = {account_id.c_str()};
  const ResultGuard result(PQexecParams(
      conn,
      "SELECT id, email_address, COALESCE(last_history_id, '') FROM account WHERE id = $1",
      1, nullptr, values, nullptr, nullptr, 0));

  if (result.status() != PGRES_TUPLES_OK) {
    return make_error(std::string("get_account failed: ") + PQerrorMessage(conn));
  }
  if (PQntuples(result.get()) == 0) {
    return std::optional<StoredAccount>{};
  }

  return std::optional<StoredAccount>{StoredAccount{
      .id = PQgetvalue(result.get(), 0, 0),
      .email_address = PQgetvalue(result.get(), 0, 1),
      .last_history_id = PQgetvalue(result.get(), 0, 2),
  }};
}

Result<void> PostgresStore::upsert_labels(const std::string& account_id,
                                          const std::vector<GmailLabel>& labels) {
  return transaction([&]() -> Result<void> {
    int order = 0;
    for (const auto& label : labels) {
      auto written = exec(
          R"(INSERT INTO label (id, account_id, remote_id, name, kind, sort_order)
             VALUES ($1, $2, $3, $4, $5::label_kind, $6)
             ON CONFLICT (id) DO UPDATE
               SET name = EXCLUDED.name, sort_order = EXCLUDED.sort_order)",
          {ids::label(account_id, label.id), account_id, label.id, label.name,
           label.type == "system" ? "system" : "user", std::to_string(order++)});
      if (!written) {
        return written.error();
      }
    }
    return Result<void>{};
  });
}

Result<void> PostgresStore::upsert_message(const std::string& account_id,
                                           const GmailMessage& message,
                                           bool write_body) {
  const std::string thread_id = ids::thread(account_id, message.thread_id);
  const std::string message_id = ids::message(account_id, message.id);
  const std::string sent_at = millis_to_string(message.internal_date_ms);

  return transaction([&]() -> Result<void> {
    // 1. The thread must exist before the message can reference it. Aggregates
    //    are placeholders here; refresh_thread computes the real values once
    //    all of this thread's messages are present.
    auto thread_written = exec(
        R"(INSERT INTO thread
             (id, account_id, remote_thread_id, subject, snippet, participants,
              last_message_at, message_count, unread_count)
           VALUES ($1, $2, $3, $4, $5, $6::jsonb, to_timestamp($7::bigint / 1000.0), 0, 0)
           ON CONFLICT (id) DO NOTHING)",
        {thread_id, account_id, message.thread_id, message.subject, message.snippet,
         addresses_to_json({message.from}), sent_at});
    if (!thread_written) return thread_written.error();

    // 2. The message itself.
    auto message_written = exec(
        R"(INSERT INTO message
             (id, account_id, thread_id, remote_message_id, rfc822_message_id,
              from_name, from_email, to_recipients, cc_recipients, bcc_recipients,
              subject, snippet, sent_at, is_read, is_starred, is_draft,
              has_attachments, size_bytes)
           VALUES ($1,$2,$3,$4,$5,$6,$7,$8::jsonb,$9::jsonb,$10::jsonb,$11,$12,
                   to_timestamp($13::bigint / 1000.0),$14,$15,$16,$17,$18)
           ON CONFLICT (id) DO UPDATE
             SET is_read = EXCLUDED.is_read,
                 is_starred = EXCLUDED.is_starred,
                 snippet = EXCLUDED.snippet)",
        {message_id, account_id, thread_id, message.id, message.rfc822_message_id,
         message.from.name, message.from.email, addresses_to_json(message.to),
         addresses_to_json(message.cc), addresses_to_json(message.bcc),
         message.subject, message.snippet, sent_at,
         message.is_unread() ? "f" : "t", message.is_starred() ? "t" : "f",
         message.is_draft() ? "t" : "f",
         message.attachments.empty() ? "f" : "t",
         std::to_string(message.size_estimate)});
    if (!message_written) return message_written.error();

    // 3. Body, when requested. Backfill defers this so the list view is usable
    //    long before every body has downloaded.
    //
    //    HTML is sanitised HERE, on the way in, rather than at render time.
    //    Sanitising once per message on ingest costs nothing noticeable;
    //    sanitising on every render would put a parser on the UI path. It also
    //    means the guarantee holds for every reader of the table — the Swift
    //    app today, anything else later — rather than depending on each one
    //    remembering to do it.
    std::string safe_html;
    if (write_body && !message.html_body.empty()) {
      safe_html = html::sanitize(message.html_body).html;
    }
    if (write_body) {
      auto body_written = exec(
          R"(INSERT INTO message_body (message_id, account_id, text_body, html_body)
             VALUES ($1, $2, $3, $4)
             ON CONFLICT (message_id) DO UPDATE
               SET text_body = EXCLUDED.text_body,
                   html_body = EXCLUDED.html_body,
                   fetched_at = now())",
          {message_id, account_id, message.text_body, safe_html});
      if (!body_written) return body_written.error();
    }

    // 4. Labels. Gmail is authoritative, so links it no longer reports are
    //    removed — that is how an archive done in the web UI reaches us.
    //    Deleting fires the counter trigger, keeping badges correct.
    auto cleared = exec("DELETE FROM message_label WHERE message_id = $1", {message_id});
    if (!cleared) return cleared.error();

    for (const auto& label_id : message.label_ids) {
      const std::string full_label_id = ids::label(account_id, label_id);
      // Skip labels we have never seen; a foreign-key violation would abort
      // the whole transaction over a label Gmail added since our last sync.
      auto linked = exec(
          R"(INSERT INTO message_label (id, account_id, message_id, label_id)
             SELECT $1, $2, $3, $4
             WHERE EXISTS (SELECT 1 FROM label WHERE id = $4)
             ON CONFLICT (id) DO NOTHING)",
          {ids::message_label(message_id, full_label_id), account_id, message_id,
           full_label_id});
      if (!linked) return linked.error();
    }

    // 5. Attachment metadata. Bytes stay on disk; only the path lands here.
    for (const auto& attachment : message.attachments) {
      if (attachment.attachment_id.empty()) continue;
      auto written = exec(
          R"(INSERT INTO attachment
               (id, account_id, message_id, filename, mime_type, size_bytes,
                content_id, is_inline, remote_attachment_id)
             VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9)
             ON CONFLICT (id) DO NOTHING)",
          {ids::attachment(message_id, attachment.attachment_id), account_id,
           message_id, attachment.filename, attachment.mime_type,
           std::to_string(attachment.size_bytes), attachment.content_id,
           attachment.is_inline ? "t" : "f", attachment.attachment_id});
      if (!written) return written.error();
    }

    return Result<void>{};
  });
}

Result<void> PostgresStore::refresh_thread(const std::string& thread_id) {
  // Recompute rather than maintain incrementally. ZQL has no aggregates so
  // these columns must exist, but deriving them in one statement is far easier
  // to reason about than keeping a dozen counters in step — and it cannot
  // drift, which matters when two independent writers touch these tables.
  return exec(
      R"(UPDATE thread t SET
           message_count   = agg.total,
           unread_count    = agg.unread,
           last_message_at = agg.newest,
           has_attachments = agg.attachments,
           is_starred      = agg.starred,
           subject         = COALESCE(NULLIF(agg.subject, ''), t.subject),
           snippet         = agg.snippet,
           participants    = agg.participants,
           updated_at      = now()
         FROM (
           SELECT
             m.thread_id,
             count(*)                                  AS total,
             count(*) FILTER (WHERE NOT m.is_read)     AS unread,
             max(m.sent_at)                            AS newest,
             bool_or(m.has_attachments)                AS attachments,
             bool_or(m.is_starred)                     AS starred,
             (array_agg(m.subject ORDER BY m.sent_at))[1]  AS subject,
             (array_agg(m.snippet ORDER BY m.sent_at DESC))[1] AS snippet,
             to_jsonb(
               array_agg(DISTINCT jsonb_build_object('name', m.from_name,
                                                     'email', m.from_email))
             )                                          AS participants
           FROM message m
           WHERE m.thread_id = $1
           GROUP BY m.thread_id
         ) agg
         WHERE t.id = agg.thread_id)",
      {thread_id});
}

Result<void> PostgresStore::delete_message(const std::string& account_id,
                                           const std::string& remote_message_id) {
  // ON DELETE CASCADE clears body, labels and attachments.
  return exec("DELETE FROM message WHERE id = $1",
              {ids::message(account_id, remote_message_id)});
}

Result<void> PostgresStore::set_history_id(const std::string& account_id,
                                           const std::string& history_id) {
  return exec(
      "UPDATE account SET last_history_id = $2, last_synced_at = now() WHERE id = $1",
      {account_id, history_id});
}

Result<std::vector<std::vector<std::string>>> PostgresStore::query(
    const std::string& sql, const std::vector<std::string>& params) {
  auto* conn = static_cast<PGconn*>(conn_);
  if (conn == nullptr) return make_error("not connected to postgres");

  std::vector<const char*> values;
  values.reserve(params.size());
  for (const auto& param : params) values.push_back(param.c_str());

  const ResultGuard result(PQexecParams(
      conn, sql.c_str(), static_cast<int>(params.size()), nullptr,
      values.empty() ? nullptr : values.data(), nullptr, nullptr, 0));

  if (result.status() != PGRES_TUPLES_OK) {
    return make_error(std::string("query failed: ") + PQerrorMessage(conn));
  }

  std::vector<std::vector<std::string>> rows;
  const int row_count = PQntuples(result.get());
  const int column_count = PQnfields(result.get());
  rows.reserve(static_cast<size_t>(row_count));

  for (int r = 0; r < row_count; ++r) {
    std::vector<std::string> row;
    row.reserve(static_cast<size_t>(column_count));
    for (int c = 0; c < column_count; ++c) {
      // NULL and empty string both surface as empty; no column read here is
      // nullable in a way that distinction matters.
      row.emplace_back(PQgetisnull(result.get(), r, c) ? ""
                                                       : PQgetvalue(result.get(), r, c));
    }
    rows.push_back(std::move(row));
  }
  return rows;
}

Result<std::vector<StoredAccount>> PostgresStore::list_accounts() {
  auto rows = query(
      R"(SELECT id, email_address, COALESCE(last_history_id, '')
         FROM account
         WHERE disconnected_at IS NULL
         ORDER BY sort_order, created_at)",
      {});
  if (!rows) return rows.error();

  std::vector<StoredAccount> accounts;
  accounts.reserve(rows->size());
  for (const auto& row : *rows) {
    if (row.size() < 3) continue;
    accounts.push_back(StoredAccount{
        .id = row[0], .email_address = row[1], .last_history_id = row[2]});
  }
  return accounts;
}

Result<void> PostgresStore::listen(const std::string& channel) {
  // The channel name cannot be parameterised — LISTEN takes an identifier, not
  // a value — so it is restricted to a conservative character set rather than
  // escaped. Every caller passes a compile-time constant; this exists so that
  // stays true.
  for (const char c : channel) {
    const bool safe = (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_';
    if (!safe) {
      return make_error("unsafe NOTIFY channel name: " + channel);
    }
  }
  return exec("LISTEN " + channel, {});
}

Result<bool> PostgresStore::wait_for_notification(int timeout_ms) {
  auto* conn = static_cast<PGconn*>(conn_);
  if (conn == nullptr) {
    return make_error("not connected");
  }

  // A notification may already be buffered from a previous round trip, in
  // which case sleeping on the socket would miss it entirely and stall until
  // the timeout.
  if (PGnotify* pending = PQnotifies(conn); pending != nullptr) {
    PQfreemem(pending);
    return true;
  }

  const int fd = PQsocket(conn);
  if (fd < 0) {
    return make_error("connection has no socket");
  }

  fd_set readable;
  FD_ZERO(&readable);
  FD_SET(fd, &readable);
  timeval tv{.tv_sec = timeout_ms / 1000,
             .tv_usec = (timeout_ms % 1000) * 1000};

  const int ready = ::select(fd + 1, &readable, nullptr, nullptr, &tv);
  if (ready < 0) {
    // EINTR is not a failure — a signal arrived. Report it as a timeout so the
    // caller loops round and re-checks its work queue.
    if (errno == EINTR) {
      return false;
    }
    return make_error(std::string("select failed: ") + std::strerror(errno));
  }
  if (ready == 0) {
    return false;  // timed out; the caller polls anyway
  }

  if (PQconsumeInput(conn) == 0) {
    return make_error(std::string("connection lost: ") + PQerrorMessage(conn));
  }

  // Drain every queued notification. Several clicks in quick succession
  // produce several NOTIFYs, and one drain pass handles all of the work they
  // represent, so leaving the rest queued would spin the loop pointlessly.
  bool notified = false;
  while (PGnotify* note = PQnotifies(conn)) {
    PQfreemem(note);
    notified = true;
  }
  return notified;
}

Result<PostgresStore::PendingAttachment> PostgresStore::attachment_for_download(
    const std::string& attachment_id) {
  auto rows = query(
      R"(SELECT a.id, m.remote_message_id, COALESCE(a.remote_attachment_id, ''),
                a.filename, a.mime_type, a.size_bytes,
                COALESCE(a.content_hash, ''), COALESCE(a.local_path, '')
         FROM attachment a
         JOIN message m ON m.id = a.message_id
         WHERE a.id = $1)",
      {attachment_id});
  if (!rows) return rows.error();
  if (rows->empty()) {
    // A row that does not exist will never exist; this must not be retried.
    return make_error("no such attachment: " + attachment_id, 404);
  }

  const auto& row = rows->front();
  PendingAttachment pending{
      .id = row[0],
      .remote_message_id = row[1],
      .remote_attachment_id = row[2],
      .filename = row[3],
      .mime_type = row[4],
      .size_bytes = std::stoll(row[5]),
      .content_hash = row[6],
      .local_path = row[7],
  };

  if (pending.remote_attachment_id.empty()) {
    // Gmail inlines very small parts directly in the message body instead of
    // exposing an attachment id. Those have nothing to fetch.
    return make_error("attachment has no remote id: " + attachment_id, 404);
  }
  return pending;
}

Result<void> PostgresStore::record_attachment_download(
    const std::string& attachment_id, const std::string& content_hash,
    const std::string& local_path, int64_t size_bytes) {
  // size_bytes is refreshed from what was actually downloaded. Gmail's
  // reported part size counts the base64 encoding for some part types, so the
  // metadata captured at sync time can overstate the real file.
  return exec(
      R"(UPDATE attachment
         SET content_hash = $2, local_path = $3, size_bytes = $4,
             downloaded_at = now()
         WHERE id = $1)",
      {attachment_id, content_hash, local_path, std::to_string(size_bytes)});
}

Result<std::vector<PostgresStore::OutboxItem>> PostgresStore::claim_outbox(
    const std::string& account_id, int limit) {
  // FOR UPDATE SKIP LOCKED is the whole trick. Rows are selected and marked
  // in_flight atomically, and any row another transaction already holds is
  // skipped rather than waited on — so concurrent drainers never collide and
  // never block each other.
  auto rows = query(
      R"(UPDATE outbox SET status = 'in_flight',
                           attempts = attempts + 1,
                           updated_at = now()
         WHERE id IN (
           SELECT id FROM outbox
           WHERE status = 'pending' AND account_id = $1
           ORDER BY created_at
           FOR UPDATE SKIP LOCKED
           LIMIT $2
         )
         RETURNING id, op::text, payload::text, attempts)",
      {account_id, std::to_string(limit)});
  if (!rows) return rows.error();

  std::vector<OutboxItem> items;
  items.reserve(rows->size());
  for (const auto& row : *rows) {
    if (row.size() < 4) continue;
    items.push_back(OutboxItem{
        .id = row[0], .op = row[1], .payload = row[2], .attempts = std::stoi(row[3])});
  }
  return items;
}

Result<void> PostgresStore::complete_outbox(const std::string& outbox_id) {
  return exec(
      "UPDATE outbox SET status = 'done', last_error = NULL, updated_at = now() "
      "WHERE id = $1",
      {outbox_id});
}

Result<void> PostgresStore::fail_outbox(const std::string& outbox_id,
                                        const std::string& error, bool permanent) {
  // Back to 'pending' means the next drain picks it up again. 'failed' is
  // terminal and surfaces in the UI through the outbox.unresolved query, so a
  // permanently failed archive is visible rather than silently lost.
  return exec(
      "UPDATE outbox SET status = $2::outbox_status, last_error = $3, "
      "updated_at = now() WHERE id = $1",
      {outbox_id, permanent ? "failed" : "pending", error});
}

Result<int64_t> PostgresStore::count_messages(const std::string& account_id) {
  auto* conn = static_cast<PGconn*>(conn_);
  if (conn == nullptr) return make_error("not connected to postgres");

  const char* values[] = {account_id.c_str()};
  const ResultGuard result(PQexecParams(
      conn, "SELECT count(*) FROM message WHERE account_id = $1", 1, nullptr, values,
      nullptr, nullptr, 0));

  if (result.status() != PGRES_TUPLES_OK) {
    return make_error(std::string("count failed: ") + PQerrorMessage(conn));
  }
  return static_cast<int64_t>(std::stoll(PQgetvalue(result.get(), 0, 0)));
}

Result<bool> PostgresStore::has_message(const std::string& account_id,
                                        const std::string& remote_message_id) {
  auto* conn = static_cast<PGconn*>(conn_);
  if (conn == nullptr) return make_error("not connected to postgres");

  const std::string id = ids::message(account_id, remote_message_id);
  const char* values[] = {id.c_str()};
  const ResultGuard result(PQexecParams(
      conn, "SELECT 1 FROM message WHERE id = $1", 1, nullptr, values, nullptr,
      nullptr, 0));

  if (result.status() != PGRES_TUPLES_OK) {
    return make_error(std::string("has_message failed: ") + PQerrorMessage(conn));
  }
  return PQntuples(result.get()) > 0;
}

}  // namespace mailengine
