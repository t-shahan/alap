/// @file test_search.cpp
/// @brief FTS5 index behaviour and query escaping.
///
/// Runs against an in-memory SQLite database, so no files and no services.
/// The escaping tests matter most: unescaped user input turns ordinary
/// searches — an email address, a hyphenated word — into FTS5 syntax errors.

#include <gtest/gtest.h>

#include <string>

#include "mailengine/search.hpp"

using namespace mailengine;

namespace {

GmailMessage message_with(const std::string& subject, const std::string& body,
                          const std::string& from_name = "Ada Okonkwo",
                          const std::string& from_email = "ada@example.com") {
  GmailMessage message;
  message.id = "m1";
  message.thread_id = "t1";
  message.subject = subject;
  message.text_body = body;
  message.from = mime::Address{from_name, from_email};
  return message;
}

/// Opens an index backed by a private in-memory database.
SearchIndex make_index() {
  SearchIndex index;
  const auto opened = index.open(":memory:");
  EXPECT_TRUE(opened.has_value()) << opened.error().message;
  return index;
}

}  // namespace

// MARK: - Escaping

TEST(EscapeQuery, QuotesEachTermAndPrefixMatchesTheLast) {
  EXPECT_EQ(SearchIndex::escape_query("design review"),
            "\"design\" AND \"review\"*");
}

TEST(EscapeQuery, SingleTermIsPrefixMatched) {
  // Prefix matching is what makes results narrow as the user types.
  EXPECT_EQ(SearchIndex::escape_query("desi"), "\"desi\"*");
}

TEST(EscapeQuery, HandlesEmailAddresses) {
  // Unquoted, `:` and `@` are FTS5 operators and this raises a syntax error.
  EXPECT_EQ(SearchIndex::escape_query("ada@example.com"), "\"ada@example.com\"*");
}

TEST(EscapeQuery, HandlesHyphensAndColons) {
  // A bare `-` means NOT in FTS5, so "cost-benefit" would silently exclude.
  EXPECT_EQ(SearchIndex::escape_query("cost-benefit"), "\"cost-benefit\"*");
  EXPECT_EQ(SearchIndex::escape_query("re:"), "\"re:\"*");
}

TEST(EscapeQuery, DoublesEmbeddedQuotes) {
  // FTS5 escapes a quote by doubling it.
  EXPECT_EQ(SearchIndex::escape_query("say \"hi\""),
            "\"say\" AND \"\"\"hi\"\"\"*");
}

TEST(EscapeQuery, NeutralisesOperatorKeywords) {
  // Quoted, these are literals rather than boolean operators.
  EXPECT_EQ(SearchIndex::escape_query("cats OR dogs"),
            "\"cats\" AND \"OR\" AND \"dogs\"*");
}

TEST(EscapeQuery, ReturnsEmptyForBlankInput) {
  EXPECT_EQ(SearchIndex::escape_query(""), "");
  EXPECT_EQ(SearchIndex::escape_query("   "), "");
}

// MARK: - Indexing and retrieval

TEST(SearchIndex, FindsBySubject) {
  auto index = make_index();
  ASSERT_TRUE(index.index_message("acct", "acct|t1", "acct|m1",
                                  message_with("Design review Thursday", "body"))
                  .has_value());

  const auto hits = index.search("design");
  ASSERT_TRUE(hits.has_value()) << hits.error().message;
  ASSERT_EQ(hits->size(), 1u);
  EXPECT_EQ((*hits)[0].thread_id, "acct|t1");
}

TEST(SearchIndex, FindsByBody) {
  auto index = make_index();
  ASSERT_TRUE(index.index_message("acct", "acct|t1", "acct|m1",
                                  message_with("Subject", "the quarterly budget"))
                  .has_value());

  const auto hits = index.search("quarterly");
  ASSERT_TRUE(hits.has_value());
  EXPECT_EQ(hits->size(), 1u);
}

TEST(SearchIndex, FindsBySenderNameOrAddress) {
  auto index = make_index();
  ASSERT_TRUE(index.index_message("acct", "acct|t1", "acct|m1",
                                  message_with("Subject", "body", "Marcus Bell",
                                               "marcus@example.com"))
                  .has_value());

  EXPECT_EQ(index.search("Marcus")->size(), 1u);
  EXPECT_EQ(index.search("marcus@example.com")->size(), 1u);
}

TEST(SearchIndex, StemsWithPorter) {
  // "meeting" should match a search for "meet".
  auto index = make_index();
  ASSERT_TRUE(index.index_message("acct", "acct|t1", "acct|m1",
                                  message_with("Weekly meetings", "body"))
                  .has_value());

  EXPECT_EQ(index.search("meeting")->size(), 1u);
}

