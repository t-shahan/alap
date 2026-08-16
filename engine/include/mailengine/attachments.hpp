/// @file attachments.hpp
/// @brief Content-addressed on-disk storage for attachment bytes.
///
/// ## Why the bytes are not in Postgres
///
/// Everything written to Postgres is picked up by logical replication, shipped
/// to zero-cache, materialised into its SQLite replica, and diffed on every
/// sync. That pipeline is what makes reads instant, and it is sized for rows,
/// not for a 40 MB PDF. Postgres therefore stores only a path; this class owns
/// the bytes.
///
/// ## Why the path is a hash rather than the filename
///
/// Filenames arrive from email, which means they are attacker-controlled. An
/// attachment called `../../../../.ssh/authorized_keys` is a genuine attack,
/// and defending it by sanitising the name is a blocklist that eventually
/// misses a case. Deriving the path from a digest we compute ourselves makes
/// path traversal structurally impossible: the output alphabet is `[0-9a-f]`,
/// so there is no separator to smuggle in.
///
/// It also deduplicates. Most attachments in a real mailbox are inline
/// signature logos repeated across hundreds of messages; identical bytes
/// collapse onto one file. And because the name *is* the digest, verifying an
/// existing blob is just re-hashing it.
///
/// The human-readable filename lives in Postgres and is applied only when the
/// file is presented to the user.

#pragma once

#include <cstdint>
#include <filesystem>
#include <string>

#include "mailengine/result.hpp"

namespace mailengine {

/// @brief A blob that is now durably on disk.
struct StoredBlob {
  /// Lowercase hex SHA-256 of the contents. Also the filename.
  std::string content_hash;
  /// Absolute path to the blob.
  std::string path;
  int64_t size_bytes = 0;
  /// False when an identical blob was already present and nothing was written.
  bool newly_written = false;
};

/// @brief Stores attachment payloads under a content-addressed root.
class AttachmentStore {
 public:
  /// @param root Directory to store blobs under; created on demand.
  explicit AttachmentStore(std::filesystem::path root);

  /// @brief Writes `bytes`, returning where they landed.
  ///
  /// Idempotent: storing identical bytes twice writes once and reports
  /// `newly_written == false` the second time.
  [[nodiscard]] Result<StoredBlob> put(const std::string& bytes) const;

  /// @brief Path a blob with this hash would occupy. Does not check existence.
  ///
  /// `hash` must be a 64-character lowercase hex digest. Anything else is
  /// rejected — this is the single place where a caller could otherwise
  /// reintroduce path traversal by passing through a value from the database.
  [[nodiscard]] Result<std::string> path_for(const std::string& hash) const;

  /// @brief Whether a blob with this hash is present on disk.
  [[nodiscard]] bool contains(const std::string& hash) const;

  /// @brief Removes a blob. Absent blobs are not an error.
  [[nodiscard]] Result<void> remove(const std::string& hash) const;

  /// @brief Total bytes currently stored.
  [[nodiscard]] Result<int64_t> total_bytes() const;

  const std::filesystem::path& root() const { return root_; }

  /// @brief The default location: `~/Library/Caches/Alap/Attachments`.
  ///
  /// Caches rather than Application Support because every blob is
  /// re-downloadable from Gmail. That keeps hundreds of megabytes of
  /// recoverable data out of Time Machine and lets macOS reclaim the space
  /// under pressure.
  ///
  /// The consequence is that a `local_path` recorded in Postgres can dangle,
  /// so readers must treat a missing file as "not downloaded" rather than
  /// trusting the database. `contains()` is how they check.
  ///
  /// Overridable with `MAILENGINE_ATTACHMENT_DIR`.
  [[nodiscard]] static std::string default_root();

 private:
  std::filesystem::path root_;
};

}  // namespace mailengine
