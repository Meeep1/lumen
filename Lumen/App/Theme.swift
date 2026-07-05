import SwiftUI

/// Shared visual language — the whole app is locked to light mode (`.preferredColorScheme(.light)`
/// in `LumenApp`), so every color here is a fixed light value, not a dynamic light/dark pair.
/// That used to matter (see git history) when the app followed the system appearance; now it's
/// one warm, consistent look everywhere regardless of the device's dark-mode setting.
extension Color {
    static let lumenBackground = Color(red: 0.99, green: 0.98, blue: 0.97)
    /// Card/sheet surface — plain white, sits one step brighter than the background.
    static let lumenCard = Color.white
    /// Muted fill for secondary surfaces (text field backgrounds, inactive chips) — replaces
    /// `Color(uiColor: .systemGray6)`.
    static let lumenSurface = Color(red: 0.95, green: 0.945, blue: 0.94)
    /// One step darker than `lumenSurface`, for placeholder/loading blocks — replaces
    /// `Color(uiColor: .systemGray5)`.
    static let lumenSurfaceStrong = Color(red: 0.905, green: 0.9, blue: 0.895)
    /// Hairline dividers — replaces `Color(uiColor: .separator)`.
    static let lumenDivider = Color(red: 0.88, green: 0.87, blue: 0.865)
    static let lumenTextSecondary = Color(red: 0.45, green: 0.43, blue: 0.42)
}

enum Theme {
    static let primaryGradient = LinearGradient(
        colors: [Color.pink, Color(red: 0.65, green: 0.35, blue: 0.85)],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    enum Radius {
        static let large: CGFloat = 20
        static let medium: CGFloat = 16
        static let small: CGFloat = 12
    }
}

// MARK: - Button styles

/// Primary CTA — gradient fill, white text, subtle press-down scale so every main action button
/// in the app feels the same to tap instead of some being plain opacity-only system buttons.
struct LumenPrimaryButtonStyle: ButtonStyle {
    var isEnabled: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(isEnabled ? AnyShapeStyle(Theme.primaryGradient) : AnyShapeStyle(Color.gray.opacity(0.35)))
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.medium))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Secondary action — quiet card-colored fill, pink text. Used for "Log In" on the auth landing
/// screen, "Skip" isn't this (it's plain text), but things like "Cancel"-weight actions are.
struct LumenSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundColor(.pink)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(Color.lumenSurface)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.medium))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Small circular icon button — back/close/ellipsis chrome. This is what replaces every system
/// toolbar button across the app: same shape (a soft filled circle) everywhere instead of each
/// screen's own one-off `Image(systemName:)` in a bare `Button`.
struct LumenIconButtonStyle: ButtonStyle {
    var tint: Color = .primary
    var background: Color = Color.lumenSurface

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(tint)
            .frame(width: 34, height: 34)
            .background(background, in: Circle())
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.65), value: configuration.isPressed)
    }
}

/// Generic "press to shrink slightly" wrapper for tappable rows/cards that aren't full buttons
/// (e.g. list rows, chips) — gives every tappable surface in the app the same tactile feedback.
struct LumenPressableStyle: ButtonStyle {
    var scale: CGFloat = 0.97

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}
