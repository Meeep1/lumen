import SwiftUI

@main
struct LumenApp: App {
    @StateObject private var authManager = AuthenticationManager.shared
    @StateObject private var socketManager = SocketManager.shared

    var body: some Scene {
        WindowGroup {
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
        VStack(spacing: 20) {
            ProgressView()

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
                        .background(Color.pink.gradient)
                        .clipShape(Capsule())
                }

                Button {
                    Task { await authManager.logout() }
                } label: {
                    Text("Log Out")
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(.red)
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
