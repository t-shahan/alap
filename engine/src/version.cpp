/// @file version.cpp
/// @brief Implementation of the engine version accessor.

#include "mailengine/version.hpp"

namespace mailengine {

std::string_view version() noexcept {
  // MAILENGINE_VERSION is injected by CMake in a later phase; the literal keeps
  // the toolchain-validation build self-contained for now.
  return "0.1.0";
}

}  // namespace mailengine
