/// @file result.hpp
/// @brief A minimal `Result<T>` for fallible operations.
///
/// C++23 has `std::expected`, but this project is pinned to C++20, so we define
/// the small piece of it we actually need.
///
/// Why not exceptions? The engine's failure modes are almost entirely expected
/// ones — network timeouts, HTTP 401s, malformed payloads. Those are control
/// flow, not exceptional conditions, and a sync engine that throws on every
/// flaky connection is painful to reason about. Exceptions stay reserved for
/// genuine programmer errors.

#pragma once

#include <string>
#include <utility>
#include <variant>

namespace mailengine {

/// @brief An error with a human-readable message and optional numeric code.
struct Error {
  std::string message;
  /// HTTP status, curl error code, or 0 when not applicable.
  int code = 0;
};

/// @brief Either a value of type `T` or an `Error`.
///
/// @tparam T The success type. Use `Result<void>` (specialised below) for
///           operations that either succeed or fail without producing a value.
///
/// Example:
/// @code
///   Result<HttpResponse> res = client.get(url);
///   if (!res) {
///     log(res.error().message);
///     return;
///   }
///   use(*res);
/// @endcode
template <typename T>
class Result {
 public:
  /// @brief Constructs a success result.
  Result(T value) : storage_(std::move(value)) {}
  /// @brief Constructs a failure result.
  Result(Error error) : storage_(std::move(error)) {}

  /// @brief True when this holds a value.
  [[nodiscard]] explicit operator bool() const noexcept {
    return std::holds_alternative<T>(storage_);
  }
  [[nodiscard]] bool has_value() const noexcept { return static_cast<bool>(*this); }

  /// @brief Accesses the value. Undefined behaviour if this holds an error.
  [[nodiscard]] const T& operator*() const& { return std::get<T>(storage_); }
  [[nodiscard]] T& operator*() & { return std::get<T>(storage_); }
  /// @brief Moves the value out. Enables `return std::move(*result);`.
  [[nodiscard]] T&& operator*() && { return std::get<T>(std::move(storage_)); }

  [[nodiscard]] const T* operator->() const { return &std::get<T>(storage_); }
  [[nodiscard]] T* operator->() { return &std::get<T>(storage_); }

  /// @brief Accesses the error. Undefined behaviour if this holds a value.
  [[nodiscard]] const Error& error() const { return std::get<Error>(storage_); }

  /// @brief Returns the value, or `fallback` when this holds an error.
  [[nodiscard]] T value_or(T fallback) const& {
    return *this ? std::get<T>(storage_) : std::move(fallback);
  }

 private:
  std::variant<T, Error> storage_;
};

/// @brief Specialisation for operations with no success value.
template <>
class Result<void> {
 public:
  /// @brief Constructs a success result.
  Result() = default;
  /// @brief Constructs a failure result.
  Result(Error error) : error_(std::move(error)), failed_(true) {}

  [[nodiscard]] explicit operator bool() const noexcept { return !failed_; }
  [[nodiscard]] bool has_value() const noexcept { return !failed_; }
  [[nodiscard]] const Error& error() const { return error_; }

 private:
  Error error_;
  bool failed_ = false;
};

/// @brief Convenience for building a failure without naming the type twice.
[[nodiscard]] inline Error make_error(std::string message, int code = 0) {
  return Error{std::move(message), code};
}

}  // namespace mailengine
