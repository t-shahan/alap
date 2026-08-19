import Foundation

extension Int {
  /// A count, abbreviated once the full figure stops being worth its width.
  ///
  /// Both the sidebar badges and the status rail need this and they need to
  /// AGREE about what a number looks like — but not about where to abbreviate,
  /// because they have very different amounts of room. A badge is a ~40pt pill
  /// and abbreviates almost immediately; the rail has most of a sidebar line
  /// and can afford four digits. Hence the threshold is a parameter and the
  /// arithmetic is not duplicated.
  ///
  /// - Parameter threshold: The first value that gets abbreviated.
  func abbreviatedCount(above threshold: Int = 10_000) -> String {
    switch self {
    case ..<threshold: formatted()
    case ..<1_000_000: String(format: "%.1fk", Double(self) / 1000)
    default: String(format: "%.1fM", Double(self) / 1_000_000)
    }
  }
}
