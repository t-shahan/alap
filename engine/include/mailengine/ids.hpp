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

/// @brief `<messageId>|<gmail attachment id>`.
[[nodiscard]] inline std::string attachment(const std::string& message_id,
                                            const std::string& remote_attachment_id) {
  return message_id + kSeparator + remote_attachment_id;
}

}  // namespace mailengine::ids
