/// @file test_outbox.cpp
/// @brief Outbox drainer: API translation and failure classification.
///
/// This code decides whether a user's archive is retried or permanently
/// abandoned, and it runs against their real mailbox. It was previously
/// verified only by hand.
///
/// `apply` needs a `LabelWriter` and nothing else, so these run with no
/// network, no Postgres and no account.

#include <gtest/gtest.h>

#include <filesystem>
#include <optional>
#include <string>
#include <vector>

#include "mailengine/outbox.hpp"

using namespace mailengine;

namespace {

/// Records what it was asked to do and returns a programmed outcome.
class FakeLabelWriter : public LabelWriter {
 public:
  struct Call {
    std::vector<std::string> message_ids;
    std::vector<std::string> add_labels;
    std::vector<std::string> remove_labels;
  };

  /// When set, every call fails with this error instead of succeeding.
  std::optional<Error> programmed_error;
  std::vector<Call> calls;

  Result<void> batch_modify(const std::vector<std::string>& message_ids,
                            const std::vector<std::string>& add_labels,
                            const std::vector<std::string>& remove_labels) override {
    calls.push_back(Call{message_ids, add_labels, remove_labels});
    if (programmed_error) {
      return *programmed_error;
    }
    return Result<void>{};
  }
};

/// Builds a claimed row as `claim_outbox` would return it.
PostgresStore::OutboxItem item(const std::string& op, const std::string& payload,
                               int attempts = 1) {
  return PostgresStore::OutboxItem{
      .id = "outbox-1", .op = op, .payload = payload, .attempts = attempts};
}

constexpr const char* kArchivePayload =
    R"({"messageIds":["m1","m2"],"addLabelIds":[],"removeLabelIds":["INBOX"]})";

/// A drainer needs a store reference it never touches in these tests, since
/// `apply` performs no persistence.
PostgresStore& unused_store() {
  static PostgresStore store;
  return store;
}

}  // namespace

// MARK: - Operation translation

TEST(OutboxApply, ArchiveBecomesRemoveInboxLabel) {
  FakeLabelWriter api;
  OutboxDrainer drainer(api, unused_store(), "acct_test");

  const auto outcome = drainer.apply(item("modify_labels", kArchivePayload));

  ASSERT_TRUE(outcome.has_value()) << outcome.error().message;
  ASSERT_EQ(api.calls.size(), 1u);
  EXPECT_EQ(api.calls[0].message_ids, (std::vector<std::string>{"m1", "m2"}));
  EXPECT_TRUE(api.calls[0].add_labels.empty());
  EXPECT_EQ(api.calls[0].remove_labels, (std::vector<std::string>{"INBOX"}));
}

TEST(OutboxApply, MarkReadTakesTheSameLabelPath) {
  // Gmail has no "mark read" verb — it is removing the UNREAD label.
  FakeLabelWriter api;
  OutboxDrainer drainer(api, unused_store(), "acct_test");

  const auto outcome = drainer.apply(item(
      "mark_read",
      R"({"messageIds":["m1"],"addLabelIds":[],"removeLabelIds":["UNREAD"]})"));

  ASSERT_TRUE(outcome.has_value());
  ASSERT_EQ(api.calls.size(), 1u);
  EXPECT_EQ(api.calls[0].remove_labels, (std::vector<std::string>{"UNREAD"}));
}

TEST(OutboxApply, StarSendsAnAddLabel) {
  FakeLabelWriter api;
  OutboxDrainer drainer(api, unused_store(), "acct_test");

  const auto outcome = drainer.apply(item(
      "modify_labels",
      R"({"messageIds":["m1"],"addLabelIds":["STARRED"],"removeLabelIds":[]})"));

  ASSERT_TRUE(outcome.has_value());
  EXPECT_EQ(api.calls[0].add_labels, (std::vector<std::string>{"STARRED"}));
}

TEST(OutboxApply, EmptyMessageListSucceedsWithoutCallingTheApi) {
  // A no-op must not be retried forever, and must not waste a request.
  FakeLabelWriter api;
  OutboxDrainer drainer(api, unused_store(), "acct_test");

  const auto outcome = drainer.apply(
      item("modify_labels", R"({"messageIds":[],"removeLabelIds":["INBOX"]})"));

  EXPECT_TRUE(outcome.has_value());
  EXPECT_TRUE(api.calls.empty());
}

