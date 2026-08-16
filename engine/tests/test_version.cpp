/// @file test_version.cpp
/// @brief Toolchain-validation test.
///
/// Per the project's TDD rules, every module gets tests from the start. This
/// one exists so the GoogleTest wiring is proven before Phase 3 adds the MIME
/// parser, which is where real test pressure begins.

#include <gtest/gtest.h>

#include "mailengine/version.hpp"

TEST(Version, ReportsANonEmptySemanticVersion) {
  // Arrange / Act
  const auto v = mailengine::version();

  // Assert
  EXPECT_FALSE(v.empty());
  EXPECT_NE(v.find('.'), std::string_view::npos);
}
