/// @file identity.cpp
/// @brief Application identity and one-time migration from the former one.

#include "mailengine/identity.hpp"

#include <cstdlib>
#include <filesystem>
#include <system_error>
#include <vector>

#include "mailengine/keychain.hpp"

namespace mailengine::identity {
namespace {

/// Human-facing directory name.
constexpr const char* kProductName = "Alap";

std::string home() {
  const char* value = std::getenv("HOME");
  return value != nullptr ? value : ".";
}

}  // namespace

const std::string& keychain_service() {
  static const std::string service = "app.alap.mail";
  return service;
}

const std::string& legacy_identifier() {
  static const std::string legacy = "dev.local.mailapp";
  return legacy;
}

std::string app_support_dir() {
  return home() + "/Library/Application Support/" + kProductName;
}

std::string cache_dir() { return home() + "/Library/Caches/" + kProductName; }

Result<MigrationReport> migrate_from_legacy(
    const std::vector<std::string>& account_ids) {
  MigrationReport report;
  std::error_code ec;

  // Directories are MOVED rather than copied. A copy would leave the old data
  // behind as a second, diverging source of truth — and 320 MB of stale search
  // index that nobody would ever think to delete.
  const auto move_if_present = [&](const std::string& from, const std::string& to) {
    if (!std::filesystem::exists(from, ec)) return false;
    // Refuse to clobber. If both exist the new location is already in use, and
    // overwriting it would destroy current data to restore old data.
    if (std::filesystem::exists(to, ec)) return false;

    std::filesystem::create_directories(
        std::filesystem::path(to).parent_path(), ec);
    std::filesystem::rename(from, to, ec);
    return !ec;
  };

  const std::string legacy_support =
      home() + "/Library/Application Support/" + legacy_identifier();
  const std::string legacy_cache =
      home() + "/Library/Caches/" + legacy_identifier();

  report.moved_app_support = move_if_present(legacy_support, app_support_dir());
  report.moved_cache = move_if_present(legacy_cache, cache_dir());

  // The Keychain cannot be enumerated by service without prompting, so each
  // known account is tried individually. A miss is the normal case after the
  // first run and is not an error.
  const Keychain current(keychain_service());
  const Keychain legacy(legacy_identifier());
  for (const auto& account_id : account_ids) {
    if (current.load(account_id).has_value()) continue;  // already migrated

    auto token = legacy.load(account_id);
    if (!token) continue;

    if (auto stored = current.store(account_id, *token); !stored) {
      return stored.error();
    }
    // The old item is deliberately LEFT IN PLACE. Deleting it would make this
    // migration irreversible, and a stale Keychain entry costs nothing but a
    // line in Keychain Access.
    ++report.migrated_keychain_items;
  }

  return report;
}

}  // namespace mailengine::identity
