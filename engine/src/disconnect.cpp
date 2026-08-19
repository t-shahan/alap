#include "mailengine/disconnect.hpp"

namespace mailengine {

Result<void> disconnect_account(CredentialRemover& credentials, MailboxDeleter& mailbox,
                                const std::string& account_id) {
  if (auto removed = credentials.remove(account_id); !removed) {
    // The mail is deliberately left alone. Deleting it while the credential
    // survives is the one outcome that undoes itself on the next poll.
    return make_error("could not remove the stored credential: " +
                      removed.error().message);
  }

  if (auto deleted = mailbox.delete_account(account_id); !deleted) {
    // Report what state this left behind. The account cannot sync now, so
    // re-running finishes the job rather than starting it over.
    return make_error(
        "the credential is gone but the mailbox could not be deleted: " +
        deleted.error().message + "; the account cannot sync, re-run to finish");
  }

  return {};
}

}  // namespace mailengine
