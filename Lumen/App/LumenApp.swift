import SwiftUI

@main
struct LumenApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var authManager = AuthenticationManager.shared
    @StateObject private var socketManager = SocketManager.shared

    var body: some Scene {
        WindowGroup {
            Group {
                if authManager.isAuthenticated {
                    if let user = authManager.currentUser {
                        if user.needsOnboarding {
                            OnboardingView()
                                .environmentObject(authManager)
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
