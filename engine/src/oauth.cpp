/// @file oauth.cpp
/// @brief Implementation of the PKCE authorization-code flow.

#include "mailengine/oauth.hpp"

#include <arpa/inet.h>
#include <netinet/in.h>
#include <spawn.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <unistd.h>

#include <iostream>

#include <nlohmann/json.hpp>
#include <utility>

#include "mailengine/crypto.hpp"
#include "mailengine/http.hpp"

extern char** environ;

namespace mailengine {
namespace {

constexpr const char* kAuthEndpoint = "https://accounts.google.com/o/oauth2/v2/auth";
constexpr const char* kTokenEndpoint = "https://oauth2.googleapis.com/token";
constexpr const char* kUserInfoEndpoint =
    "https://www.googleapis.com/oauth2/v2/userinfo";

/// The page the browser lands on after consent.
constexpr const char* kSuccessPage =
    "HTTP/1.1 200 OK\r\n"
    "Content-Type: text/html; charset=utf-8\r\n"
    "Connection: close\r\n\r\n"
    "<!doctype html><meta charset=utf-8>"
    "<title>Connected</title>"
    "<style>body{font:15px -apple-system,system-ui,sans-serif;background:#14161a;"
    "color:#d8dee9;display:grid;place-items:center;height:100vh;margin:0}"
    "div{text-align:center}h1{font-size:17px;font-weight:600;margin:0 0 .4rem}"
    "p{color:#7c8899;margin:0}</style>"
    "<div><h1>Account connected</h1><p>You can close this tab.</p></div>";

std::string join(const std::vector<std::string>& parts, char sep) {
  std::string out;
  for (const auto& part : parts) {
    if (!out.empty()) out += sep;
    out += part;
  }
  return out;
}

/// Percent-decodes a query-string value (`%2F` → `/`, `+` → space).
std::string percent_decode(const std::string& input) {
  std::string out;
  out.reserve(input.size());
  for (size_t i = 0; i < input.size(); ++i) {
    if (input[i] == '%' && i + 2 < input.size()) {
      const std::string hex = input.substr(i + 1, 2);
      out += static_cast<char>(std::stoi(hex, nullptr, 16));
      i += 2;
    } else if (input[i] == '+') {
      out += ' ';
    } else {
      out += input[i];
    }
  }
  return out;
}

}  // namespace

// MARK: - LoopbackListener

LoopbackListener::~LoopbackListener() {
  if (socket_ >= 0) {
    close(socket_);
  }
}

Result<uint16_t> LoopbackListener::start() {
  socket_ = ::socket(AF_INET, SOCK_STREAM, 0);
  if (socket_ < 0) {
    return make_error("socket() failed");
  }

  // Without SO_REUSEADDR a rapid re-run can fail while the previous socket
  // lingers in TIME_WAIT.
  int reuse = 1;
  setsockopt(socket_, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));

  sockaddr_in addr{};
  addr.sin_family = AF_INET;
  // Loopback only. Binding INADDR_ANY would expose the redirect listener to
  // the local network for the duration of the flow.
  addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  // Port 0 asks the kernel for any free ephemeral port. Google permits any
  // port on 127.0.0.1 for desktop clients, so nothing needs pre-registering.
  addr.sin_port = 0;

  if (bind(socket_, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) < 0) {
    return make_error("bind() failed");
  }
  if (listen(socket_, 1) < 0) {
    return make_error("listen() failed");
  }

  sockaddr_in bound{};
  socklen_t len = sizeof(bound);
  if (getsockname(socket_, reinterpret_cast<sockaddr*>(&bound), &len) < 0) {
    return make_error("getsockname() failed");
  }
  return ntohs(bound.sin_port);
}

