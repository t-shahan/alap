/// @file html.hpp
/// @brief HTML sanitizer for message bodies.
///
/// ## Why this exists
///
/// `migrations/0001_init.sql` describes `message_body.html_body` as sanitised.
/// Until now it was not — raw provider HTML went straight into Postgres, which
/// meant the schema made a promise the code did not keep, and the SwiftUI
/// reading pane had to downgrade every message to plain text rather than risk
/// rendering it.
///
/// Mail HTML is genuinely hostile input. It is authored by strangers, and it
/// arrives with scripts, tracking pixels, remote CSS, and URLs designed to
/// exfiltrate or mislead.
///
/// ## Approach
///
/// A strict ALLOWLIST driven by a small tokenizer.
///
/// Allowlisting is the only defensible choice: a blocklist fails open, so
/// every tag or attribute the author did not think of becomes a hole. Here,
/// anything not explicitly permitted is dropped.
///
/// A tokenizer rather than regular expressions, because regex-based HTML
/// sanitizers are a well-known source of bypasses — nested quoting, malformed
/// tags, comment tricks and encoded delimiters all defeat pattern matching.
/// Walking the input character by character means malformed markup degrades
/// into escaped text instead of slipping through as markup.

#pragma once

#include <string>

namespace mailengine::html {

/// @brief Sanitizer policy.
struct SanitizeOptions {
  /// Whether to keep images loaded from remote servers.
  ///
  /// Off by default. A remote image is the standard email tracking pixel: it
  /// reports back that a message was opened, when, and from which IP. Blocking
  /// them by default is a privacy decision, and matches what Apple Mail and
  /// Gmail do. Inline `cid:` images referencing our own attachments are always
  /// kept — they are already downloaded and leak nothing.
  bool allow_remote_images = false;
};

/// @brief Result of sanitizing, including what was removed.
struct SanitizeResult {
  /// Safe HTML, ready to render.
  std::string html;
  /// Remote images suppressed. Surfaced so the UI can offer "load images".
  int blocked_remote_images = 0;
  /// True when script, style or similar executable content was discarded.
  bool removed_active_content = false;
};

/// @brief Sanitizes untrusted HTML against a strict allowlist.
///
/// Guarantees on the output:
///   - no `<script>`, `<style>`, `<iframe>`, `<object>`, `<embed>`, `<form>`,
///     `<link>`, `<meta>` or `<base>`, and none of their contents
///   - no `on*` event-handler attributes
///   - no `javascript:`, `vbscript:` or `data:` URLs
///   - no `style` or `class` attributes, so remote CSS and layout attacks
///     cannot be smuggled in
///   - every `<a>` gains `rel="noopener noreferrer"`
///   - all text content is entity-escaped
[[nodiscard]] SanitizeResult sanitize(const std::string& input,
                                      const SanitizeOptions& options = {});

/// @brief Decodes HTML entities into their characters.
///
/// Gmail returns `snippet` HTML-escaped, so a subject line reaches us as
/// "Next week&#39;s menu". Rendering that verbatim in a native list shows the
/// raw entity, which looks broken. Decoding happens once on ingest.
[[nodiscard]] std::string unescape_entities(const std::string& text);

/// @brief Collapses runs of invisible preheader padding.
///
/// Bulk senders pad the inbox preview with long runs of characters that render
/// to nothing — `&shy;`, `&zwnj;`, `&#847;`, `&#8199;` — so the preview shows
/// their tagline instead of the body. It is meant to be invisible, and mostly
/// is, but it leaves a wall of whitespace above the message, and a sender that
/// double-encodes it (`&amp;shy;`) turns the padding into visible literal text.
///
/// Only DENSE runs are collapsed. A lone `&shy;` is a hyphenation hint and a
/// lone `&nbsp;` is a meaningful space; both survive. A run has to carry
/// several invisible characters before it is treated as padding.
///
/// Tag-aware: markup passes through byte-identical, so this is safe to run
/// over already-sanitised HTML where `data-blocked-src` holds the only copy of
/// a blocked image URL.
[[nodiscard]] std::string collapse_padding(const std::string& html);

/// @brief Escapes text so it cannot be interpreted as markup.
[[nodiscard]] std::string escape_text(const std::string& text);

/// @brief True when `url` uses a scheme safe to emit in an href.
///
/// Permits http, https, mailto, cid, and scheme-relative or relative URLs.
/// Everything else — notably `javascript:` and `data:` — is rejected, and
/// leading whitespace, control characters and mixed case are normalised first
/// because those are the classic ways of disguising a scheme.
[[nodiscard]] bool is_safe_url(const std::string& url);

}  // namespace mailengine::html
