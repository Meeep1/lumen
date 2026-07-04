import SwiftUI

/// Shared visual language — warm off-white background instead of stark system gray/white,
/// closer to what dating apps like Hinge use, per direct design reference from the user.
///
/// This has to be a *dynamic* color (adapting to light/dark mode) rather than a fixed
/// Color(red:green:blue:) — a fixed light cream stayed light even in dark mode, clashing badly
/// with system-adaptive text/card colors that turned white-on-white or otherwise inverted
/// around it.
extension Color {
    static let lumenBackground = Color(uiColor: UIColor { traitCollection in
        traitCollection.userInterfaceStyle == .dark
            ? UIColor(red: 0.11, green: 0.10, blue: 0.10, alpha: 1)
            : UIColor(red: 0.98, green: 0.96, blue: 0.93, alpha: 1)
    })
}