Result<std::string> LoopbackListener::await_redirect(std::chrono::seconds timeout) {
  // select() rather than a blocking accept(), so a user who abandons the
  // consent screen does not hang the process forever.
  fd_set readable;
  FD_ZERO(&readable);
  FD_SET(socket_, &readable);

  timeval tv{};
  tv.tv_sec = static_cast<time_t>(timeout.count());

  const int ready = select(socket_ + 1, &readable, nullptr, nullptr, &tv);
  if (ready == 0) {
    return make_error("timed out waiting for browser redirect");
  }
  if (ready < 0) {
    return make_error("select() failed");
  }

  const int client = accept(socket_, nullptr, nullptr);
  if (client < 0) {
    return make_error("accept() failed");
  }

  // The request line is all we need and always arrives in the first packet:
  //   GET /?code=4/0A...&state=xyz HTTP/1.1
  std::string request;
  char buffer[4096];
  const ssize_t received = recv(client, buffer, sizeof(buffer) - 1, 0);
  if (received > 0) {
    request.assign(buffer, static_cast<size_t>(received));
  }

  send(client, kSuccessPage, strlen(kSuccessPage), 0);
  close(client);

  const size_t start = request.find(' ');
  const size_t end = request.find(' ', start + 1);
  if (start == std::string::npos || end == std::string::npos) {
    return make_error("malformed HTTP request from browser");
  }
  const std::string target = request.substr(start + 1, end - start - 1);

  const size_t question = target.find('?');
  if (question == std::string::npos) {
    return make_error("redirect carried no query string");
  }
  return target.substr(question + 1);
}

std::string query_param(const std::string& query, const std::string& key) {
  const std::string needle = key + "=";
  size_t pos = 0;
  while (pos < query.size()) {
    const size_t amp = query.find('&', pos);
    const std::string pair =
        query.substr(pos, amp == std::string::npos ? std::string::npos : amp - pos);
    if (pair.rfind(needle, 0) == 0) {
      return percent_decode(pair.substr(needle.size()));
    }
    if (amp == std::string::npos) break;
    pos = amp + 1;
  }
  return {};
}

Result<void> open_in_browser(const std::string& url) {
  // posix_spawn rather than system(): no shell is involved, so a URL
  // containing shell metacharacters cannot be interpreted as a command.
  const char* argv[] = {"open", url.c_str(), nullptr};
  pid_t pid = 0;
  const int rc = posix_spawn(&pid, "/usr/bin/open", nullptr, nullptr,
                             const_cast<char* const*>(argv), environ);
  if (rc != 0) {
    return make_error("failed to launch browser", rc);
  }
  return {};
}

// MARK: - OAuthClient

OAuthClient::OAuthClient(OAuthConfig config) : config_(std::move(config)) {}

std::string OAuthClient::build_authorization_url(uint16_t port,
                                                 const std::string& challenge,
                                                 const std::string& state) const {
  const std::string redirect = "http://127.0.0.1:" + std::to_string(port);
  return std::string(kAuthEndpoint) + "?" +
         HttpClient::form_encode({
             {"client_id", config_.client_id},
             {"redirect_uri", redirect},
             {"response_type", "code"},
             {"scope", join(config_.scopes, ' ')},
             {"code_challenge", challenge},
             {"code_challenge_method", "S256"},
             {"state", state},
             // offline + consent is what makes Google return a refresh token.
             // Without them you get an access token that expires in an hour
             // and no way to renew it.
             {"access_type", "offline"},
             {"prompt", "consent"},
         });
}

Result<TokenSet> OAuthClient::exchange_code(const std::string& code,
                                            const std::string& verifier,
                                            uint16_t port) const {
  HttpClient http;
  const std::string redirect = "http://127.0.0.1:" + std::to_string(port);
  const std::string body = HttpClient::form_encode({
      {"client_id", config_.client_id},
      {"client_secret", config_.client_secret},
      {"code", code},
      {"code_verifier", verifier},
      {"grant_type", "authorization_code"},
      {"redirect_uri", redirect},
  });

  auto response = http.post(kTokenEndpoint, body);
  if (!response) {
    return response.error();
  }
  if (!response->ok()) {
    return make_error("token exchange failed: " + response->body,
                      static_cast<int>(response->status));
  }

  const auto json = nlohmann::json::parse(response->body, nullptr, false);
  if (json.is_discarded()) {
    return make_error("token response was not valid JSON");
  }

  TokenSet tokens;
  tokens.access_token = json.value("access_token", "");
  tokens.refresh_token = json.value("refresh_token", "");
  tokens.expires_at = std::chrono::system_clock::now() +
                      std::chrono::seconds(json.value("expires_in", 3600));

  if (tokens.access_token.empty()) {
    return make_error("token response carried no access_token");
  }
  return tokens;
}

