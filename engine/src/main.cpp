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
#include <optional>
#include <string>

#include "mailengine/gmail.hpp"
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
               "  auth <account-id>     authorize a Gmail account\n"
               "  token <account-id>    mint an access token from the stored refresh token\n"
               "  profile <account-id>  show mailbox profile and history watermark\n"
               "  labels <account-id>   list Gmail labels\n"
               "  peek <account-id> [n] fetch and print the newest n messages\n"
               "  check <account-id> [n] parse-health report over n messages (no content)\n"
               "  version\n";
  return 64;  // EX_USAGE
}


int cmd_profile(const std::string& account_id) {
  auto tokens = mailengine::TokenProvider(config_from_env(), account_id);
  mailengine::GmailClient gmail(tokens);

  auto profile = gmail.get_profile();
  if (!profile) {
    std::cerr << "error: " << profile.error().message << "\n";
    return 1;
  }
  std::cout << "  address    " << profile->email_address << "\n"
            << "  messages   " << profile->messages_total << "\n"
            << "  historyId  " << profile->history_id << "\n";
  return 0;
}

int cmd_labels(const std::string& account_id) {
  auto tokens = mailengine::TokenProvider(config_from_env(), account_id);
  mailengine::GmailClient gmail(tokens);

  auto labels = gmail.list_labels();
  if (!labels) {
    std::cerr << "error: " << labels.error().message << "\n";
    return 1;
  }
  std::cout << labels->size() << " labels\n";
  for (const auto& label : *labels) {
    std::cout << "  " << (label.type == "system" ? "[sys] " : "      ") << label.name
              << "  (" << label.id << ")\n";
  }
  return 0;
}

int cmd_peek(const std::string& account_id, int count) {
  auto tokens = mailengine::TokenProvider(config_from_env(), account_id);
  mailengine::GmailClient gmail(tokens);

  auto page = gmail.list_messages({}, "in:inbox", count);
  if (!page) {
    std::cerr << "error: " << page.error().message << "\n";
    return 1;
  }

  std::cout << "newest " << page->message_ids.size() << " inbox messages\n\n";
  for (const auto& id : page->message_ids) {
    auto message = gmail.get_message(id);
    if (!message) {
      std::cerr << "  ! " << id << ": " << message.error().message << "\n";
      continue;
    }
    const std::string who =
        message->from.name.empty() ? message->from.email : message->from.name;
    std::cout << (message->is_unread() ? "  * " : "    ") << who << "\n"
              << "      " << message->subject << "\n"
              << "      " << message->snippet.substr(0, 78) << "\n";
    if (!message->attachments.empty()) {
      std::cout << "      " << message->attachments.size() << " attachment(s)\n";
    }
    std::cout << "\n";
  }
  return 0;
}

/// Fetches a sample of real mail and reports parse health in aggregate.
///
/// Prints NO message content — only counts. Real inboxes are a far harsher
/// test of the MIME decoder than any fixture, and building the ingest pipeline
/// on a parser that silently drops bodies would be a bad trade.
int cmd_check(const std::string& account_id, int count) {
  auto tokens = mailengine::TokenProvider(config_from_env(), account_id);
  mailengine::GmailClient gmail(tokens);

  auto page = gmail.list_messages({}, {}, count);
  if (!page) {
    std::cerr << "error: " << page.error().message << "\n";
    return 1;
  }

  int parsed = 0, failed = 0;
  int undecoded_words = 0, non_ascii_subjects = 0, empty_subjects = 0;
  int no_body = 0, html_only = 0, text_only = 0, both_bodies = 0;
  int with_attachments = 0, inline_images = 0;
  int missing_from_name = 0, missing_rfc_id = 0;

  for (const auto& id : page->message_ids) {
    auto message = gmail.get_message(id);
    if (!message) {
      ++failed;
      std::cerr << "  ! parse failed: " << message.error().message << "\n";
      continue;
    }
    ++parsed;

    // A surviving "=?" means an encoded-word the decoder did not handle —
    // it would render as gibberish in the UI.
    if (message->subject.find("=?") != std::string::npos) ++undecoded_words;
    if (message->subject.empty()) ++empty_subjects;
    for (const unsigned char c : message->subject) {
      if (c > 127) { ++non_ascii_subjects; break; }
    }

    const bool has_text = !message->text_body.empty();
    const bool has_html = !message->html_body.empty();
    if (!has_text && !has_html) ++no_body;
    else if (has_text && has_html) ++both_bodies;
    else if (has_html) ++html_only;
    else ++text_only;

    if (!message->attachments.empty()) ++with_attachments;
    for (const auto& attachment : message->attachments) {
      if (attachment.is_inline) { ++inline_images; break; }
    }

    if (message->from.name.empty()) ++missing_from_name;
    if (message->rfc822_message_id.empty()) ++missing_rfc_id;
  }

  std::cout << "\n  sampled            " << page->message_ids.size() << "\n"
            << "  parsed             " << parsed << "\n"
            << "  parse failures     " << failed
            << (failed ? "   <-- investigate" : "") << "\n"
            << "\n  subjects\n"
            << "    non-ASCII        " << non_ascii_subjects
            << "   (decoder exercised)\n"
            << "    undecoded =?..?= " << undecoded_words
            << (undecoded_words ? "   <-- DECODER BUG" : "   ok") << "\n"
            << "    empty            " << empty_subjects << "\n"
            << "\n  bodies\n"
            << "    text + html      " << both_bodies << "\n"
            << "    html only        " << html_only << "\n"
            << "    text only        " << text_only << "\n"
            << "    NO body          " << no_body
            << (no_body ? "   <-- investigate" : "   ok") << "\n"
            << "\n  other\n"
            << "    with attachments " << with_attachments << "\n"
            << "    inline images    " << inline_images << "\n"
            << "    no sender name   " << missing_from_name << "\n"
            << "    no Message-ID    " << missing_rfc_id << "\n\n";
  return 0;
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
  if (command == "profile") {
    if (argc < 3) return usage();
    return cmd_profile(argv[2]);
  }
  if (command == "labels") {
    if (argc < 3) return usage();
    return cmd_labels(argv[2]);
  }
  if (command == "check") {
    if (argc < 3) return usage();
    return cmd_check(argv[2], argc > 3 ? std::atoi(argv[3]) : 40);
  }
  if (command == "peek") {
    if (argc < 3) return usage();
    return cmd_peek(argv[2], argc > 3 ? std::atoi(argv[3]) : 5);
  }

  return usage();
}
