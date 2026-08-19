import SwiftUI

/// The app's one button style.
///
/// ## Why this exists
///
/// Every interactive surface used to invent its own feedback. Nine controls,
/// nine answers: the sidebar row had none at all, the account row tinted to
/// `control`, the attachment chip went to `selection` with a blue border, the
/// bulk button multiplied its own fill by 0.85, and the badge pill reached for
/// a hardcoded `Color.white.opacity(0.1)` that is simply wrong in the light
/// theme. That inconsistency is the main reason the app read less finished than
/// its palette deserved.
///
/// So hover, pressed, disabled and focus live here, once, and every button in
/// the app is one of four roles.
///
/// ## What a role decides
///
/// Only the *resting* treatment. Hover and pressed are the same overlay tints
/// in every role — `Theme.State.hover` / `.pressed`, layered ON whatever the
/// control already sits on, so one value composes correctly against all five
/// surfaces — and disabled is always `Theme.Ink.disabled` with the resting fill
/// dropped. A role that reinvented those would put us back where we started.
struct AlapButtonStyle: ButtonStyle {
  enum Role {
    /// Filled accent, white label. The one primary action in a context.
    case primary
    /// A control-surface fill. Secondary actions with a visible box.
    case secondary
    /// No resting fill. Icon buttons, sidebar rows, inline text actions —
    /// the majority.
    case quiet
    /// Quiet at rest, red on hover. Distance and colour, not colour alone:
    /// giving an irreversible action permanent red makes it the loudest thing
    /// in a toolbar full of things you actually want people to press.
    case destructive
  }

  var role: Role = .quiet
  /// Foreground when ENABLED, overriding the role's default.
  ///
  /// It belongs here rather than on the label. `foregroundStyle` applied
  /// inside the label sits closer to the leaf than the style's own wrap and
  /// therefore WINS — so a label that colours itself silently opts out of the
  /// disabled treatment, which is how two toolbars kept rendering full-strength
  /// ink while disabled and quietly undid the fix for that.
  var tint: Color?
  /// Corner radius of the resting fill and of the hover/pressed overlay.
  /// Scales with the element, per the radius scale.
  var radius: CGFloat = Theme.Radius.control
  /// True when the control is showing an "on" state — a selected sidebar row,
  /// an armed toggle. Carries the resting fill that `quiet` otherwise omits.
  var isOn: Bool = false

  func makeBody(configuration: Configuration) -> some View {
    Surface(configuration: configuration, role: role, radius: radius,
            isOn: isOn, tint: tint)
  }

  /// A nested `View` because a `ButtonStyle` cannot hold `@State` or read
  /// `@Environment` in `makeBody` — and hover and enablement are both needed
  /// to decide the treatment.
  private struct Surface: View {
    let configuration: Configuration
    let role: Role
    let radius: CGFloat
    let isOn: Bool
    let tint: Color?

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
      configuration.label
        .foregroundStyle(foreground)
        .background(restingFill, in: .rect(cornerRadius: radius))
        .overlay { overlayTint.map { $0.clipShape(.rect(cornerRadius: radius)) } }
        .contentShape(.rect(cornerRadius: radius))
        .onHover { isHovering = $0 }
        // `fade`, not a spring: this is a colour change, and a spring on a
        // colour overshoots the destination and comes back.
        .animation(Theme.Motion.fade, value: isHovering)
        .animation(Theme.Motion.fade, value: configuration.isPressed)
        .animation(Theme.Motion.fade, value: isEnabled)
    }

    /// Hover is suppressed while pressed, so the two tints never stack into a
    /// third value nobody chose.
    private var overlayTint: Color? {
      guard isEnabled else { return nil }
      if configuration.isPressed { return Theme.State.pressed }
      return isHovering ? Theme.State.hover : nil
    }

    private var restingFill: Color {
      guard isEnabled else {
        // A disabled primary keeps a fill so the control still reads as a
        // control; it just stops claiming to be the accent.
        return role == .primary ? Theme.Surface.control : .clear
      }
      switch role {
      case .primary: return Theme.Accent.blue
      case .secondary: return Theme.Surface.control
      case .quiet, .destructive: return isOn ? Theme.Surface.control : .clear
      }
    }

    private var foreground: Color {
      guard isEnabled else { return Theme.Ink.disabled }
      if let tint { return tint }
      switch role {
      case .primary: return .white
      case .secondary: return Theme.Ink.primary
      case .quiet: return Theme.Ink.secondary
      case .destructive: return isHovering ? Theme.Accent.red : Theme.Ink.secondary
      }
    }
  }
}

extension ButtonStyle where Self == AlapButtonStyle {
  /// The app's button style. `.quiet` is the default because most buttons here
  /// are bare icons or inline text actions.
  static func alap(
    _ role: AlapButtonStyle.Role = .quiet,
    radius: CGFloat = Theme.Radius.control,
    isOn: Bool = false,
    tint: Color? = nil
  ) -> AlapButtonStyle {
    AlapButtonStyle(role: role, tint: tint, radius: radius, isOn: isOn)
  }
}