Result<std::string> OAuthClient::fetch_email(const std::string& access_token) const {
  HttpClient http;
  auto response = http.get(kUserInfoEndpoint,
                           {{"Authorization", "Bearer " + access_token}});
  if (!response) {
    return response.error();
  }
  if (!response->ok()) {
    return make_error("userinfo failed: " + response->body,
                      static_cast<int>(response->status));
  }
  const auto json = nlohmann::json::parse(response->body, nullptr, false);
  if (json.is_discarded()) {
    return make_error("userinfo response was not valid JSON");
  }
  return json.value("email", std::string{});
}

Result<AuthorizationResult> OAuthClient::authorize_interactively(
    std::chrono::seconds timeout) const {
  if (config_.client_id.empty()) {
    return make_error("GOOGLE_CLIENT_ID is not set");
  }

  auto verifier = crypto::generate_code_verifier();
  if (!verifier) {
    return verifier.error();
  }
  const std::string challenge = crypto::derive_code_challenge(*verifier);

  // CSRF guard: Google echoes this back and we require an exact match, so a
  // redirect we did not initiate is rejected.
  auto state_bytes = crypto::random_bytes(16);
  if (!state_bytes) {
    return state_bytes.error();
  }
  const std::string state = crypto::base64url_encode(*state_bytes);

  LoopbackListener listener;
  auto port = listener.start();
  if (!port) {
    return port.error();
  }

  const std::string url = build_authorization_url(*port, challenge, state);

  // Print the URL as well as opening it. Each run binds a NEW ephemeral port,
  // so a consent page left open from an earlier attempt redirects to a port
  // nothing is listening on — the browser shows "can't connect" and this
  // process waits until it times out. Showing the current URL makes it
  // obvious which tab is the live one.
  std::cout << "  listening on 127.0.0.1:" << *port << "\n"
            << "  if your browser did not open, visit:\n\n"
            << url << "\n\n";

  if (auto opened = open_in_browser(url); !opened) {
    return opened.error();
  }

  auto query = listener.await_redirect(timeout);
  if (!query) {
    return query.error();
  }

  if (const std::string error = query_param(*query, "error"); !error.empty()) {
    return make_error("authorization denied: " + error);
  }
  if (query_param(*query, "state") != state) {
    return make_error("state mismatch — possible CSRF, aborting");
  }

  const std::string code = query_param(*query, "code");
  if (code.empty()) {
    return make_error("redirect carried no authorization code");
  }

  auto tokens = exchange_code(code, *verifier, *port);
  if (!tokens) {
    return tokens.error();
  }
  if (tokens->refresh_token.empty()) {
    return make_error(
        "Google returned no refresh token. Revoke this app's access at "
        "https://myaccount.google.com/permissions and try again.");
  }

  auto email = fetch_email(tokens->access_token);
  if (!email) {
    return email.error();
  }

  return AuthorizationResult{std::move(*tokens), std::move(*email)};
}

Result<TokenSet> OAuthClient::refresh(const std::string& refresh_token) const {
  HttpClient http;
  const std::string body = HttpClient::form_encode({
      {"client_id", config_.client_id},
      {"client_secret", config_.client_secret},
      {"refresh_token", refresh_token},
      {"grant_type", "refresh_token"},
  });

  auto response = http.post(kTokenEndpoint, body);
  if (!response) {
    return response.error();
  }
  if (!response->ok()) {
    return make_error("refresh failed: " + response->body,
                      static_cast<int>(response->status));
  }

  const auto json = nlohmann::json::parse(response->body, nullptr, false);
  if (json.is_discarded()) {
    return make_error("refresh response was not valid JSON");
  }

  TokenSet tokens;
  tokens.access_token = json.value("access_token", "");
  tokens.expires_at = std::chrono::system_clock::now() +
                      std::chrono::seconds(json.value("expires_in", 3600));
  if (tokens.access_token.empty()) {
    return make_error("refresh response carried no access_token");
  }
  return tokens;
}

}  // namespace mailengine
