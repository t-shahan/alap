/// @file keychain.hpp
/// @brief macOS Keychain storage for OAuth refresh tokens.
///
/// The refresh token is the only real secret in this system: it grants
/// long-lived access to a user's entire mailbox. It must never appear in
/// Postgres (which replicates to every client), in `.env`, or in a log line.
/// The Keychain gives it OS-level encryption at rest and per-app access
/// control.

#pragma once

#include <string>

#include "mailengine/result.hpp"

namespace mailengine {

/// @brief Stores and retrieves secrets in the login keychain.
///
/// Items are keyed by (service, account). The service is a fixed identifier
/// for this app; the account is our internal account id, so multiple mailboxes
/// coexist without collision.
class Keychain {
 public:
  /// @param service Keychain service identifier, shared by all items.
  /// @param service Defaults to `identity::keychain_service()`. Passing it
  ///        explicitly is for tests and for reading the pre-rename items.
  explicit Keychain(std::string service = {});

  /// @brief Stores or replaces a secret.
  /// @param account Our account id, e.g. `acct_dev`.
  /// @param secret The value to protect.
  [[nodiscard]] Result<void> store(const std::string& account,
                                   const std::string& secret) const;

  /// @brief Reads a secret.
  /// @return The secret, or an error when absent.
  [[nodiscard]] Result<std::string> load(const std::string& account) const;

  /// @brief Removes a secret. Succeeds even when nothing was stored.
  [[nodiscard]] Result<void> remove(const std::string& account) const;

  /// @brief Whether keychain calls in THIS PROCESS may raise a dialog.
  ///
  /// A background process must never put a modal on screen. The daemon polls
  /// every ten seconds, so an item whose ACL no longer matches the binary
  /// produced a password prompt every ten seconds — one stale credential made
  /// the machine unusable, and the prompt stole focus from whatever was in
  /// front of it.
  ///
  /// With interaction disabled the read FAILS instead of asking, which is the
  /// answer the daemon actually wants: it can report the account as needing
  /// re-authorization and stop polling it, rather than badgering someone who
  /// is in the middle of something else.
  ///
  /// Process-wide, so it is set once at start-up rather than around individual
  /// calls. Interactive commands leave it alone.
  static void set_interaction_allowed(bool allowed);

 private:
  std::string service_;
};

}  // namespace mailengine
