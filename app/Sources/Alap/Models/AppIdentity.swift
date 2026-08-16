import Foundation

/// The application's identity, in one place.
///
/// These strings were previously copy-pasted across several files, which is how
/// a rename half-lands — the cache moves but the log subsystem does not, and
/// nothing points at the discrepancy until you go looking for logs that were
/// never written under the name you searched for.
///
/// The engine owns the same values in `identity.hpp` and performs the migration
/// from the previous identity. Both sides must agree; there is no mechanism
/// enforcing that beyond this comment, so change them together.
enum AppIdentity {
  /// Human-facing product name. Appears in the window, the Dock and the menu.
  static let name = "Alap"

  /// Reverse-DNS identifier — bundle id, Keychain service, log subsystem.
  static let bundleID = "app.alap.mail"

  /// `~/Library/Application Support/Alap`, where the search index lives.
  ///
  /// Product-named rather than reverse-DNS: the user sees this path when they
  /// go looking, and a reverse-DNS string tells them nothing.
  static var applicationSupport: URL {
    FileManager.default
      .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent(name)
  }

  /// `~/Library/Caches/Alap`, where downloaded attachments live.
  static var caches: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Caches")
      .appendingPathComponent(name)
  }
}
