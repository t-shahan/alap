/// @file bench.cpp
/// @brief Search benchmark at realistic mailbox scale.
///
/// Search latency at 500 messages says nothing useful about 31,000. This
/// synthesises a corpus with mail-like statistics and measures query latency
/// percentiles, so the fuzzy-search design can be chosen from data rather than
/// from assumption.
///
/// Percentiles rather than an average: a mean hides the tail, and the tail is
/// what a user actually perceives as "sometimes it hangs".

#include "mailengine/bench.hpp"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <iomanip>
#include <iostream>
#include <random>
#include <sstream>

namespace mailengine::bench {
namespace {

/// Vocabulary size. Real mailboxes run to tens of thousands of distinct terms
/// once names, product names, URLs and numbers are included.
///
/// This matters enormously and is easy to get wrong. An earlier version of this
/// benchmark used only the ~59 seed words below, which meant every query term
/// appeared in essentially EVERY document. Query cost is proportional to the
/// number of matching rows, so that measured the absolute worst case and made
/// FTS5 look linear in mailbox size. With a realistic vocabulary, a given term
/// matches a small fraction of the corpus and the picture changes completely.
constexpr size_t kVocabularySize = 30000;

/// Frequent words, used as query targets so results are non-trivial.
const std::vector<std::string>& seed_words() {
  static const std::vector<std::string> words = {
      "meeting", "budget", "review", "project", "update", "invoice", "receipt",
      "schedule", "deadline", "proposal", "contract", "shipping", "delivery",
      "account", "payment", "subscription", "renewal", "reminder", "confirm",
      "flight", "hotel", "reservation", "itinerary", "quarterly", "annual",
      "design", "engineering", "infrastructure", "database", "migration",
      "security", "incident", "postmortem", "roadmap", "planning", "hiring",
      "interview", "candidate", "offer", "onboarding", "policy", "benefits",
      "newsletter", "digest", "weekly", "announcement", "release", "version",
      "feedback", "survey", "response", "question", "answer", "discussion",
      "attached", "document", "spreadsheet", "presentation", "report",
  };
  return words;
}

/// The full vocabulary: the seed words plus a long tail of synthetic terms,
/// which is what gives realistic selectivity.
const std::vector<std::string>& vocabulary() {
  static const std::vector<std::string> words = [] {
    std::vector<std::string> all = seed_words();
    all.reserve(kVocabularySize);
    for (size_t i = all.size(); i < kVocabularySize; ++i) {
      all.push_back("term" + std::to_string(i));
    }
    return all;
  }();
  return words;
}

const std::vector<std::string>& senders() {
  static const std::vector<std::string> names = {
      "Ada Okonkwo", "Marcus Bell", "Jun Watanabe", "Priya Raman",
      "Sofia Marino", "Tomas Novak", "Amara Diallo", "Lars Andersen",
  };
  return names;
}

/// Zipf-like index over `size` items.
///
/// Uses an inverse power law, which spreads probability across the whole
/// vocabulary while still concentrating it at the front — the shape real word
/// frequencies take. Squaring a uniform sample (the previous approach) collapses
/// almost all mass onto the first few entries, which is why the old benchmark
/// behaved as if the vocabulary were tiny even after it was enlarged.
size_t zipf_index(std::mt19937& rng, size_t size) {
  std::uniform_real_distribution<double> uniform(0.0, 1.0);
  const double sample = std::max(uniform(rng), 1e-9);
  const auto index = static_cast<size_t>(std::pow(static_cast<double>(size), sample));
  return std::min(index, size - 1);
}

std::string make_text(std::mt19937& rng, int word_count) {
  const auto& words = vocabulary();
  std::string text;
  for (int i = 0; i < word_count; ++i) {
    if (!text.empty()) text += ' ';
    text += words[zipf_index(rng, words.size())];
  }
  return text;
}

/// Returns the value at `percentile` (0–100) of a sorted sample.
double percentile_of(const std::vector<double>& sorted, double percentile) {
  if (sorted.empty()) return 0;
  const auto index = static_cast<size_t>(
      std::clamp(percentile / 100.0 * static_cast<double>(sorted.size() - 1), 0.0,
                 static_cast<double>(sorted.size() - 1)));
  return sorted[index];
}

}  // namespace

Result<void> populate(SearchIndex& index, int64_t document_count, uint32_t seed) {
  std::mt19937 rng(seed);

  // One transaction for the whole corpus. Per-document autocommit makes this
  // fsync-bound rather than CPU-bound.
  if (auto begun = index.begin_batch(); !begun) return begun.error();

  for (int64_t i = 0; i < document_count; ++i) {
    const std::string suffix = std::to_string(i);
    // Threads average roughly 1.5 messages, so ids repeat a little.
    const std::string thread_id = "acct_bench|t" + std::to_string(i / 3 * 2 + i % 2);

    auto written = index.index_document(
        "acct_bench", thread_id, "acct_bench|m" + suffix,
        make_text(rng, 6),                                   // subject
        senders()[zipf_index(rng, senders().size())] + " s" + suffix + "@example.com",
        make_text(rng, 220),                                 // body
        1700000000000LL + i * 60000LL);                      // sent_at, 1/min
    if (!written) return written.error();
  }

  return index.commit_batch();
}

BenchResult measure(SearchIndex& index, const std::vector<std::string>& queries,
                    int repetitions, SearchOrder order) {
  BenchResult result;
  std::vector<double> samples;
  samples.reserve(queries.size() * static_cast<size_t>(repetitions));

  for (int repetition = 0; repetition < repetitions; ++repetition) {
    for (const auto& query : queries) {
      const auto began = std::chrono::steady_clock::now();
      auto hits = index.search(query, 100, order);
      const auto elapsed = std::chrono::steady_clock::now() - began;

      samples.push_back(
          std::chrono::duration<double, std::milli>(elapsed).count());
      if (hits) {
        result.total_hits += static_cast<int64_t>(hits->size());
      } else {
        ++result.failures;
      }
    }
  }

  std::sort(samples.begin(), samples.end());
  result.queries = static_cast<int64_t>(samples.size());
  result.p50_ms = percentile_of(samples, 50);
  result.p95_ms = percentile_of(samples, 95);
  result.p99_ms = percentile_of(samples, 99);
  result.max_ms = samples.empty() ? 0 : samples.back();
  return result;
}

void print(const std::string& label, const BenchResult& result) {
  std::cout << std::fixed << std::setprecision(3) << "  " << std::left
            << std::setw(22) << label << "p50 " << std::setw(8) << result.p50_ms
            << "p95 " << std::setw(8) << result.p95_ms << "p99 " << std::setw(8)
            << result.p99_ms << "max " << std::setw(8) << result.max_ms << "ms"
            << (result.failures > 0
                    ? "  FAILURES: " + std::to_string(result.failures)
                    : "")
            << "\n";
}

std::vector<std::string> sample_queries() {
  return {
      "budget",              // common single term
      "meeting",             // common single term
      "quarterly budget",    // two common terms
      "infrastructure",      // rarer term
      "postmortem incident", // two rarer terms
      "sec",                 // short prefix — widest match, worst case
      "rev",                 // short prefix
      "ada@example.com",     // punctuation-heavy
      "design review project budget", // four terms
  };
}

}  // namespace mailengine::bench
