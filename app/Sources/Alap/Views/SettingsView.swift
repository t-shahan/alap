import SwiftUI

/// The ⌘, window.
///
/// Deliberately small. A settings window is where preferences go to be found,
/// not where features go to hide — anything that belongs in the main window
/// should stay there. Today that is the theme, which already has a menu and a
/// control in the sidebar; the list density, which is where a Mac user looks
/// for it; and the remote-image switch, which has nowhere else to live because
/// it is a standing decision rather than a per-message one.
struct SettingsView: View {
  @Bindable var settings: ReadingSettings
  @Bindable var themes: ThemeController

  var body: some View {
    Form {
      Section {
        Picker("Theme", selection: $themes.theme) {
          ForEach(AppTheme.allCases, id: \.self) { theme in
            Text(theme.title).tag(theme)
          }
        }
        .pickerStyle(.inline)
      } header: {
        Text("Appearance").font(Theme.Font.bodyEmphasis)
      }

      Section {
        Picker("Density", selection: $settings.listDensity) {
          ForEach(ListDensity.allCases) { density in
            Text(density.title).tag(density)
          }
        }
        .pickerStyle(.inline)

        Text(settings.listDensity.subtitle)
          .font(Theme.Font.micro)
          .fontWeight(.regular)
          .foregroundStyle(Theme.Ink.tertiary)
          .fixedSize(horizontal: false, vertical: true)
      } header: {
        Text("Conversation list").font(Theme.Font.bodyEmphasis)
      }

      Section {
        Toggle("Load remote images", isOn: $settings.loadsRemoteImages)

        // States the actual trade rather than a reassurance. The switch is the
        // one place in the app where the honest answer is "this leaks
        // something", and burying that would make the setting decorative.
        Text(settings.loadsRemoteImages
             ? "Messages render as their senders designed them. Opening one "
               + "tells the sender it was opened, and roughly from where."
             : "Images are withheld until you ask for them, per message. "
               + "Some messages will look broken, because they are built "
               + "entirely out of images.")
          .font(Theme.Font.micro)
          .fontWeight(.regular)
          .foregroundStyle(Theme.Ink.tertiary)
          .fixedSize(horizontal: false, vertical: true)
      } header: {
        Text("Privacy").font(Theme.Font.bodyEmphasis)
      }
    }
    .formStyle(.grouped)
    .frame(width: 420)
    .fixedSize(horizontal: false, vertical: true)
  }
}
