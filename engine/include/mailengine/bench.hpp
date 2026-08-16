/// @file bench.hpp
/// @brief Search benchmarking helpers.

#pragma once

#include <cstdint>
#include <string>
#include <vector>

#include "mailengine/result.hpp"
#include "mailengine/search.hpp"

namespace mailengine::bench {

/// @brief Latency distribution for a batch of queries.
struct BenchResult {
  int64_t queries = 0;
  int64_t total_hits = 0;
  int64_t failures = 0;
  double p50_ms = 0;
  double p95_ms = 0;
  double p99_ms = 0;
  double max_ms = 0;
};

/// @brief Fills `index` with `document_count` synthetic mail-like documents.
[[nodiscard]] Result<void> populate(SearchIndex& index, int64_t document_count,
                                    uint32_t seed = 42);

/// @brief Times `queries`, repeated `repetitions` times.
[[nodiscard]] BenchResult measure(SearchIndex& index,
                                  const std::vector<std::string>& queries,
                                  int repetitions = 20,
                                  SearchOrder order = SearchOrder::Recency);

/// @brief Prints one labelled result row.
void print(const std::string& label, const BenchResult& result);

/// @brief A spread of query shapes: common, rare, multi-term, short prefix.
[[nodiscard]] std::vector<std::string> sample_queries();

}  // namespace mailengine::bench
