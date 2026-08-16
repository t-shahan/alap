/// @file http.hpp
/// @brief Thin RAII wrapper over libcurl's easy interface.

#pragma once

#include <map>
#include <string>
#include <vector>

#include "mailengine/result.hpp"

namespace mailengine {

/// @brief A completed HTTP response.
struct HttpResponse {
  long status = 0;
  std::string body;

  /// @brief True for 2xx.
  [[nodiscard]] bool ok() const noexcept { return status >= 200 && status < 300; }
};

/// @brief Performs HTTPS requests against the Gmail and Google OAuth APIs.
///
/// ## Ownership
///
/// Each instance owns one `CURL*` handle, freed in the destructor. The handle
/// is deliberately reused across requests: libcurl keeps the TLS session and
/// connection alive between calls to the same host, which matters a great deal
/// when fetching thousands of messages — a fresh handshake per message would
/// dominate sync time.
///
/// ## Thread safety
///
/// NOT thread-safe. A `CURL*` handle may only be used by one thread at a time.
/// The ingest worker pool gives each thread its own `HttpClient`.
class HttpClient {
 public:
  HttpClient();
  ~HttpClient();

  /// Non-copyable: a `CURL*` handle cannot be meaningfully duplicated.
  HttpClient(const HttpClient&) = delete;
  HttpClient& operator=(const HttpClient&) = delete;
  /// Movable, so clients can live in containers.
  HttpClient(HttpClient&& other) noexcept;
  HttpClient& operator=(HttpClient&& other) noexcept;

  /// @brief Issues a GET request.
  /// @param url Absolute URL.
  /// @param headers Extra request headers, e.g. Authorization.
  [[nodiscard]] Result<HttpResponse> get(
      const std::string& url,
      const std::map<std::string, std::string>& headers = {});

  /// @brief Issues a POST request.
  /// @param url Absolute URL.
  /// @param body Raw request body.
  /// @param content_type Value for the Content-Type header.
  /// @param headers Extra request headers.
  [[nodiscard]] Result<HttpResponse> post(
      const std::string& url,
      const std::string& body,
      const std::string& content_type = "application/x-www-form-urlencoded",
      const std::map<std::string, std::string>& headers = {});

  /// @brief Sets the total request timeout. Defaults to 30s.
  void set_timeout_seconds(long seconds) noexcept { timeout_seconds_ = seconds; }

  /// @brief Percent-encodes a string for use in a URL query or form body.
  [[nodiscard]] static std::string url_encode(const std::string& value);

  /// @brief Builds an `a=1&b=2` form body from key/value pairs, encoding both.
  [[nodiscard]] static std::string form_encode(
      const std::vector<std::pair<std::string, std::string>>& fields);

 private:
  /// Opaque `CURL*`. Kept as void* so this header does not leak <curl/curl.h>
  /// into every translation unit that touches HTTP.
  void* handle_ = nullptr;
  long timeout_seconds_ = 30;

  [[nodiscard]] Result<HttpResponse> perform(
      const std::string& url,
      const std::map<std::string, std::string>& headers);
};

}  // namespace mailengine
