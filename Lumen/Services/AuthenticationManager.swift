import Foundation
import Combine

@MainActor
class AuthenticationManager: ObservableObject {
    static let shared = AuthenticationManager()
    
    @Published var isAuthenticated = false
    @Published var currentUser: User?
    @Published var isLoading = false
    @Published var errorMessage: String?
    /// Set when the backend reports the account is suspended (any authenticated request, not
    /// just login — see `authenticate` middleware). AuthenticationView shows this as an alert
    /// once the forced logout below lands the user back there.
    @Published var suspensionMessage: String?

    private var suspensionObserver: NSObjectProtocol?
    private var photoReviewedObserver: NSObjectProtocol?

    private init() {
        // Check if user is already authenticated
        if KeychainManager.shared.getAccessToken() != nil {
            isAuthenticated = true
            Task {
                await loadCurrentUser()
            }
        }

        suspensionObserver = NotificationCenter.default.addObserver(
            forName: .accountSuspended, object: nil, queue: .main
        ) { [weak self] notification in
            let message = (notification.userInfo?["message"] as? String) ?? "Your account has been suspended."
            Task { @MainActor in
                self?.forceLogout(message: message)
            }
        }

        // A photo getting approved/rejected happens entirely server-side (an admin acting, or
        // a rescan) — without this, `currentUser.photos` would stay stale until something else
        // happened to trigger a reload, showing outdated statuses/badges.
        photoReviewedObserver = NotificationCenter.default.addObserver(
            forName: .photoReviewed, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.loadCurrentUser()
            }
        }
    }

    private func forceLogout(message: String) {
        SocketManager.shared.disconnect()
        KeychainManager.shared.clearAll()
        isAuthenticated = false
        currentUser = nil
        suspensionMessage = message
    }
    
    // MARK: - Sign Up Flow
    
    func signup(
        name: String,
        email: String,
        phone: String,
        password: String?,
        appleIdentityToken: String? = nil,
        dateOfBirth: Date,
        genderIdentity: GenderIdentity,
        genderIdentityOther: String?,
        femAttestationAccepted: Bool
    ) async -> Result<String, Error> {
        isLoading = true
        errorMessage = nil

        defer { isLoading = false }

        // Format date as ISO8601 string
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let dobString = formatter.string(from: dateOfBirth)

        let request = SignupRequest(
            name: name,
            email: email,
            phone: phone,
            password: password,
            appleIdentityToken: appleIdentityToken,
            dateOfBirth: dobString,
            genderIdentity: genderIdentity.rawValue,
            genderIdentityOther: genderIdentityOther,
            femAttestationAccepted: femAttestationAccepted
        )

        do {
            let (userId, _) = try await APIService.shared.signup(request: request)
            return .success(userId)
        } catch {
            errorMessage = error.localizedDescription
            return .failure(error)
        }
    }

    // MARK: - Sign in with Apple

    /// Either logs straight in (existing Apple-linked or matching-email account) or signals
    /// that this Apple ID needs to go through signup — still needs phone/OTP, age, gender, fem
    /// attestation the same as any account here, Apple only ever replaces the password step.
    func signInWithApple(identityToken: String) async -> Result<AppleSignInOutcome, Error> {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let outcome = try await APIService.shared.signInWithApple(identityToken: identityToken)

            if case .authenticated(let authResponse) = outcome {
                KeychainManager.shared.saveAccessToken(authResponse.accessToken)
                KeychainManager.shared.saveRefreshToken(authResponse.refreshToken)
                KeychainManager.shared.saveUserId(authResponse.user.id)

                isAuthenticated = true
                await loadCurrentUser()
                SocketManager.shared.connect()
            }

            return .success(outcome)
        } catch {
            errorMessage = error.localizedDescription
            return .failure(error)
        }
    }
    
    func verifyOTP(email: String, code: String) async -> Result<Void, Error> {
        isLoading = true
        errorMessage = nil

        defer { isLoading = false }

        let request = VerifyOTPRequest(email: email, code: code)
        
        do {
            let authResponse = try await APIService.shared.verifyOTP(request: request)
            
            // Save tokens
            KeychainManager.shared.saveAccessToken(authResponse.accessToken)
            KeychainManager.shared.saveRefreshToken(authResponse.refreshToken)
            KeychainManager.shared.saveUserId(authResponse.user.id)
            
            isAuthenticated = true
            
            // Load full user profile
            await loadCurrentUser()
            
            // Connect socket
            SocketManager.shared.connect()
            
            return .success(())
        } catch {
            errorMessage = error.localizedDescription
            return .failure(error)
        }
    }
    
    func resendOTP(email: String) async -> Result<String, Error> {
        isLoading = true
        errorMessage = nil

        defer { isLoading = false }

        do {
            let message = try await APIService.shared.resendOTP(email: email)
            return .success(message)
        } catch {
            errorMessage = error.localizedDescription
            return .failure(error)
        }
    }
    
    // MARK: - Login
    
    func login(email: String, password: String) async -> Result<Void, Error> {
        isLoading = true
        errorMessage = nil
        
        defer { isLoading = false }
        
        let request = LoginRequest(email: email, password: password)
        
        do {
            let authResponse = try await APIService.shared.login(request: request)
            
            // Save tokens
            KeychainManager.shared.saveAccessToken(authResponse.accessToken)
            KeychainManager.shared.saveRefreshToken(authResponse.refreshToken)
            KeychainManager.shared.saveUserId(authResponse.user.id)
            
            isAuthenticated = true
            
            // Load full user profile
            await loadCurrentUser()
            
            // Connect socket
            SocketManager.shared.connect()
            
            return .success(())
        } catch {
            errorMessage = error.localizedDescription
            return .failure(error)
        }
    }
    
    // MARK: - Logout
    
    func logout() async {
        isLoading = true
        
        defer {
            isLoading = false
        }
        
        // Disconnect socket
        SocketManager.shared.disconnect()
        
        // Call logout API
        if let refreshToken = KeychainManager.shared.getRefreshToken() {
            try? await APIService.shared.logout(refreshToken: refreshToken)
        }
        
        // Clear keychain
        KeychainManager.shared.clearAll()
        
        // Update state
        isAuthenticated = false
        currentUser = nil
    }

    // MARK: - Delete Account

    func deleteAccount() async -> Result<Void, Error> {
        isLoading = true
        defer { isLoading = false }

        do {
            try await APIService.shared.deleteAccount()
            SocketManager.shared.disconnect()
            KeychainManager.shared.clearAll()
            isAuthenticated = false
            currentUser = nil
            return .success(())
        } catch {
            errorMessage = error.localizedDescription
            return .failure(error)
        }
    }

    // MARK: - Load Current User
    
    func loadCurrentUser() async {
        do {
            let user = try await APIService.shared.getMyProfile()
            currentUser = user
        } catch APIError.unauthorized {
            // Stored tokens are expired/invalid or the account no longer exists (Keychain
            // survives app reinstalls, so this is a normal thing to hit during dev/testing).
            // Fall back to login instead of leaving the app stuck on a loading screen forever.
            KeychainManager.shared.clearAll()
            isAuthenticated = false
            currentUser = nil
        } catch APIError.accountSuspended {
            // Already handled by the .accountSuspended notification observer (forced logout +
            // suspensionMessage set) — nothing further to do here.
        } catch {
            print("Failed to load current user: \(error)")
            errorMessage = error.localizedDescription
        }
    }
    
    // MARK: - Update Profile
    
    func updateProfile(_ update: ProfileUpdate) async -> Result<Void, Error> {
        isLoading = true
        errorMessage = nil
        
        defer { isLoading = false }
        
        do {
            try await APIService.shared.updateProfile(update: update)
            // Reload full profile
            await loadCurrentUser()
            return .success(())
        } catch {
            errorMessage = error.localizedDescription
            return .failure(error)
        }
    }
}
