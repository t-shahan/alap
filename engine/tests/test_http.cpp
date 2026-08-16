/// @file test_http.cpp
/// @brief Transport-level tests for HttpClient.
///
/// The motivating bug: `CURLOPT_POSTFIELDSIZE` set *after*
/// `CURLOPT_COPYPOSTFIELDS` invalidates the copied buffer, so libcurl falls
/// back to its default read callback — which reads from stdin. The result is a
/// process wedged inside `curl_easy_perform` with an established TLS
/// connection and no request body, indistinguishable from a network hang.
///
/// These tests run against a throwaway in-process HTTP server, so they need no
/// network and finish in milliseconds.

#include <gtest/gtest.h>

#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

#include <atomic>
#include <string>
#include <thread>

#include "mailengine/http.hpp"

using namespace mailengine;

namespace {

/// A single-request HTTP server that captures whatever it receives.
class CapturingServer {
 public:
  /// Binds to an ephemeral loopback port. Returns the port.
  uint16_t start() {
    fd_ = ::socket(AF_INET, SOCK_STREAM, 0);
    EXPECT_GE(fd_, 0);
    int reuse = 1;
    setsockopt(fd_, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));

    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = 0;
    EXPECT_EQ(::bind(fd_, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)), 0);
    EXPECT_EQ(::listen(fd_, 1), 0);

    sockaddr_in bound{};
    socklen_t len = sizeof(bound);
    EXPECT_EQ(::getsockname(fd_, reinterpret_cast<sockaddr*>(&bound), &len), 0);
    return ntohs(bound.sin_port);
  }

  /// Serves exactly one request on a background thread.
  void serve_once() {
    worker_ = std::thread([this] {
      const int client = ::accept(fd_, nullptr, nullptr);
      if (client < 0) return;

      // Read until the headers end, then keep reading whatever Content-Length
      // promised, so the captured request includes the body.
      std::string request;
      char buffer[8192];
      while (true) {
        const ssize_t n = ::recv(client, buffer, sizeof(buffer), 0);
        if (n <= 0) break;
        request.append(buffer, static_cast<size_t>(n));

        const size_t header_end = request.find("\r\n\r\n");
        if (header_end == std::string::npos) continue;

        size_t expected = 0;
        const size_t cl = request.find("Content-Length:");
        if (cl != std::string::npos) {
          expected = static_cast<size_t>(std::stoul(request.substr(cl + 15)));
        }
        if (request.size() >= header_end + 4 + expected) break;
      }

      captured_ = request;
      const char* response =
          "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok";
      ::send(client, response, strlen(response), 0);
      ::close(client);
      done_ = true;
    });
  }

  ~CapturingServer() {
    if (worker_.joinable()) worker_.join();
    if (fd_ >= 0) ::close(fd_);
  }

  [[nodiscard]] const std::string& captured() const { return captured_; }
  [[nodiscard]] bool done() const { return done_; }

 private:
  int fd_ = -1;
  std::thread worker_;
  std::string captured_;
  std::atomic<bool> done_{false};
};

std::string url_for(uint16_t port) {
  return "http://127.0.0.1:" + std::to_string(port);
}

}  // namespace

TEST(HttpClient, PostActuallySendsTheBody) {
  // The regression guard. Before the fix this test hung rather than failed,
  // because libcurl sat waiting on stdin for a body that never came.
  CapturingServer server;
  const uint16_t port = server.start();
  server.serve_once();

  HttpClient client;
  client.set_timeout_seconds(5);
  const std::string body = "grant_type=authorization_code&code=abc123";

  const auto response = client.post(url_for(port), body);

  ASSERT_TRUE(response.has_value()) << response.error().message;
  EXPECT_EQ(response->status, 200);
  EXPECT_TRUE(server.done());

  // The body must appear in what the server received.
  EXPECT_NE(server.captured().find(body), std::string::npos)
      << "request body missing; captured:\n"
      << server.captured();
  EXPECT_NE(server.captured().find("POST "), std::string::npos);
  EXPECT_NE(server.captured().find("Content-Length: " + std::to_string(body.size())),
            std::string::npos);
}

TEST(HttpClient, PostSetsContentType) {
  CapturingServer server;
  const uint16_t port = server.start();
  server.serve_once();

  HttpClient client;
  client.set_timeout_seconds(5);
  const auto response = client.post(url_for(port), "{}", "application/json");

  ASSERT_TRUE(response.has_value()) << response.error().message;
  EXPECT_NE(server.captured().find("Content-Type: application/json"),
            std::string::npos);
}

TEST(HttpClient, GetAfterPostIsStillAGet) {
  // Handles are reused across requests. Without curl_easy_reset, POST state
  // leaks into the next call and a GET silently goes out as a POST.
  HttpClient client;
  client.set_timeout_seconds(5);

  {
    CapturingServer server;
    const uint16_t port = server.start();
    server.serve_once();
    ASSERT_TRUE(client.post(url_for(port), "a=1").has_value());
  }

  CapturingServer server;
  const uint16_t port = server.start();
  server.serve_once();

  const auto response = client.get(url_for(port));
  ASSERT_TRUE(response.has_value()) << response.error().message;
  EXPECT_EQ(server.captured().rfind("GET ", 0), 0u)
      << "expected a GET; captured:\n"
      << server.captured();
}

TEST(HttpClient, SendsCustomHeaders) {
  CapturingServer server;
  const uint16_t port = server.start();
  server.serve_once();

  HttpClient client;
  client.set_timeout_seconds(5);
  const auto response =
      client.get(url_for(port), {{"Authorization", "Bearer test-token"}});

  ASSERT_TRUE(response.has_value()) << response.error().message;
  EXPECT_NE(server.captured().find("Authorization: Bearer test-token"),
            std::string::npos);
}

TEST(HttpClient, FormEncodeEscapesReservedCharacters) {
  const std::string encoded = HttpClient::form_encode({
      {"redirect_uri", "http://127.0.0.1:8080"},
      {"scope", "https://www.googleapis.com/auth/gmail.modify"},
  });

  // Colons and slashes must be escaped, or Google rejects the request.
  EXPECT_NE(encoded.find("redirect_uri=http%3A%2F%2F127.0.0.1%3A8080"),
            std::string::npos)
      << encoded;
  EXPECT_NE(encoded.find('&'), std::string::npos);
}
