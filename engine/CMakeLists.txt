cmake_minimum_required(VERSION 3.28)
project(mailengine VERSION 0.1.0 LANGUAGES CXX)

# ─────────────────────────────────────────────────────────────────────────────
# C++20 is required (not just requested) — Phase 3 leans on <concepts>,
# designated initializers, and std::span for zero-copy MIME buffer slicing.
# CXX_EXTENSIONS OFF keeps us on -std=c++20 rather than -std=gnu++20 so the
# code stays portable off Apple clang.
# ─────────────────────────────────────────────────────────────────────────────
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# Emit compile_commands.json so clangd / the Xcode editor can resolve headers.
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE RelWithDebInfo)
endif()

include(FetchContent)

# ─────────────────────────────────────────────────────────────────────────────
# Dependencies
#
# libcurl and SQLite3 ship with macOS, so we link the system copies rather than
# vendoring them. SQLite3 is what backs the FTS5 full-text index — Zero's ZQL
# has no text search, so instant search lives here in C++, not in Zero.
# ─────────────────────────────────────────────────────────────────────────────
find_package(CURL REQUIRED)
find_package(SQLite3 REQUIRED)

# libpq: how the engine writes parsed messages INTO Postgres. The engine never
# talks to Zero — it writes rows, and logical replication carries them to
# zero-cache, which diffs them into each open client query.
#
# Homebrew's postgresql@18 is keg-only AND nests its libraries under
# lib/postgresql/, so a plain find_library(pq) misses it. Going through
# pkg-config picks up the include dir, link dir, and transitive deps in one
# step, and keeps this working if you later switch to the standalone `libpq`
# formula or Postgres.app.
find_package(PkgConfig REQUIRED)
set(ENV{PKG_CONFIG_PATH}
    "/opt/homebrew/opt/postgresql@18/lib/postgresql/pkgconfig:/opt/homebrew/opt/libpq/lib/pkgconfig:$ENV{PKG_CONFIG_PATH}")
pkg_check_modules(LIBPQ REQUIRED IMPORTED_TARGET libpq)

FetchContent_Declare(json
  URL https://github.com/nlohmann/json/releases/download/v3.11.3/json.tar.xz
  DOWNLOAD_EXTRACT_TIMESTAMP TRUE)
FetchContent_MakeAvailable(json)

# ─────────────────────────────────────────────────────────────────────────────
# The engine core, built as a library so the test target can link it without
# recompiling, and so Phase 4 can expose it to Swift through an Objective-C++
# translation unit.
# ─────────────────────────────────────────────────────────────────────────────
add_library(mailengine_core
  src/version.cpp
  src/http.cpp
  src/crypto.cpp
  src/keychain.cpp
  src/oauth.cpp
  src/mime.cpp
  src/gmail.cpp
)
target_include_directories(mailengine_core
  PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/include
)
target_link_libraries(mailengine_core
  PRIVATE CURL::libcurl SQLite3::SQLite3 PkgConfig::LIBPQ nlohmann_json::nlohmann_json
)

# Security supplies SecRandomCopyBytes and the Keychain item API; CoreFoundation
# supplies the CFString/CFDictionary types those calls are expressed in.
# CommonCrypto (SHA-256) is part of libSystem and needs no explicit link.
if(APPLE)
  target_link_libraries(mailengine_core
    PRIVATE "-framework Security" "-framework CoreFoundation"
  )
endif()
target_compile_options(mailengine_core PRIVATE -Wall -Wextra -Wpedantic)

# Standalone daemon: drains the Gmail sync queue and the IMAP command outbox.
add_executable(mailengined src/main.cpp)
target_link_libraries(mailengined PRIVATE mailengine_core)

# ─────────────────────────────────────────────────────────────────────────────
# Tests (opt-in so the app build doesn't pay for GoogleTest)
# ─────────────────────────────────────────────────────────────────────────────
option(MAILENGINE_BUILD_TESTS "Build unit tests" ON)
if(MAILENGINE_BUILD_TESTS)
  FetchContent_Declare(googletest
    URL https://github.com/google/googletest/archive/refs/tags/v1.15.2.tar.gz
    DOWNLOAD_EXTRACT_TIMESTAMP TRUE)
  FetchContent_MakeAvailable(googletest)

  enable_testing()
  add_executable(mailengine_tests
    tests/test_version.cpp
    tests/test_crypto.cpp
    tests/test_oauth.cpp
    tests/test_http.cpp
    tests/test_mime.cpp
    tests/test_gmail.cpp
  )
  target_link_libraries(mailengine_tests PRIVATE mailengine_core GTest::gtest_main)

  include(GoogleTest)
  gtest_discover_tests(mailengine_tests)
endif()
