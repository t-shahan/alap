/// @file test_disconnect.cpp
/// @brief Signing an account out, and the order that makes it safe.
///
/// This is the only irreversible operation a reader can trigger from the UI:
/// it removes a credential and deletes a mailbox from the machine. The two
/// steps cannot be atomic, so which one goes first decides what a crash
/// between them leaves behind — and that is a property no amount of reading
/// the code guarantees stays true.
///
/// Runs with no Keychain, no Postgres and no account, like the rest of this
/// suite.

#include <gtest/gtest.h>

#include <string>
#include <vector>

#include "mailengine/disconnect.hpp"

using namespace mailengine;

namespace {

/// Records the order of every step across BOTH halves.
///
/// One shared log rather than a call count each, because the assertion that
/// matters is not "both were called" but "the credential went first".
struct Journal {
  std::vector<std::string> steps;
};

class FakeCredentials : public CredentialRemover {
 public:
  explicit FakeCredentials(Journal& journal) : journal_(journal) {}

  std::optional<Error> programmed_error;
  std::vector<std::string> removed;

  Result<void> remove(const std::string& account_id) override {
    journal_.steps.push_back("credential:" + account_id);
    if (programmed_error) return Result<void>(*programmed_error);
    removed.push_back(account_id);
    return {};
  }

 private:
  Journal& journal_;
};

class FakeMailbox : public MailboxDeleter {
 public:
  explicit FakeMailbox(Journal& journal) : journal_(journal) {}

  std::optional<Error> programmed_error;
  std::vector<std::string> deleted;

  Result<void> delete_account(const std::string& account_id) override {
    journal_.steps.push_back("mailbox:" + account_id);
    if (programmed_error) return Result<void>(*programmed_error);
    deleted.push_back(account_id);
    return {};
  }

 private:
  Journal& journal_;
};

}  // namespace

TEST(Disconnect, RemovesTheCredentialBeforeTheMail) {
  // The whole safety argument in one assertion. If these ever swap, a crash in
  // between leaves a live token beside an empty mailbox, and the next poll
  // backfills everything back — a disconnect that silently reverses itself.
  Journal journal;
  FakeCredentials credentials(journal);
  FakeMailbox mailbox(journal);

  const auto result = disconnect_account(credentials, mailbox, "acct_dev");

  ASSERT_TRUE(result);
  ASSERT_EQ(journal.steps.size(), 2u);
  EXPECT_EQ(journal.steps[0], "credential:acct_dev");
  EXPECT_EQ(journal.steps[1], "mailbox:acct_dev");
}

TEST(Disconnect, ActsOnExactlyTheAccountItWasGiven) {
  // Both halves take the id separately, so a copy-paste that passed the wrong
  // one to the second call would delete a mailbox nobody asked about.
  Journal journal;
  FakeCredentials credentials(journal);
  FakeMailbox mailbox(journal);

  ASSERT_TRUE(disconnect_account(credentials, mailbox, "acct_second"));

  ASSERT_EQ(credentials.removed, std::vector<std::string>{"acct_second"});
  ASSERT_EQ(mailbox.deleted, std::vector<std::string>{"acct_second"});
}

TEST(Disconnect, LeavesTheMailAloneWhenTheCredentialCannotBeRemoved) {
  // The dangerous direction. Deleting the mail while the token survives is the
  // one outcome that undoes itself, so a failed first step must stop the
  // sequence rather than press on.
  Journal journal;
  FakeCredentials credentials(journal);
  FakeMailbox mailbox(journal);
  credentials.programmed_error = Error{"keychain refused"};

  const auto result = disconnect_account(credentials, mailbox, "acct_dev");

  EXPECT_FALSE(result);
  EXPECT_TRUE(mailbox.deleted.empty());
  ASSERT_EQ(journal.steps.size(), 1u) << "the mailbox must not be touched";
  EXPECT_NE(result.error().message.find("keychain refused"), std::string::npos);
}

TEST(Disconnect, SaysWhatSurvivedWhenTheMailCannotBeDeleted) {
  // The recoverable direction. The credential is already gone, so the account
  // cannot sync — the error has to say so, because "disconnect failed" alone
  // would suggest nothing happened when in fact half of it did.
  Journal journal;
  FakeCredentials credentials(journal);
  FakeMailbox mailbox(journal);
  mailbox.programmed_error = Error{"connection refused"};

  const auto result = disconnect_account(credentials, mailbox, "acct_dev");

  EXPECT_FALSE(result);
  EXPECT_EQ(credentials.removed.size(), 1u) << "the credential did go";
  EXPECT_NE(result.error().message.find("credential is gone"), std::string::npos);
  EXPECT_NE(result.error().message.find("re-run"), std::string::npos);
}

TEST(Disconnect, IsSafeToRunAgainAfterAPartialFailure) {
  // Keychain::remove succeeds when nothing is stored, which is what makes the
  // recovery path work: re-running finishes the job rather than failing on the
  // step that already completed.
  Journal journal;
  FakeCredentials credentials(journal);
  FakeMailbox mailbox(journal);
  mailbox.programmed_error = Error{"connection refused"};
  EXPECT_FALSE(disconnect_account(credentials, mailbox, "acct_dev"));

  mailbox.programmed_error.reset();
  EXPECT_TRUE(disconnect_account(credentials, mailbox, "acct_dev"));
  EXPECT_EQ(mailbox.deleted.size(), 1u);
}
