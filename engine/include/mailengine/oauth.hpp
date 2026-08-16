/// @file oauth.hpp
/// @brief OAuth 2.0 authorization-code flow with PKCE for desktop clients.
///
/// ## Why loopback rather than a pasted code
///
/// Google removed the out-of-band (`urn:ietf:wg:oauth:2.0:oob`) flow, so a
/// desktop app must receive the authorization code on a local HTTP listener.
/// The sequence:
///
///   1. Bind 127.0.0.1 on an ephemeral port; the OS picks it.
///   2. Open the system browser at Google's consent screen, passing that port
///      as `redirect_uri` and a PKCE challenge.
///   3. The user consents. Google redirects the browser to our listener with
///      `?code=...&state=...`.
///   4. Exchange the code plus the PKCE *verifier* for tokens, over TLS,
///      directly to Google.
///
/// The client secret in a desktop app is not secret — it ships in every copy
/// of the binary. Security comes from PKCE (an intercepted code is useless
/// without the verifier, which never leaves this process) and from the
/// `state` parameter guarding against cross-site request forgery.

#pragma once

#include <chrono>
#include <string>
#include <vector>

#include "mailengine/result.hpp"

namespace mailengine {

/// @brief Tokens returned by Google's token endpoint.
struct TokenSet {
  std::string access_token;
  /// Empty on refresh: Google only issues a refresh token on first consent.
  std::string refresh_token;
  std::chrono::system_clock::time_point expires_at;

  /// @brief True when the access token is expired or within 60s of expiry.
  [[nodiscard]] bool needs_refresh() const {
    return std::chrono::system_clock::now() + std::chrono::seconds(60) >= expires_at;
  }
};

/// @brief Static configuration for the Google OAuth client.
struct OAuthConfig {
  std::string client_id;
  std::string client_secret;
  /// Scopes to request. `gmail.modify` is a *restricted* scope: production use
  /// requires Google verification plus a CASA security assessment.
  std::vector<std::string> scopes = {
      "https://www.googleapis.com/auth/gmail.modify",
      "https://www.googleapis.com/auth/userinfo.email",
  };
};

/// @brief Result of an interactive authorization.
struct AuthorizationResult {
  TokenSet tokens;
  /// The address of the mailbox that was authorized, from the id/userinfo.
  std::string email_address;
};

/// @brief Drives the interactive and refresh halves of the OAuth flow.
class OAuthClient {
 public:
  explicit OAuthClient(OAuthConfig config);

  /// @brief Runs the full interactive flow, blocking until the user consents.
  ///
  /// Opens the system browser and waits for the redirect. Intended to be
  /// called from a CLI or a one-off setup path, never from a sync loop.
  ///
  /// @param timeout How long to wait for the user before giving up.
  [[nodiscard]] Result<AuthorizationResult> authorize_interactively(
      std::chrono::seconds timeout = std::chrono::seconds(300)) const;

  /// @brief Exchanges a refresh token for a fresh access token.
  ///
  /// The returned `TokenSet` carries an empty `refresh_token`; the original
  /// stays valid and remains in the Keychain.
  [[nodiscard]] Result<TokenSet> refresh(const std::string& refresh_token) const;

 private:
  OAuthConfig config_;

  /// Builds the consent-screen URL for a given port, challenge, and state.
  [[nodiscard]] std::string build_authorization_url(uint16_t port,
                                                    const std::string& challenge,
                                                    const std::string& state) const;

  /// Trades an authorization code plus PKCE verifier for tokens.
  [[nodiscard]] Result<TokenSet> exchange_code(const std::string& code,
                                               const std::string& verifier,
                                               uint16_t port) const;

  /// Reads the authorized address from Google's userinfo endpoint.
  [[nodiscard]] Result<std::string> fetch_email(const std::string& access_token) const;
};

/// @brief A single-use HTTP listener on 127.0.0.1 for the OAuth redirect.
///
/// Deliberately not a general-purpose server: it accepts one request, parses
/// the query string, replies with a small HTML page, and closes.
class LoopbackListener {
 public:
  LoopbackListener() = default;
  ~LoopbackListener();
  LoopbackListener(const LoopbackListener&) = delete;
  LoopbackListener& operator=(const LoopbackListener&) = delete;

  /// @brief Binds to 127.0.0.1 on an OS-assigned port and begins listening.
  [[nodiscard]] Result<uint16_t> start();

  /// @brief Blocks until the browser hits the redirect, or the timeout passes.
  /// @return The full query string, e.g. `code=4/0A...&state=xyz`.
  [[nodiscard]] Result<std::string> await_redirect(std::chrono::seconds timeout);

 private:
  int socket_ = -1;
};

/// @brief Extracts one parameter from an unescaped query string.
[[nodiscard]] std::string query_param(const std::string& query, const std::string& key);

/// @brief Opens `url` in the user's default browser via `/usr/bin/open`.
[[nodiscard]] Result<void> open_in_browser(const std::string& url);

}  // namespace mailengine
