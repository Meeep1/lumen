import SwiftUI

@main
struct LumenApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var authManager = AuthenticationManager.shared
    @StateObject private var socketManager = SocketManager.shared
    /// Latches true the moment onboarding is first shown, independent of `user.needsOnboarding`
    /// re-evaluating in the meantime. `needsOnboarding` is a live, data-driven check (has a
    /// location + a photo) — but `currentUser` can legitimately reload mid-onboarding (e.g. the
    /// first photo finishing moderation posts .photoReviewed, which reloads the profile to
    /// refresh its status), and the instant that reload lands, `needsOnboarding` can already read
    /// false even though the user is still on, say, the "About" step. Without this latch that
    /// reload alone would swap the whole root view straight to MainTabView, silently skipping
    /// everything after whichever step they were on. Only OnboardingView's own completion (via
    /// onFinish below) clears it, so the manual Skip/Continue buttons remain the only way out.
    @State private var isOnboarding = false

    var body: some Scene {
        WindowGroup {
            Group {
                if authManager.isAuthenticated {
                    if let user = authManager.currentUser {
                        if isOnboarding || user.needsOnboarding {
                            OnboardingView(onFinish: { isOnboarding = false })
                                .environmentObject(authManager)
                                .onAppear { isOnboarding = true }
                        } else {
                            MainTabView()
                                .environmentObject(authManager)
                                .environmentObject(socketManager)
                        }
                    } else {
                        SessionLoadingView()
                            .environmentObject(authManager)
                    }
                } else {
                    AuthenticationView()
                        .environmentObject(authManager)
                }
            }
            // The whole app is designed as one light, white/warm-off-white look — locking the
            // color scheme means it renders that way regardless of the device's system dark-mode
            // setting, rather than needing every custom color to carry its own light/dark variant.
            .preferredColorScheme(.light)
        }
    }
}

/// Shown while the stored session's profile is loading. AuthenticationManager already
/// auto-logs-out on an expired/invalid token (APIError.unauthorized), but any other failure
/// (e.g. a dropped connection) shouldn't be able to strand the app on a bare spinner forever —
/// this offers a way out after a few seconds instead of spinning indefinitely.
private struct SessionLoadingView: View {
    @EnvironmentObject var authManager: AuthenticationManager
    @State private var showOptions = false

    var body: some View {
        ZStack {
            Color.lumenBackground
                .ignoresSafeArea()

            VStack(spacing: 20) {
                Image(systemName: "heart.circle.fill")
                    .resizable()
                    .frame(width: 80, height: 80)
                    .foregroundStyle(Theme.primaryGradient)

                Text("Lumen")
                    .font(.system(size: 36, weight: .bold, design: .rounded))

                ProgressView()
                    .padding(.top, 8)

                if showOptions {
                    Text("This is taking longer than expected.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Button {
                        showOptions = false
                        Task { await authManager.loadCurrentUser() }
                    } label: {
                        Text("Try Again")
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 12)
                            .background(Theme.primaryGradient)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(LumenPressableStyle())

                    Button {
                        Task { await authManager.logout() }
                    } label: {
                        Text("Log Out")
                            .font(.subheadline.weight(.medium))
                            .foregroundColor(.red)
                    }
                    .buttonStyle(LumenPressableStyle())
                }
            }
        }
        .task {
            try? await Task.sleep(for: .seconds(5))
            if authManager.currentUser == nil {
                showOptions = true
            }
        }
    }
}
