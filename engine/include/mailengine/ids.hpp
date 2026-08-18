/// @file ids.hpp
/// @brief Row-ID construction. CROSS-LANGUAGE CONTRACT.
///
/// These formats must match `packages/shared/src/ids.ts` exactly. Both the C++
/// engine and the TypeScript mutators write to the same tables, so a divergence
/// here produces duplicate rows that look identical to a human and are painful
/// to unpick.
///
/// If you change a format, change it in both places in the same commit.

#pragma once

#include <string>

#include "mailengine/crypto.hpp"

namespace mailengine::ids {

/// Segment separator.
///
/// `|` cannot appear in a Gmail message, thread or label id (those are
/// base64url-ish) nor in our account ids. `:` would be ambiguous, since
/// composite ids are themselves used as segments — `acct_1:INBOX` appearing
/// inside a message-label id could not be split back apart unambiguously.
inline constexpr char kSeparator = '|';

/// @brief `<accountId>|<gmail label id>` — e.g. `acct_dev|INBOX`.
[[nodiscard]] inline std::string label(const std::string& account,
                                       const std::string& remote_label_id) {
  return account + kSeparator + remote_label_id;
}

/// @brief `<accountId>|<gmail thread id>`.
[[nodiscard]] inline std::string thread(const std::string& account,
                                        const std::string& remote_thread_id) {
  return account + kSeparator + remote_thread_id;
}

/// @brief `<accountId>|<gmail message id>`.
[[nodiscard]] inline std::string message(const std::string& account,
                                         const std::string& remote_message_id) {
  return account + kSeparator + remote_message_id;
}

/// @brief `<messageId>|<labelId>` for the junction table.
///
/// Derived rather than random so applying the same label twice is idempotent.
[[nodiscard]] inline std::string message_label(const std::string& message_id,
                                               const std::string& label_id) {
  return message_id + kSeparator + label_id;
}

/// @brief `<messageId>|<digest of the part's identity>`.
///
/// NOT derived from Gmail's `attachmentId`, which is ephemeral: fetching the
/// same message twice seconds apart returns different ids for the same part.
/// With that in the key, every sync inserted a new row instead of updating one
/// — 7,350 surplus rows of 9,175 in a real mailbox, and a resume that appeared
/// to carry five identical copies of itself.
///
/// Derived from what actually identifies a part instead: its filename, its
/// size and its Content-ID. Two genuinely identical attachments on one message
/// collapse to a single row, which is a fair trade against the alternative of
/// keying on position — position and a SQL migration cannot be made to agree,
/// so a re-sync would rewrite one part's metadata over another's.
///
/// The message id stays a literal prefix so a row is still traceable by eye in
/// a log line.
[[nodiscard]] inline std::string attachment(const std::string& message_id,
                                            const std::string& filename,
                                            int64_t size_bytes,
                                            const std::string& content_id) {
  // Unit Separator rather than NUL: the same digest has to be reproducible in
  // SQL for the migration that re-keys existing rows, and Postgres text cannot
  // contain a NUL byte. US cannot appear in a filename or a Content-ID.
  const std::string identity = filename + '\x1f' + std::to_string(size_bytes) +
                               '\x1f' + content_id;
  return message_id + kSeparator +
         crypto::hex_encode(crypto::sha256(identity)).substr(0, 32);
}

}  // namespace mailengine::ids