TEST(OutboxApply, MissingKeysAreToleratedAsEmptyArrays) {
  FakeLabelWriter api;
  OutboxDrainer drainer(api, unused_store(), "acct_test");

  const auto outcome = drainer.apply(item("modify_labels", R"({"messageIds":["m1"]})"));

  ASSERT_TRUE(outcome.has_value());
  EXPECT_TRUE(api.calls[0].add_labels.empty());
  EXPECT_TRUE(api.calls[0].remove_labels.empty());
}

// MARK: - Rejected operations

TEST(OutboxApply, MalformedPayloadFailsAsClientError) {
  FakeLabelWriter api;
  OutboxDrainer drainer(api, unused_store(), "acct_test");

  const auto outcome = drainer.apply(item("modify_labels", "{not json"));

  ASSERT_FALSE(outcome.has_value());
  // Must be a 4xx so it fails permanently rather than retrying forever.
  EXPECT_EQ(outcome.error().code, 400);
  EXPECT_TRUE(api.calls.empty());
}

TEST(OutboxApply, UnknownOperationFailsPermanently) {
  FakeLabelWriter api;
  OutboxDrainer drainer(api, unused_store(), "acct_test");

  const auto outcome = drainer.apply(item("teleport_message", kArchivePayload));

  ASSERT_FALSE(outcome.has_value());
  EXPECT_EQ(outcome.error().code, 400);
}

TEST(OutboxApply, UnimplementedOperationsReportNotImplemented) {
  FakeLabelWriter api;
  OutboxDrainer drainer(api, unused_store(), "acct_test");

  for (const char* op : {"send", "delete_forever"}) {
    const auto outcome = drainer.apply(item(op, kArchivePayload));
    ASSERT_FALSE(outcome.has_value()) << op;
    EXPECT_EQ(outcome.error().code, 501) << op;
  }
}

TEST(OutboxApply, PropagatesApiFailure) {
  FakeLabelWriter api;
  api.programmed_error = Error{"gmail said no", 403};
  OutboxDrainer drainer(api, unused_store(), "acct_test");

  const auto outcome = drainer.apply(item("modify_labels", kArchivePayload));

  ASSERT_FALSE(outcome.has_value());
  EXPECT_EQ(outcome.error().code, 403);
}

// MARK: - Failure classification
//
// The branch table that decides retry-vs-abandon.

TEST(ClassifyAttempt, SuccessIsApplied) {
  EXPECT_EQ(classify_attempt(true, 0, 1, 5), OutboxDisposition::Applied);
}

TEST(ClassifyAttempt, ClientErrorsFailImmediately) {
  // A bad label id or deleted message fails identically on every attempt.
  // Retrying only delays the user finding out.
  for (const int code : {400, 401, 403, 404, 422, 501}) {
    EXPECT_EQ(classify_attempt(false, code, /*attempts=*/1, /*max=*/5),
              OutboxDisposition::Failed)
        << "code " << code << " should not be retried";
  }
}

TEST(ClassifyAttempt, RateLimitIsRetriedDespiteBeing4xx) {
  // 429 is the deliberate exception: it means "slow down", not "bad request".
  EXPECT_EQ(classify_attempt(false, 429, /*attempts=*/1, /*max=*/5),
            OutboxDisposition::Retry);
}

TEST(ClassifyAttempt, ServerErrorsAreRetried) {
  for (const int code : {500, 502, 503, 504}) {
    EXPECT_EQ(classify_attempt(false, code, /*attempts=*/1, /*max=*/5),
              OutboxDisposition::Retry)
        << "code " << code;
  }
}

TEST(ClassifyAttempt, TransportErrorsAreRetried) {
  // code 0 means the request never reached Gmail — a DNS failure or a dropped
  // connection. Exactly the case retries exist for.
  EXPECT_EQ(classify_attempt(false, 0, /*attempts=*/1, /*max=*/5),
            OutboxDisposition::Retry);
}

TEST(ClassifyAttempt, ExhaustedAttemptsFailEvenWhenTransient) {
  EXPECT_EQ(classify_attempt(false, 503, /*attempts=*/5, /*max=*/5),
            OutboxDisposition::Failed);
  EXPECT_EQ(classify_attempt(false, 503, /*attempts=*/6, /*max=*/5),
            OutboxDisposition::Failed);
}

