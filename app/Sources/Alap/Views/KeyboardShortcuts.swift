import SwiftUI

/// Keyboard-first triage.
///
/// ## Why bare letters and not just ⌘-combinations
///
/// Triage is a repetitive loop: look, decide, act, advance. A modifier on every
/// action doubles the keystrokes and forces a hand position change, which is
/// exactly the friction this app exists to remove. So the primary bindings are
/// single letters, in the tradition of mutt, Gmail and Superhuman.
///
/// The tradeoff is that bare letters must not fire while the user is typing.
/// `onKeyPress` only delivers to the focused view, so these are attached to the
/// thread list and are naturally inert while the search field has focus.
///
/// Menu commands mirror the destructive ones with ⌘-equivalents, because a
/// shortcut nobody can discover may as well not exist.
struct TriageKeyboardShortcuts: ViewModifier {
  @Bindable var store: MailStore
  @FocusState.Binding var listFocused: Bool

  func body(content: Content) -> some View {
    content
      .focusable()
      .focusEffectDisabled()
      .focused($listFocused)
      // Navigation. J/K mirror the arrow keys rather than replacing them, so
      // both muscle memories work.
      .onKeyPress("j") { store.moveSelection(by: 1); return .handled }
      .onKeyPress("k") { store.moveSelection(by: -1); return .handled }
      .onKeyPress(.downArrow) { store.moveSelection(by: 1); return .handled }
      .onKeyPress(.upArrow) { store.moveSelection(by: -1); return .handled }

      // Actions.
      .onKeyPress("e") {
        Task { await store.archiveSelectedAndAdvance() }
        return .handled
      }
      .onKeyPress("s") {
        Task { await store.toggleStarOnSelection() }
        return .handled
      }
      .onKeyPress("u") {
        Task { await store.toggleReadOnSelection() }
        return .handled
      }

      // `/` focuses search, the one convention every keyboard-driven app shares.
      .onKeyPress("/") {
        listFocused = false
        return .handled
      }

      .onKeyPress(.escape) {
        if !store.searchText.isEmpty {
          store.searchText = ""
          return .handled
        }
        return .ignored
      }
  }
}

extension View {
  /// Attaches triage key handling. See `TriageKeyboardShortcuts`.
  func triageShortcuts(
    store: MailStore,
    listFocused: FocusState<Bool>.Binding
  ) -> some View {
    modifier(TriageKeyboardShortcuts(store: store, listFocused: listFocused))
  }
}

/// Menu commands.
///
/// These exist for discoverability as much as for use: a bare-letter shortcut
/// is invisible, whereas the menu bar teaches it. Each item shows its
/// ⌘-equivalent and names the single-letter form in its title.
struct MailCommands: Commands {
  let store: MailStore

  var body: some Commands {
    // Replaces the New Item slot that was emptied in MailApp: ⌘N is what
    // every mail client on this platform binds to composing.
    // ⌘A over the message list. Replaces the system Select All, which would
    // otherwise try to select text in whatever field last had focus.
    CommandGroup(replacing: .textEditing) {
      Button("Select All Conversations") { store.selectAll() }
        .keyboardShortcut("a", modifiers: .command)
      Button("Deselect All") { store.clearSelection() }
        .keyboardShortcut("a", modifiers: [.command, .shift])
        .disabled(store.selection.isEmpty)
    }

    CommandGroup(replacing: .newItem) {
      Button("New Message") { store.startNewMessage() }
        .keyboardShortcut("n", modifiers: .command)
      Button("Reply") { store.startReply() }
        .keyboardShortcut("r", modifiers: .command)
        .disabled(store.selectedThread == nil)
    }

    CommandMenu("Message") {
      Button("Archive") {
        Task { await store.archiveSelectedAndAdvance() }
      }
      .keyboardShortcut("e", modifiers: .command)
      .disabled(store.selectedThread == nil)

      Button(store.selectedThread?.isUnread == true ? "Mark as Read" : "Mark as Unread") {
        Task { await store.toggleReadOnSelection() }
      }
      .keyboardShortcut("u", modifiers: .command)
      .disabled(store.selectedThread == nil)

      Button(store.selectedThread?.isStarred == true ? "Remove Star" : "Star") {
        Task { await store.toggleStarOnSelection() }
      }
      .keyboardShortcut("s", modifiers: .command)
      .disabled(store.selectedThread == nil)

      Divider()

      Button("Next Message") { store.moveSelection(by: 1) }
        .keyboardShortcut(.downArrow, modifiers: .command)
      Button("Previous Message") { store.moveSelection(by: -1) }
        .keyboardShortcut(.upArrow, modifiers: .command)
    }
  }
}

/// Appearance switching, under View.
///
/// A menu command rather than a preferences window: there is exactly one
/// setting so far, and a whole window to hold it would be more chrome than
/// content. It moves into Settings the moment there is a second one.
struct ThemeCommands: Commands {
  @Bindable var themes: ThemeController

  var body: some Commands {
    CommandGroup(after: .toolbar) {
      Picker("Appearance", selection: $themes.theme) {
        ForEach(AppTheme.allCases) { theme in
          Label(theme.title, systemImage: theme.symbol).tag(theme)
        }
      }
      .pickerStyle(.inline)

      Divider()
    }
  }
}
