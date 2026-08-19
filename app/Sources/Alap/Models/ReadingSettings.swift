import Foundation
import Observation

/// Preferences that change how a message is rendered.
///
/// ## Why remote images now load by default
///
/// They did not, and the reasoning was sound: a remote image in mail is a
/// tracking pixel more often than it is a picture, and loading one tells the
/// sender the message was opened, by whom, and roughly from where.
///
/// What that reasoning missed is that mail is *designed around* its images.
/// Marketing HTML is a table of image slices; withholding them does not leave a
/// clean text version behind, it leaves a skeleton of empty cells and stray
/// spacing that reads as a broken client rather than a private one. Paying that
/// cost on every message to defeat a pixel on some of them is the wrong trade
/// for a client whose whole point is that reading mail should feel good.
///
/// The privacy control is still here, still one switch, and still honest about
/// what it does — it is just no longer the default. Turning it off restores the
/// previous behaviour exactly, including the per-message "Load images" banner.
@MainActor
@Observable
final class ReadingSettings {
  static let shared = ReadingSettings()

  private static let remoteImagesKey = "reading.loadsRemoteImages"
  private static let densityKey = "reading.listDensity"

  /// Whether remote images load without being asked for.
  ///
  /// Persisted, unlike the old per-thread consent. That was deliberate when the
  /// answer defaulted to "no" — consenting to one sender's images is not
  /// consent for the next one's. It stops making sense as a default of "yes",
  /// where re-asking would only be a switch that forgets what it was set to.
  var loadsRemoteImages: Bool {
    didSet {
      guard loadsRemoteImages != oldValue else { return }
      UserDefaults.standard.set(loadsRemoteImages, forKey: Self.remoteImagesKey)
    }
  }

  /// How dense the thread list is.
  ///
  /// Defaults to `.comfortable` — see `ListDensity.standard` for why, which is
  /// a decision made by opening the running build rather than by argument.
  /// Compact is one setting away for anyone who wants it.
  var listDensity: ListDensity {
    didSet {
      guard listDensity != oldValue else { return }
      UserDefaults.standard.set(listDensity.rawValue, forKey: Self.densityKey)
    }
  }

  private init() {
    // `object(forKey:)` rather than `bool(forKey:)`, which cannot tell an
    // absent key from a stored `false` and would silently override the default.
    let stored = UserDefaults.standard.object(forKey: Self.remoteImagesKey) as? Bool
    loadsRemoteImages = stored ?? true

    // Same `object(forKey:)` discipline: an absent key must resolve to the
    // designed default rather than to whatever `string(forKey:)` returns for
    // nothing.
    let density = UserDefaults.standard.object(forKey: Self.densityKey) as? String
    listDensity = density.flatMap(ListDensity.init(rawValue:)) ?? .standard
  }
}
