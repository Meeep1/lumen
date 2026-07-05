import SwiftUI
import AuthenticationServices

private struct AppleSignupInfo: Identifiable, Hashable {
    let id = UUID()
    let identityToken: String
    let email: String?
}

struct AuthenticationView: View {
    @EnvironmentObject var authManager: AuthenticationManager
    @State private var showSignup = false
    @State private var appleSignupInfo: AppleSignupInfo?
    @State private var appleErrorMessage: String?

    // Hidden switch between local dev and production, for fast manual testing against either
    // server without rebuilding — see BackendEnvironment.swift. Doesn't exist in Release builds.
    #if DEBUG
    @State private var logoTapCount = 0
    @State private var lastLogoTapTime = Date.distantPast
    @State private var showEnvironmentPicker = false
    @ObservedObject private var environmentStore = BackendEnvironmentStore.shared
    #endif

    var body: some View {
        NavigationStack {
            ZStack {
                Color.lumenBackground.ignoresSafeArea()

                VStack(spacing: 32) {
                    Spacer()

                    // Logo and branding
                    VStack(spacing: 16) {
                        Image(systemName: "heart.circle.fill")
                            .resizable()
                            .frame(width: 100, height: 100)
                            .foregroundStyle(Theme.primaryGradient)
                            #if DEBUG
                            // 5 taps within 1.5s of each other unlocks the environment picker —
                            // deliberately not documented UI, just a fast escape hatch for testing.
                            .onTapGesture {
                                let now = Date()
                                if now.timeIntervalSince(lastLogoTapTime) > 1.5 { logoTapCount = 0 }
                                lastLogoTapTime = now
                                logoTapCount += 1
                                if logoTapCount >= 5 {
                                    logoTapCount = 0
                                    showEnvironmentPicker = true
                                }
                            }
                            #endif

                        Text("Lumen")
                            .font(.system(size: 48, weight: .bold, design: .rounded))

                        Text("Fem-for-fem dating")
                            .font(.title3)
                            .foregroundStyle(.secondary)

                        #if DEBUG
                        Text("[DEBUG] \(environmentStore.current.displayName)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        #endif
                    }

                    Spacer()

                    // Buttons
                    VStack(spacing: 16) {
                        NavigationLink(destination: SignupView()) {
                            Text("Create Account")
                        }
                        .buttonStyle(LumenPrimaryButtonStyle())

                        NavigationLink(destination: LoginView()) {
                            Text("Log In")
                        }
                        .buttonStyle(LumenSecondaryButtonStyle())

                        // Apple requires their own exact button (no custom styling/reskinning) per
                        // their Human Interface Guidelines — this is the one native-looking control
                        // in the app that's supposed to stay that way.
                        SignInWithAppleButton(.signIn) { request in
                            request.requestedScopes = [.email]
                        } onCompletion: { result in
                            handleAppleCompletion(result)
                        }
                        .signInWithAppleButtonStyle(.black)
                        .frame(height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.medium))
                    }
                    .padding(.horizontal, 32)
                    .padding(.bottom, 48)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .customAlert(
                isPresented: Binding(
                    get: { authManager.suspensionMessage != nil },
                    set: { if !$0 { authManager.suspensionMessage = nil } }
                ),
                title: "Account Suspended",
                message: authManager.suspensionMessage ?? ""
            )
            .customAlert(
                isPresented: Binding(get: { appleErrorMessage != nil }, set: { if !$0 { appleErrorMessage = nil } }),
                title: "Couldn't Sign In",
                message: appleErrorMessage ?? ""
            )
            .navigationDestination(item: $appleSignupInfo) { info in
                SignupView(appleIdentityToken: info.identityToken, prefillEmail: info.email)
            }
            #if DEBUG
            .confirmationDialog(
                "Backend Environment",
                isPresented: $showEnvironmentPicker,
                titleVisibility: .visible
            ) {
                ForEach(BackendEnvironment.allCases) { env in
                    Button(env == environmentStore.current ? "✓ \(env.displayName)" : env.displayName) {
                        environmentStore.current = env
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Currently: \(environmentStore.current.baseURL)\nRestart the app after switching so open connections pick it up.")
            }
            #endif
        }
    }

    private func handleAppleCompletion(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .failure(let error):
            // Code 1001 is the user dismissing the Apple sheet themselves — not a real error.
            if (error as NSError).code != ASAuthorizationError.canceled.rawValue {
                appleErrorMessage = error.localizedDescription
            }
        case .success(let authorization):
            guard
                let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                let tokenData = credential.identityToken,
                let identityToken = String(data: tokenData, encoding: .utf8)
            else {
                appleErrorMessage = "Apple didn't return a usable credential. Try again."
                return
            }

            Task {
                let result = await authManager.signInWithApple(identityToken: identityToken)
                switch result {
                case .success(.needsSignup(let token, let email)):
                    appleSignupInfo = AppleSignupInfo(identityToken: token, email: email)
                case .success(.authenticated):
                    break // AuthenticationManager already flipped isAuthenticated — LumenApp takes over.
                case .failure(let error):
                    appleErrorMessage = error.localizedDescription
                }
            }
        }
    }
}

#Preview {
    AuthenticationView()
        .environmentObject(AuthenticationManager.shared)
}