TEST(ClassifyAttempt, RetriesUpToButNotIncludingTheLimit) {
  // Boundary: the fourth attempt of five still retries; the fifth does not.
  EXPECT_EQ(classify_attempt(false, 503, /*attempts=*/4, /*max=*/5),
            OutboxDisposition::Retry);
  EXPECT_EQ(classify_attempt(false, 503, /*attempts=*/5, /*max=*/5),
            OutboxDisposition::Failed);
}

// MARK: - Attachment downloads
//
// The full download path needs Postgres (it reads the attachment row and
// writes back the resulting path), so these cover the decisions `apply` makes
// BEFORE reaching the database — which are exactly the ones that decide
// whether a row is retried forever or abandoned.

namespace {

/// Returns programmed bytes, and records what was asked for.
class FakeAttachmentFetcher : public AttachmentFetcher {
 public:
  struct Call {
    std::string message_id;
    std::string attachment_id;
  };

  std::optional<Error> programmed_error;
  std::string payload = "attachment bytes";
  std::vector<Call> calls;

  Result<std::string> get_attachment(const std::string& message_id,
                                     const std::string& attachment_id) override {
    calls.push_back(Call{message_id, attachment_id});
    if (programmed_error) {
      return *programmed_error;
    }
    return payload;
  }
};

}  // namespace

TEST(OutboxApply, DownloadFailsAsUnimplementedWhenNoFetcherIsConfigured) {
  FakeLabelWriter api;
  OutboxDrainer drainer(api, unused_store(), "acct_test");

  const auto outcome = drainer.apply(item("download_attachment", R"({"attachmentId":"a1"})"));

  ASSERT_FALSE(outcome.has_value());
  // 501 rather than a generic failure: it is classified as permanent, so the
  // row fails immediately instead of burning every retry on a capability the
  // process does not have.
  EXPECT_EQ(outcome.error().code, 501);
  EXPECT_EQ(classify_attempt(false, outcome.error().code, 1, 5),
            OutboxDisposition::Failed);
}

TEST(OutboxApply, DownloadRequiresBothAFetcherAndABlobStore) {
  FakeLabelWriter api;
  FakeAttachmentFetcher fetcher;
  AttachmentStore blobs{std::filesystem::temp_directory_path() /
                        "mailengine-outbox-test"};

  // A fetcher with nowhere to put the bytes is not a usable configuration.
  OutboxDrainer no_store(api, unused_store(), "acct_test", 5,
                         {.attachments = &fetcher});
  EXPECT_EQ(no_store.apply(item("download_attachment", R"({"attachmentId":"a1"})"))
                .error()
                .code,
            501);

  // Somewhere to put bytes but no way to fetch them, likewise.
  OutboxDrainer no_fetcher(api, unused_store(), "acct_test", 5, {.blobs = &blobs});
  EXPECT_EQ(no_fetcher.apply(item("download_attachment", R"({"attachmentId":"a1"})"))
                .error()
                .code,
            501);

  EXPECT_TRUE(fetcher.calls.empty()) << "no download should have been attempted";
}

TEST(OutboxApply, DownloadWithNoAttachmentIdFailsPermanently) {
  FakeLabelWriter api;
  FakeAttachmentFetcher fetcher;
  AttachmentStore blobs{std::filesystem::temp_directory_path() /
                        "mailengine-outbox-test"};
  OutboxDrainer drainer(api, unused_store(), "acct_test", 5,
                        {.attachments = &fetcher, .blobs = &blobs});

  // An empty payload can never succeed however many times it is retried.
  const auto outcome = drainer.apply(item("download_attachment", "{}"));

  ASSERT_FALSE(outcome.has_value());
  EXPECT_EQ(outcome.error().code, 400);
  EXPECT_EQ(classify_attempt(false, outcome.error().code, 1, 5),
            OutboxDisposition::Failed);
  EXPECT_TRUE(fetcher.calls.empty());
}

TEST(OutboxApply, DownloadIsNotConfusedWithOtherOps) {
  FakeLabelWriter api;
  OutboxDrainer drainer(api, unused_store(), "acct_test");

  // A download must never reach the label API, whatever else it does.
  (void)drainer.apply(item("download_attachment", R"({"attachmentId":"a1"})"));

  EXPECT_TRUE(api.calls.empty());
}
