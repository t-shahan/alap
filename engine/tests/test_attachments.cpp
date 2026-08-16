/// @file test_attachments.cpp
/// @brief Content-addressed attachment storage.
///
/// The traversal cases are the point of this file. Attachment filenames come
/// from email and are attacker-controlled, and the store's whole defence is
/// that a path is derived from a digest we compute rather than from anything a
/// sender supplies. These tests assert that the defence cannot be bypassed by
/// feeding a hostile value in through `path_for`, which is the one entry point
/// that accepts a hash from outside.

#include <gtest/gtest.h>

#include <filesystem>
#include <fstream>
#include <string>

#include "mailengine/attachments.hpp"
#include "mailengine/crypto.hpp"

using namespace mailengine;

namespace {

/// A store rooted in a unique temp directory, cleaned up on destruction.
class TempStore {
 public:
  TempStore()
      : root_(std::filesystem::temp_directory_path() /
              ("mailengine-attach-test-" + std::to_string(::getpid()) + "-" +
               std::to_string(counter_++))),
        store_(root_) {}

  ~TempStore() {
    std::error_code ec;
    std::filesystem::remove_all(root_, ec);
  }

  TempStore(const TempStore&) = delete;
  TempStore& operator=(const TempStore&) = delete;

  const AttachmentStore& store() const { return store_; }
  const std::filesystem::path& root() const { return root_; }

 private:
  static inline int counter_ = 0;
  std::filesystem::path root_;
  AttachmentStore store_;
};

std::string readFile(const std::string& path) {
  std::ifstream in(path, std::ios::binary);
  return std::string(std::istreambuf_iterator<char>(in), {});
}

}  // namespace

// MARK: - Round trip

TEST(AttachmentStore, StoresAndReadsBackExactly) {
  TempStore temp;
  const std::string payload = "%PDF-1.4\nnot really a pdf\n";

  const auto blob = temp.store().put(payload);
  ASSERT_TRUE(blob.has_value()) << blob.error().message;
  EXPECT_TRUE(blob->newly_written);
  EXPECT_EQ(blob->size_bytes, static_cast<int64_t>(payload.size()));
  EXPECT_EQ(readFile(blob->path), payload);
}

TEST(AttachmentStore, HandlesBinaryContentIncludingNulBytes) {
  TempStore temp;
  // A PNG header — embedded NULs would truncate anything treating this as a
  // C string.
  const std::string payload("\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR", 21);

  const auto blob = temp.store().put(payload);
  ASSERT_TRUE(blob.has_value());
  EXPECT_EQ(blob->size_bytes, 21);
  EXPECT_EQ(readFile(blob->path), payload);
}

TEST(AttachmentStore, HandlesEmptyContent) {
  TempStore temp;
  const auto blob = temp.store().put("");
  ASSERT_TRUE(blob.has_value());
  EXPECT_EQ(blob->size_bytes, 0);
  EXPECT_TRUE(temp.store().contains(blob->content_hash));
}

// MARK: - Content addressing

TEST(AttachmentStore, NameIsTheSha256OfTheContent) {
  TempStore temp;
  const std::string payload = "hello";

  const auto blob = temp.store().put(payload);
  ASSERT_TRUE(blob.has_value());
  EXPECT_EQ(blob->content_hash, crypto::hex_encode(crypto::sha256(payload)));
}

TEST(AttachmentStore, IdenticalContentIsStoredOnce) {
  TempStore temp;
  // The real case: the same signature logo inlined into hundreds of messages.
  const std::string logo = "\x89PNG fake logo bytes";

  const auto first = temp.store().put(logo);
  const auto second = temp.store().put(logo);
  ASSERT_TRUE(first.has_value());
  ASSERT_TRUE(second.has_value());

  EXPECT_TRUE(first->newly_written);
  EXPECT_FALSE(second->newly_written) << "identical bytes were written twice";
  EXPECT_EQ(first->path, second->path);
}

TEST(AttachmentStore, DifferentContentGetsDifferentPaths) {
  TempStore temp;
  const auto a = temp.store().put("invoice A");
  const auto b = temp.store().put("invoice B");
  ASSERT_TRUE(a.has_value());
  ASSERT_TRUE(b.has_value());
  EXPECT_NE(a->path, b->path);
}

TEST(AttachmentStore, FansOutAcrossSubdirectoriesRatherThanOneFlatDirectory) {
  TempStore temp;
  const auto blob = temp.store().put("something");
  ASSERT_TRUE(blob.has_value());

  const auto relative =
      std::filesystem::relative(blob->path, temp.root()).string();
  // "ab/cdef…" — one level of fanout, not a single flat directory.
  EXPECT_EQ(relative.find('/'), 2u) << "unexpected layout: " << relative;
}

// MARK: - Path traversal
//
// `path_for` is the only place a value from outside becomes a filesystem path.

TEST(AttachmentStore, RejectsRelativeTraversalInAHash) {
  TempStore temp;
  for (const char* hostile : {"../../../../etc/passwd",
                              "..",
                              "../",
                              "a/../../../../../../etc/passwd"}) {
    EXPECT_FALSE(temp.store().path_for(hostile).has_value()) << hostile;
  }
}

