/// @file attachments.cpp
/// @brief Content-addressed attachment storage.

#include "mailengine/attachments.hpp"

#include <cstdlib>
#include <fstream>
#include <system_error>
#include <unistd.h>
#include <utility>

#include "mailengine/crypto.hpp"

namespace mailengine {
namespace {

/// Length of a hex-encoded SHA-256 digest.
constexpr size_t kHashLength = 64;

/// Number of leading hash characters used as a subdirectory name.
///
/// A single flat directory holding every blob works until it doesn't:
/// enumerating it degrades, and some tooling copes badly with very wide
/// directories. Two characters gives 256 buckets, which keeps a mailbox with
/// tens of thousands of attachments comfortable while staying trivial to
/// reason about by hand.
constexpr size_t kFanoutLength = 2;

/// Rejects anything that is not a 64-character lowercase hex digest.
///
/// This is the security boundary. Hashes reaching us from Postgres are treated
/// as untrusted input: if a row's `content_hash` were ever tampered with, this
/// is what stops it from becoming `../../../etc/passwd`.
bool is_valid_hash(const std::string& hash) {
  if (hash.size() != kHashLength) {
    return false;
  }
  for (const char c : hash) {
    const bool hex_digit = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f');
    if (!hex_digit) {
      return false;
    }
  }
  return true;
}

}  // namespace

AttachmentStore::AttachmentStore(std::filesystem::path root)
    : root_(std::move(root)) {}

std::string AttachmentStore::default_root() {
  if (const char* configured = std::getenv("MAILENGINE_ATTACHMENT_DIR");
      configured != nullptr && *configured != '\0') {
    return configured;
  }
  const char* home = std::getenv("HOME");
  const std::string base = home != nullptr ? home : ".";
  return base + "/Library/Caches/dev.local.mailapp/Attachments";
}

Result<std::string> AttachmentStore::path_for(const std::string& hash) const {
  if (!is_valid_hash(hash)) {
    return make_error("not a valid content hash: " + hash, 400);
  }
  const auto path =
      root_ / hash.substr(0, kFanoutLength) / hash.substr(kFanoutLength);
  return path.string();
}

bool AttachmentStore::contains(const std::string& hash) const {
  auto path = path_for(hash);
  if (!path) {
    return false;
  }
  std::error_code ec;
  return std::filesystem::is_regular_file(*path, ec);
}

Result<StoredBlob> AttachmentStore::put(const std::string& bytes) const {
  const std::string hash = crypto::hex_encode(crypto::sha256(bytes));

  auto path = path_for(hash);
  if (!path) {
    return path.error();
  }

  StoredBlob blob;
  blob.content_hash = hash;
  blob.path = *path;
  blob.size_bytes = static_cast<int64_t>(bytes.size());

  // Identical content is already here by definition — the name IS the digest.
  if (contains(hash)) {
    blob.newly_written = false;
    return blob;
  }

  std::error_code ec;
  std::filesystem::create_directories(
      std::filesystem::path(*path).parent_path(), ec);
  if (ec) {
    return make_error("could not create attachment directory: " + ec.message());
  }

  // Write to a temporary name and rename into place. A content-addressed path
  // is an assertion that the file's bytes hash to its name, so a partial write
  // left behind by a crash or a full disk would be actively harmful: every
  // later reader would trust it. rename(2) within a filesystem is atomic, so a
  // blob is either absent or complete, never half-formed.
  //
  // The pid keeps two concurrent downloads of the same attachment from
  // clobbering each other's temporary file.
  const std::string temp = *path + ".tmp." + std::to_string(::getpid());
  {
    std::ofstream out(temp, std::ios::binary | std::ios::trunc);
    if (!out) {
      return make_error("could not open attachment for writing: " + temp);
    }
    out.write(bytes.data(), static_cast<std::streamsize>(bytes.size()));
    out.flush();
    if (!out) {
      std::filesystem::remove(temp, ec);
      return make_error("could not write attachment: " + temp);
    }
  }

  std::filesystem::rename(temp, *path, ec);
  if (ec) {
    std::error_code ignored;
    std::filesystem::remove(temp, ignored);
    return make_error("could not commit attachment: " + ec.message());
  }

  blob.newly_written = true;
  return blob;
}

Result<void> AttachmentStore::remove(const std::string& hash) const {
  auto path = path_for(hash);
  if (!path) {
    return path.error();
  }
  std::error_code ec;
  std::filesystem::remove(*path, ec);
  if (ec) {
    return make_error("could not remove attachment: " + ec.message());
  }
  return Result<void>{};
}

Result<int64_t> AttachmentStore::total_bytes() const {
  std::error_code ec;
  if (!std::filesystem::exists(root_, ec)) {
    return int64_t{0};
  }

  int64_t total = 0;
  for (auto it = std::filesystem::recursive_directory_iterator(root_, ec);
       it != std::filesystem::recursive_directory_iterator(); it.increment(ec)) {
    if (ec) {
      return make_error("could not walk attachment store: " + ec.message());
    }
    if (it->is_regular_file(ec)) {
      total += static_cast<int64_t>(it->file_size(ec));
    }
  }
  return total;
}

}  // namespace mailengine
