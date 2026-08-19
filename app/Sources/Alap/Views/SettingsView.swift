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
      // Named and described, in two groups.
      //
      // This was one inline `Picker` of bare titles, which worked while there
      // were three appearances and two of them were called Dark and Light.
      // With six — three of them dark — a column of names is a column of names:
      // nothing in "Signature / Dark / Umber" says which is which, and Settings
      // is precisely where someone is deliberately shopping rather than
      // flipping between two they already know.
      //
      // Grouped by polarity for the same reason `allCases` is ordered that way:
      // the first question anyone actually has is light or dark, and answering
      // it once halves the list instead of asking it six times.
      Section {
        ForEach(AppTheme.allCases.filter(\.isDark)) { theme in
          themeRow(theme)
        }
      } header: {
        Text("Appearance — dark").font(Theme.Font.bodyEmphasis)
      }

      Section {
        ForEach(AppTheme.allCases.filter { !$0.isDark }) { theme in
          themeRow(theme)
        }
      } header: {
        Text("Appearance — light").font(Theme.Font.bodyEmphasis)
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

  /// One appearance, as a row rather than a `Picker` entry.
  ///
  /// Hand-built for the same reason `FromField` and the sidebar switcher are:
  /// a `Picker` renders its items as bare labels and gives no place to put the
  /// subtitle, which is the whole reason this section changed. The radio mark
  /// is drawn rather than inherited, so it stays on the palette's own tokens.
  private func themeRow(_ theme: AppTheme) -> some View {
    Button {
      // A colour interpolation, so never a spring — the same rule the switcher
      // and `Theme.Motion.fade` state.
      withAnimation(Theme.Motion.fade) { themes.theme = theme }
    } label: {
      HStack(spacing: Theme.Space.loose) {
        Image(systemName: themes.theme == theme ? "largecircle.fill.circle" : "circle")
          .font(Theme.Icon.small)
          .foregroundStyle(themes.theme == theme ? Theme.Accent.blueText : Theme.Ink.tertiary)
          .accessibilityHidden(true)

        VStack(alignment: .leading, spacing: 0) {
          Text(theme.title)
            .font(Theme.Font.body)
            .foregroundStyle(Theme.Ink.primary)
          Text(theme.subtitle)
            .font(Theme.Font.micro)
            .fontWeight(.regular)
            .foregroundStyle(Theme.Ink.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }

        Spacer(minLength: 0)
      }
      .padding(.vertical, Theme.Space.tight)
      .contentShape(.rect)
    }
    .buttonStyle(.alap())
    .accessibilityLabel("\(theme.title). \(theme.subtitle)")
    .accessibilityAddTraits(themes.theme == theme ? [.isSelected] : [])
  }
}
