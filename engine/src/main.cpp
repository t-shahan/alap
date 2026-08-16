/// @file main.cpp
/// @brief Entry point for the `mailengined` daemon and its setup commands.
///
/// Subcommands:
///   auth <account-id>    Run the interactive OAuth flow and store the refresh
///                        token in the Keychain.
///   token <account-id>   Mint a fresh access token (verifies stored refresh).
///   version
///
/// The sync loops themselves land in the next module.

#include <cstdlib>
#include <iostream>
#include <string>

#include "mailengine/keychain.hpp"
#include "mailengine/oauth.hpp"
#include "mailengine/version.hpp"

namespace {

/// Reads an environment variable, returning empty when unset.
std::string env(const char* name) {
  const char* value = std::getenv(name);
  return value != nullptr ? std::string(value) : std::string{};
}

mailengine::OAuthConfig config_from_env() {
  return mailengine::OAuthConfig{
      .client_id = env("GOOGLE_CLIENT_ID"),
      .client_secret = env("GOOGLE_CLIENT_SECRET"),
  };
}

int usage() {
  std::cerr << "usage: mailengined <command>\n\n"
               "  auth <account-id>    authorize a Gmail account\n"
               "  token <account-id>   mint an access token from the stored refresh token\n"
               "  version\n";
  return 64;  // EX_USAGE
}

int cmd_auth(const std::string& account_id) {
  const mailengine::OAuthClient client(config_from_env());

  std::cout << "Opening your browser to authorize " << account_id << "…\n";
  auto result = client.authorize_interactively();
  if (!result) {
    std::cerr << "error: " << result.error().message << "\n";
    return 1;
  }

  const mailengine::Keychain keychain;
  if (auto stored = keychain.store(account_id, result->tokens.refresh_token); !stored) {
    std::cerr << "error: could not store refresh token: " << stored.error().message
              << "\n";
    return 1;
  }

  // The access token is deliberately not printed or persisted — it lives only
  // in memory for the life of a sync run.
  std::cout << "✓ authorized " << result->email_address << "\n"
            << "  refresh token stored in Keychain under account " << account_id
            << "\n";
  return 0;
}

int cmd_token(const std::string& account_id) {
  const mailengine::Keychain keychain;
  auto refresh_token = keychain.load(account_id);
  if (!refresh_token) {
    std::cerr << "error: " << refresh_token.error().message
              << "\n(run `mailengined auth " << account_id << "` first)\n";
    return 1;
  }

  const mailengine::OAuthClient client(config_from_env());
  auto tokens = client.refresh(*refresh_token);
  if (!tokens) {
    std::cerr << "error: " << tokens.error().message << "\n";
    return 1;
  }

  const auto lifetime = std::chrono::duration_cast<std::chrono::minutes>(
      tokens->expires_at - std::chrono::system_clock::now());
  std::cout << "✓ access token minted (valid " << lifetime.count() << " min, "
            << tokens->access_token.size() << " chars)\n";
  return 0;
}

}  // namespace

int main(int argc, char** argv) {
  if (argc < 2) {
    return usage();
  }
  const std::string command = argv[1];

  if (command == "version") {
    std::cout << "mailengined " << mailengine::version() << "\n";
    return 0;
  }
  if (command == "auth") {
    if (argc < 3) return usage();
    return cmd_auth(argv[2]);
  }
  if (command == "token") {
    if (argc < 3) return usage();
    return cmd_token(argv[2]);
  }

  return usage();
}
