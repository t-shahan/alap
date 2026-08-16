/// @file test_oauth.cpp
/// @brief Tests for query parsing and the loopback listener.
///
/// The interactive flow itself cannot be tested without a browser and a real
/// Google account, but its parsing and transport pieces can — and those are
/// where the subtle bugs live.

#include <gtest/gtest.h>

#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

#include <chrono>
#include <string>
#include <thread>

#include "mailengine/keychain.hpp"
#include "mailengine/oauth.hpp"

using namespace mailengine;

namespace {

/// Stands in for the browser: connects to the loopback listener and sends a
/// bare HTTP GET, exactly as Google's redirect would.
void send_redirect(uint16_t port, const std::string& target) {
  const int fd = ::socket(AF_INET, SOCK_STREAM, 0);
  ASSERT_GE(fd, 0);

  sockaddr_in addr{};
  addr.sin_family = AF_INET;
  addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  addr.sin_port = htons(port);

  ASSERT_EQ(::connect(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)), 0);
  const std::string request = "GET " + target + " HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n";
  ::send(fd, request.data(), request.size(), 0);
  ::close(fd);
}

}  // namespace

TEST(QueryParam, ExtractsSimpleValues) {
  const std::string query = "code=4/0AX&state=abc123&scope=email";
  EXPECT_EQ(query_param(query, "code"), "4/0AX");
  EXPECT_EQ(query_param(query, "state"), "abc123");
  EXPECT_EQ(query_param(query, "scope"), "email");
}

TEST(QueryParam, PercentDecodes) {
  // Google returns codes and scopes containing / and : escaped.
  const std::string query = "code=4%2F0AeaYSHB&scope=https%3A%2F%2Fmail.google.com";
  EXPECT_EQ(query_param(query, "code"), "4/0AeaYSHB");
  EXPECT_EQ(query_param(query, "scope"), "https://mail.google.com");
}

TEST(QueryParam, ReturnsEmptyForMissingKey) {
  EXPECT_EQ(query_param("code=abc", "state"), "");
}

TEST(QueryParam, DoesNotMatchOnKeySuffix) {
  // "state" must not be found inside "oauth_state".
  const std::string query = "oauth_state=wrong&state=right";
  EXPECT_EQ(query_param(query, "state"), "right");
}

TEST(QueryParam, HandlesLastParameterWithoutTrailingAmpersand) {
  EXPECT_EQ(query_param("a=1&b=2", "b"), "2");
}

TEST(LoopbackListener, BindsToAnEphemeralPort) {
  LoopbackListener listener;
  const auto port = listener.start();

  ASSERT_TRUE(port.has_value()) << port.error().message;
  // Ephemeral range; the exact value is the kernel's choice.
  EXPECT_GT(*port, 1024);
}

TEST(LoopbackListener, TimesOutWhenNoRedirectArrives) {
  LoopbackListener listener;
  ASSERT_TRUE(listener.start().has_value());

  const auto began = std::chrono::steady_clock::now();
  const auto result = listener.await_redirect(std::chrono::seconds(1));
  const auto elapsed = std::chrono::steady_clock::now() - began;

  EXPECT_FALSE(result.has_value());
  // Must actually wait rather than returning instantly, and must not hang.
  EXPECT_GE(std::chrono::duration_cast<std::chrono::milliseconds>(elapsed).count(), 900);
  EXPECT_LT(std::chrono::duration_cast<std::chrono::milliseconds>(elapsed).count(), 3000);
}

TEST(LoopbackListener, ReceivesTheRedirectQueryString) {
  LoopbackListener listener;
  const auto port = listener.start();
  ASSERT_TRUE(port.has_value());

  // Stand in for the browser: connect and send a redirect request.
  std::thread browser([p = *port] {
    std::this_thread::sleep_for(std::chrono::milliseconds(100));
    send_redirect(p, "/?code=test-code&state=test-state");
  });

  const auto query = listener.await_redirect(std::chrono::seconds(5));
  browser.join();

  ASSERT_TRUE(query.has_value()) << query.error().message;
  EXPECT_EQ(query_param(*query, "code"), "test-code");
  EXPECT_EQ(query_param(*query, "state"), "test-state");
}

TEST(Keychain, RoundTripsASecret) {
  const Keychain keychain("app.alap.mail.tests");
  const std::string account = "acct_unit_test";
  const std::string secret = "1//0eXaMpLe-refresh-token";

  ASSERT_TRUE(keychain.store(account, secret).has_value());

  const auto loaded = keychain.load(account);
  ASSERT_TRUE(loaded.has_value()) << loaded.error().message;
  EXPECT_EQ(*loaded, secret);

  ASSERT_TRUE(keychain.remove(account).has_value());
  EXPECT_FALSE(keychain.load(account).has_value());
}

TEST(Keychain, StoreOverwritesExistingSecret) {
  const Keychain keychain("app.alap.mail.tests");
  const std::string account = "acct_overwrite_test";

  ASSERT_TRUE(keychain.store(account, "first").has_value());
  ASSERT_TRUE(keychain.store(account, "second").has_value());

  const auto loaded = keychain.load(account);
  ASSERT_TRUE(loaded.has_value());
  EXPECT_EQ(*loaded, "second");

  (void)keychain.remove(account);
}

TEST(Keychain, RemovingAnAbsentItemSucceeds) {
  const Keychain keychain("app.alap.mail.tests");
  EXPECT_TRUE(keychain.remove("acct_never_existed").has_value());
}
