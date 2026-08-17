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

  /// The sync engine, stopped explicitly on quit.
  ///
  /// Without this the child outlives the app: a terminated parent does not take
  /// its children with it, so quitting would leave an orphaned process polling
  /// Gmail with no window to show it in.
  @MainActor var daemon: SyncDaemon?

  func applicationWillTerminate(_ notification: Notification) {
    MainActor.assumeIsolated { daemon?.stop() }
  }
}

@main
struct AlapApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  /// Owned here so the menu commands and the window share one store.
  @State private var store = MailStore()
  @State private var themes = ThemeController.shared
  @State private var daemon = SyncDaemon()
  @State private var settings = ReadingSettings.shared

  var body: some Scene {
    WindowGroup {
      ContentView(store: store)
        // The narrowest layout is a hidden sidebar (0) + list (300) + the reading
        // pane floor (380). Below that something has to be squeezed, so the
        // window refuses instead.
        .frame(minWidth: 680, minHeight: 480)
        // Started with the window, so the first incremental poll happens as
        // the app appears — which is what makes opening it show current mail
        // rather than whatever was there when it last closed.
        .task {
          appDelegate.daemon = daemon
          daemon.start()
        }
        // Carries the choice into AppKit's own chrome — scrollbars, the text
        // cursor, focus rings. Without it the surfaces go dark while the
        // scrollbars stay light, which looks like a rendering bug.
        .preferredColorScheme(themes.theme.colorScheme)
    }
    // Hides the title bar text so the split view reads as one continuous
    // surface rather than three stacked panels with a heavy header.
    .windowStyle(.hiddenTitleBar)
    .commands {
      MailCommands(store: store)
      ThemeCommands(themes: themes)
    }

    // ⌘, for free, and the standard place a Mac user looks for a preference.
    Settings {
      SettingsView(settings: settings, themes: themes)
        .preferredColorScheme(themes.theme.colorScheme)
    }
  }
}
