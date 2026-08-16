/// @file main.cpp
/// @brief Entry point for the `mailengined` daemon.
///
/// Phase 3 turns this into the sync worker: it will run two loops against
/// Postgres — an ingest loop (Gmail `history.list` → MIME parse → INSERT) and
/// an outbox loop (`LISTEN` on the command outbox → execute Gmail mutations).
/// For now it only proves that the C++20 toolchain, CMake wiring, and linked
/// system libraries all resolve.

#include <iostream>

#include "mailengine/version.hpp"

int main() {
  std::cout << "mailengined " << mailengine::version() << '\n';
  return 0;
}
