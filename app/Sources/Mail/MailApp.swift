import SwiftUI

@main
struct MailApp: App {
  /// Owned here so the menu commands and the window share one store.
  @State private var store = MailStore()

  var body: some Scene {
    WindowGroup {
      ContentView(store: store)
        .frame(minWidth: 900, minHeight: 560)
    }
    // Hides the title bar text so the split view reads as one continuous
    // surface rather than three stacked panels with a heavy header.
    .windowStyle(.hiddenTitleBar)
    .commands {
      CommandGroup(replacing: .newItem) {}
      MailCommands(store: store)
    }
  }
}
