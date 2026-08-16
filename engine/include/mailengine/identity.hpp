/// @file identity.hpp
/// @brief The application's identity, and migration from its former one.
///
/// These strings were previously copy-pasted across six files, which is how a
/// rename half-lands: the Keychain moves but the cache does not, and the app
/// silently stops finding data it still has.
///
/// Three of them are load-bearing in a way that is easy to underestimate:
///
///   - `keychain_service()` names the Keychain item holding each account's
///     OAuth refresh token. Change it without migrating and every account is
///     silently disconnected, needing re-authorisation.
///   - `app_support_dir()` holds the FTS5 search index — 320 MB and several
///     minutes to rebuild on a real mailbox.
///   - `cache_dir()` holds downloaded attachments, and Postgres stores
///     ABSOLUTE paths into it. Moving the directory without updating those rows
///     leaves every attachment looking un-downloaded.
///
/// `migrate_from_legacy()` handles all three. It is idempotent and safe to call
/// on every startup.

#pragma once

#include <string>
#include <vector>

#include "mailengine/result.hpp"

namespace mailengine::identity {

/// Reverse-DNS bundle identifier, and the Keychain service name.
[[nodiscard]] const std::string& keychain_service();

/// `~/Library/Application Support/Alap` — the search index lives here.
///
/// Product-named rather than reverse-DNS because the user sees this path when
/// they go looking for it, and `dev.local.mailapp` tells them nothing.
[[nodiscard]] std::string app_support_dir();

/// `~/Library/Caches/Alap` — downloaded attachments live here.
///
/// Caches rather than Application Support because every blob is re-downloadable
/// from Gmail, which keeps hundreds of megabytes of recoverable data out of
/// Time Machine.
[[nodiscard]] std::string cache_dir();

/// @brief Number of things moved by `migrate_from_legacy`.
struct MigrationReport {
  bool moved_app_support = false;
  bool moved_cache = false;
  int migrated_keychain_items = 0;
  /// Attachment rows whose stored path was rewritten.
  int64_t rewritten_paths = 0;
};

/// @brief Moves data from the pre-rename locations, if any remain.
///
/// Idempotent: once nothing is left at the old locations this does nothing and
/// costs two `stat` calls.
///
/// @param account_ids Accounts whose Keychain item should be migrated. The
///        Keychain cannot be enumerated by service alone without prompting, so
///        the caller supplies the ids it already knows about.
[[nodiscard]] Result<MigrationReport> migrate_from_legacy(
    const std::vector<std::string>& account_ids);

/// The identifier used before the app was named. Exposed for the migration and
/// for tests; nothing else should reference it.
[[nodiscard]] const std::string& legacy_identifier();

}  // namespace mailengine::identity
