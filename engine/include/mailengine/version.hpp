/// @file version.hpp
/// @brief Build identity for the mail engine.
///
/// This header exists mainly to give Phase 1 a compilable target so the CMake
/// toolchain can be validated end-to-end before any real logic lands.

#pragma once

#include <string_view>

/// @namespace mailengine
/// @brief Root namespace for the C++ mail engine.
///
/// The engine is a *producer into Postgres*. It fetches from the Gmail API,
/// parses MIME, maintains the SQLite FTS5 index, and writes rows to Postgres.
/// It has no knowledge of Zero: logical replication carries its writes to
/// zero-cache, which computes per-query diffs for connected clients.
namespace mailengine {

/// @brief Semantic version of the engine, matching the CMake project version.
/// @return A static, null-terminated version string such as "0.1.0".
[[nodiscard]] std::string_view version() noexcept;

}  // namespace mailengine
