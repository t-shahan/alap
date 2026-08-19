#pragma once

/// @file disconnect.hpp
/// @brief Signing an account out: forgetting the credential, then the mail.

#include <string>

#include "mailengine/result.hpp"

namespace mailengine {

/// @brief The credential half of a disconnect.
///
/// Extracted for the same dependency-inversion reason as `LabelWriter`: the
/// real implementation talks to the macOS Keychain, which cannot run in a
/// hermetic test, and the ORDER these two calls happen in is the entire safety
/// property here. A sequence whose correctness cannot be asserted is a sequence
/// that will be reordered by someone tidying up.
class CredentialRemover {
 public:
  virtual ~CredentialRemover() = default;

  /// @see Keychain::remove — succeeds when nothing was stored.
  [[nodiscard]] virtual Result<void> remove(const std::string& account_id) = 0;
};

/// @brief The mailbox half of a disconnect.
class MailboxDeleter {
 public:
  virtual ~MailboxDeleter() = default;

  /// @see PostgresStore::delete_account
  [[nodiscard]] virtual Result<void> delete_account(const std::string& account_id) = 0;
};

/// @brief Disconnects a mailbox: credential first, then the mail.
///
/// ## Why the order is not a preference
///
/// The two steps cannot be atomic — they are a Keychain call and a Postgres
/// statement. So a crash between them leaves one of exactly two states, and
/// only one of them is safe:
///
///   - **credential gone, rows present.** The account cannot authenticate, so
///     it cannot sync. The stale mail sits there until someone re-runs this.
///     Recoverable, and nothing is leaking.
///   - **rows gone, credential present.** The daemon's next poll finds a live
///     token, backfills the entire mailbox, and the disconnect silently undoes
///     itself — while the credential is still on disk, which is the one thing
///     the reader asked to be rid of.
///
/// Hence: credential first, always, and the mail is not touched if that fails.
///
/// This does NOT revoke the grant at Google. Revocation is a network call that
/// can fail, and a sign-out that depends on the network is one you cannot
/// perform on a plane. The token is gone from this machine, which is what the
/// button promises.
[[nodiscard]] Result<void> disconnect_account(CredentialRemover& credentials,
                                              MailboxDeleter& mailbox,
                                              const std::string& account_id);

}  // namespace mailengine