TEST(SearchIndex, FoldsDiacritics) {
  // "cafe" should match "café" — remove_diacritics 2 in the tokenizer.
  auto index = make_index();
  ASSERT_TRUE(
      index.index_message("acct", "acct|t1", "acct|m1", message_with("Café notes", "body"))
          .has_value());

  EXPECT_EQ(index.search("cafe")->size(), 1u);
}

TEST(SearchIndex, PrefixMatchesAsYouType) {
  auto index = make_index();
  ASSERT_TRUE(index.index_message("acct", "acct|t1", "acct|m1",
                                  message_with("Infrastructure spend", "body"))
                  .has_value());

  for (const char* partial : {"infra", "infrast", "infrastructure"}) {
    EXPECT_EQ(index.search(partial)->size(), 1u) << partial;
  }
}

TEST(SearchIndex, RequiresAllTerms) {
  auto index = make_index();
  ASSERT_TRUE(index.index_message("acct", "acct|t1", "acct|m1",
                                  message_with("Design review", "body"))
                  .has_value());

  EXPECT_EQ(index.search("design review")->size(), 1u);
  EXPECT_EQ(index.search("design unrelated")->size(), 0u);
}

TEST(SearchIndex, DeduplicatesByThread) {
  // Three matching messages in one conversation is one result, not three.
  auto index = make_index();
  for (const char* id : {"acct|m1", "acct|m2", "acct|m3"}) {
    ASSERT_TRUE(
        index.index_message("acct", "acct|t1", id, message_with("Budget", "budget"))
            .has_value());
  }

  const auto hits = index.search("budget");
  ASSERT_TRUE(hits.has_value());
  EXPECT_EQ(hits->size(), 1u);
}

TEST(SearchIndex, ReindexingReplacesRatherThanDuplicates) {
  auto index = make_index();
  ASSERT_TRUE(
      index.index_message("acct", "acct|t1", "acct|m1", message_with("First", "one"))
          .has_value());
  ASSERT_TRUE(
      index.index_message("acct", "acct|t1", "acct|m1", message_with("Second", "two"))
          .has_value());

  EXPECT_EQ(*index.count(), 1);
  // The old text must be gone, or an edited message stays findable by its
  // previous contents forever.
  EXPECT_EQ(index.search("First")->size(), 0u);
  EXPECT_EQ(index.search("Second")->size(), 1u);
}

TEST(SearchIndex, RemovesMessages) {
  auto index = make_index();
  ASSERT_TRUE(
      index.index_message("acct", "acct|t1", "acct|m1", message_with("Gone", "body"))
          .has_value());
  ASSERT_TRUE(index.remove_message("acct|m1").has_value());

  EXPECT_EQ(*index.count(), 0);
  EXPECT_EQ(index.search("Gone")->size(), 0u);
}

TEST(SearchIndex, RanksSubjectMatchesAboveBodyMatches) {
  auto index = make_index();
  ASSERT_TRUE(index.index_message("acct", "acct|body", "acct|m1",
                                  message_with("Unrelated", "mentions budget once"))
                  .has_value());
  ASSERT_TRUE(index.index_message("acct", "acct|subject", "acct|m2",
                                  message_with("Budget planning", "unrelated text"))
                  .has_value());

  const auto hits = index.search("budget");
  ASSERT_TRUE(hits.has_value());
  ASSERT_EQ(hits->size(), 2u);
  // bm25 weights subject 10x body, so the subject match must come first.
  EXPECT_EQ((*hits)[0].thread_id, "acct|subject");
}

TEST(SearchIndex, EmptyQueryReturnsNothingRatherThanEverything) {
  auto index = make_index();
  ASSERT_TRUE(
      index.index_message("acct", "acct|t1", "acct|m1", message_with("Anything", "body"))
          .has_value());

  EXPECT_TRUE(index.search("")->empty());
  EXPECT_TRUE(index.search("   ")->empty());
}

TEST(SearchIndex, RespectsLimit) {
  auto index = make_index();
  for (int i = 0; i < 10; ++i) {
    const std::string suffix = std::to_string(i);
    ASSERT_TRUE(index
                    .index_message("acct", "acct|t" + suffix, "acct|m" + suffix,
                                   message_with("Budget " + suffix, "body"))
                    .has_value());
  }

  EXPECT_EQ(index.search("budget", 3)->size(), 3u);
}

TEST(SearchIndex, SurvivesPunctuationHeavyInput) {
  // These would all be FTS5 syntax errors unescaped.
  auto index = make_index();
  ASSERT_TRUE(
      index.index_message("acct", "acct|t1", "acct|m1", message_with("Hello", "body"))
          .has_value());

  for (const char* nasty : {"((", "\"", "*", "AND OR NOT", "a:b:c", "-x", "^"}) {
    const auto hits = index.search(nasty);
    EXPECT_TRUE(hits.has_value()) << "crashed on: " << nasty;
  }
}
