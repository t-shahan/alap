import AppKit
import SwiftUI

/// Makes the red close button actually quit.
///
/// AppKit's default is that closing the last window leaves the process running
/// with only a menu bar — correct for Mail.app or Xcode, where a document-less
/// app is still meaningful, and wrong here. This app is one window; when it is
/// gone there is nothing left to interact with, and a mail client silently
/// holding a Zero client, a WebKit process and a WebSocket open with no visible
/// UI is exactly the kind of background weight this app exists to avoid.
///
/// ⌘W and the red button now do the same thing as ⌘Q.
final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    true
  }
}

@main
struct AlapApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  /// Owned here so the menu commands and the window share one store.
  @State private var store = MailStore()
  @State private var themes = ThemeController.shared

  var body: some Scene {
    WindowGroup {
      ContentView(store: store)
        .frame(minWidth: 900, minHeight: 560)
        // Carries the choice into AppKit's own chrome — scrollbars, the text
        // cursor, focus rings. Without it the surfaces go dark while the
        // scrollbars stay light, which looks like a rendering bug.
        .preferredColorScheme(themes.theme.colorScheme)
    }
    // Hides the title bar text so the split view reads as one continuous
    // surface rather than three stacked panels with a heavy header.
    .windowStyle(.hiddenTitleBar)
    .commands {
      CommandGroup(replacing: .newItem) {}
      MailCommands(store: store)
      ThemeCommands(themes: themes)
    }
  }
}