TEST(AttachmentStore, RejectsAbsolutePathsAndSeparators) {
  TempStore temp;
  for (const char* hostile : {"/etc/passwd", "/", "abc/def", "abc\\def"}) {
    EXPECT_FALSE(temp.store().path_for(hostile).has_value()) << hostile;
  }
}

TEST(AttachmentStore, RejectsAnythingThatIsNotSixtyFourHexCharacters) {
  TempStore temp;
  const std::string valid(64, 'a');
  EXPECT_TRUE(temp.store().path_for(valid).has_value());

  EXPECT_FALSE(temp.store().path_for("").has_value());
  EXPECT_FALSE(temp.store().path_for(std::string(63, 'a')).has_value());
  EXPECT_FALSE(temp.store().path_for(std::string(65, 'a')).has_value());
  // Uppercase is rejected rather than folded: APFS is case-insensitive by
  // default, so accepting both cases would let two distinct hashes name the
  // same file.
  EXPECT_FALSE(temp.store().path_for(std::string(64, 'A')).has_value());
  // 'g' is outside hex.
  EXPECT_FALSE(temp.store().path_for(std::string(64, 'g')).has_value());
  // A NUL would truncate the path at the syscall boundary.
  EXPECT_FALSE(temp.store().path_for(std::string("a\0", 2) + std::string(62, 'a'))
                   .has_value());
}

TEST(AttachmentStore, EveryStoredBlobStaysUnderTheRoot) {
  TempStore temp;
  const auto blob = temp.store().put("payload");
  ASSERT_TRUE(blob.has_value());

  const auto canonical_root = std::filesystem::weakly_canonical(temp.root());
  const auto canonical_blob = std::filesystem::weakly_canonical(blob->path);
  EXPECT_EQ(canonical_blob.string().rfind(canonical_root.string(), 0), 0u)
      << canonical_blob << " escaped " << canonical_root;
}

// MARK: - Durability

TEST(AttachmentStore, LeavesNoTemporaryFilesBehind) {
  TempStore temp;
  ASSERT_TRUE(temp.store().put("one").has_value());
  ASSERT_TRUE(temp.store().put("two").has_value());

  // A reader trusts that a file named by its digest actually hashes to it, so
  // a stray partial write must never survive under a real name.
  for (const auto& entry :
       std::filesystem::recursive_directory_iterator(temp.root())) {
    EXPECT_EQ(entry.path().string().find(".tmp."), std::string::npos)
        << "temporary file left behind: " << entry.path();
  }
}

// MARK: - Housekeeping

TEST(AttachmentStore, ContainsReflectsWhatIsActuallyOnDisk) {
  TempStore temp;
  const auto blob = temp.store().put("payload");
  ASSERT_TRUE(blob.has_value());
  EXPECT_TRUE(temp.store().contains(blob->content_hash));

  // macOS may reclaim a cache directory at any time, so a hash recorded in
  // Postgres can outlive its file. `contains` must report the disk, not the
  // database.
  std::filesystem::remove(blob->path);
  EXPECT_FALSE(temp.store().contains(blob->content_hash));
}

TEST(AttachmentStore, ContainsRejectsMalformedHashesRatherThanThrowing) {
  TempStore temp;
  EXPECT_FALSE(temp.store().contains("../../../etc/passwd"));
  EXPECT_FALSE(temp.store().contains(""));
}

TEST(AttachmentStore, RemoveDeletesAndIsIdempotent) {
  TempStore temp;
  const auto blob = temp.store().put("payload");
  ASSERT_TRUE(blob.has_value());

  ASSERT_TRUE(temp.store().remove(blob->content_hash).has_value());
  EXPECT_FALSE(temp.store().contains(blob->content_hash));
  // Removing an absent blob is not an error — cleanup should be re-runnable.
  EXPECT_TRUE(temp.store().remove(blob->content_hash).has_value());
}

TEST(AttachmentStore, TotalBytesSumsStoredContent) {
  TempStore temp;
  EXPECT_EQ(temp.store().total_bytes().value_or(-1), 0);

  ASSERT_TRUE(temp.store().put("12345").has_value());
  ASSERT_TRUE(temp.store().put("1234567890").has_value());
  EXPECT_EQ(temp.store().total_bytes().value_or(-1), 15);

  // Deduplicated content must not be counted twice.
  ASSERT_TRUE(temp.store().put("12345").has_value());
  EXPECT_EQ(temp.store().total_bytes().value_or(-1), 15);
}

TEST(AttachmentStore, TotalBytesIsZeroForAStoreThatWasNeverWrittenTo) {
  TempStore temp;
  EXPECT_EQ(temp.store().total_bytes().value_or(-1), 0);
}

// MARK: - Default location

TEST(AttachmentStore, DefaultRootIsUnderCachesNotApplicationSupport) {
  const auto root = AttachmentStore::default_root();
  // Caches, because every blob is re-downloadable: this keeps hundreds of
  // megabytes of recoverable data out of Time Machine.
  EXPECT_NE(root.find("/Library/Caches/"), std::string::npos) << root;
  EXPECT_EQ(root.find("Application Support"), std::string::npos) << root;
}
