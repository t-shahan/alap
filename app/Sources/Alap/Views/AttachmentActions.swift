import AppKit
import SwiftUI

/// What can be done with a downloaded attachment, in one place.
///
/// The chip's context menu had these and the menu bar did not, which made
/// Open / Reveal / Save a Copy reachable by pointer only — there was no
/// keyboard path to any of them. Mirroring the actions into the Message menu
/// means two call sites, and two call sites means this stops being a private
/// method on a view.
enum AttachmentActions {
  /// Shows the file in Finder.
  ///
  /// The cache stores blobs under a content hash, so the file on disk is not
  /// named anything a person would recognise — which is why Reveal exists
  /// alongside Save a Copy rather than instead of it.
  @MainActor
  static func reveal(_ file: URL) {
    NSWorkspace.shared.activateFileViewerSelecting([file])
  }

  /// Copies the blob out under its real filename.
  ///
  /// Exporting is where the display name from Postgres finally gets applied —
  /// and note it is applied by `NSSavePanel`, which resolves the user's chosen
  /// destination itself. The email-supplied name never becomes a path we
  /// construct.
  @MainActor
  static func saveCopy(of file: URL, named filename: String) {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = filename
    panel.canCreateDirectories = true
    guard panel.runModal() == .OK, let destination = panel.url else { return }
    try? FileManager.default.removeItem(at: destination)
    try? FileManager.default.copyItem(at: file, to: destination)
  }
}
