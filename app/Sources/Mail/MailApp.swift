import SwiftUI

@main
struct MailApp: App {
  var body: some Scene {
    WindowGroup {
      ContentView()
        .frame(minWidth: 900, minHeight: 560)
    }
    // Hides the title bar text so the split view reads as one continuous
    // surface rather than three stacked panels with a heavy header.
    .windowStyle(.hiddenTitleBar)
    .commands {
      CommandGroup(replacing: .newItem) {}
    }
  }
}
