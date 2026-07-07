import Foundation

enum APIError: Error, LocalizedError {
    case invalidURL
    case networkError(Error)
    case invalidResponse
    case decodingError(Error)
    case serverError(String)
    case unauthorized
    case accountSuspended(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid URL"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .invalidResponse:
            return "Invalid response from server"
        case .decodingError(let error):
            return "Failed to decode response: \(error.localizedDescription)"
        case .serverError(let message):
            return message
        case .unauthorized:
            return "Unauthorized. Please log in again."
        case .accountSuspended(let message):
            return message
        }
    }
}

extension Notification.Name {
    /// Posted whenever a request comes back with `code: "ACCOUNT_SUSPENDED"` — APIService has
    /// no reference to AuthenticationManager (would be a circular dependency), so it broadcasts
    /// instead of calling it directly. AuthenticationManager listens and forces a logout.
    static let accountSuspended = Notification.Name("accountSuspended")
}

class APIService {
    static let shared = APIService()
    
    // Debug builds read from BackendEnvironmentStore (flippable at runtime via a hidden gesture
    // on the login screen — see AuthenticationView) so local dev vs. production can be switched
    // without rebuilding. Release builds hit production directly, no toggle — no manual flip
    // needed before archiving for TestFlight/App Store.
    #if DEBUG
    private var baseURL: String { BackendEnvironmentStore.shared.current.baseURL }
    #else
    private let baseURL = "https://lumenfem.app"
    #endif

    /// Backend photo URLs (from `getPresignedUrl` in local-dev mode) are host-relative paths
    /// like "/uploads/photos/…", not full URLs — resolve them against baseURL so AsyncImage
    /// actually has a host to fetch from. Safe to call with an already-absolute URL string too.
    func imageURL(for path: String?) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        if path.hasPrefix("http://") || path.hasPrefix("https://") {
            return URL(string: path)
        }
        return URL(string: "\(baseURL)\(path)")
    }

    // Internal (not private) so LumenTests can exercise the exact same decoder configuration
    // real network responses go through — see LumenTests/APIServiceDecodingTests.swift.
    let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        // Backend sends camelCase keys throughout (see backend/src/utils/validation.ts) —
        // do not convert case here, it would leave keys like "dateOfBirth" untouched but
        // silently break on any future snake_case-looking key.
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let dateString = try container.decode(String.self)
            
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            
            if let date = formatter.date(from: dateString) {
                return date
            }
            
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: dateString) {
                return date
            }
            
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date format")
        }
        return decoder
    }()
    
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
    
    private init() {}
    
    // MARK: - Generic Request Method
    
    private func request<T: Codable>(
        endpoint: String,
        method: String = "GET",
        body: Codable? = nil,
        requiresAuth: Bool = true
    ) async throws -> T {
        guard let url = URL(string: "\(baseURL)\(endpoint)") else {
            throw APIError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = method

        if requiresAuth, let token = KeychainManager.shared.getAccessToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        // Only claim a JSON content-type when we actually send a body — URLSession sends an
        // explicit zero-length body alongside the header otherwise, and Fastify's JSON parser
        // rejects that combination outright (FST_ERR_CTP_EMPTY_JSON_BODY) before routing even
        // runs. Bit us on DELETE /account, which has no body.
        if let body = body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try encoder.encode(body)
        }
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw APIError.invalidResponse
            }
            
            if httpResponse.statusCode == 401 {
                // Try to refresh token
                if try await refreshAccessToken() {
                    // Retry the request
                    return try await self.request(endpoint: endpoint, method: method, body: body, requiresAuth: requiresAuth)
                } else {
                    throw APIError.unauthorized
                }
            }
            
            if httpResponse.statusCode >= 400 {
                if let errorResponse = try? decoder.decode(ErrorResponse.self, from: data) {
                    if errorResponse.code == "ACCOUNT_SUSPENDED" {
                        NotificationCenter.default.post(name: .accountSuspended, object: nil, userInfo: ["message": errorResponse.error])
                        throw APIError.accountSuspended(errorResponse.error)
                    }
                    throw APIError.serverError(errorResponse.error)
                }
                throw APIError.serverError("Server error: \(httpResponse.statusCode)")
            }

            return try decoder.decode(T.self, from: data)
        } catch let error as APIError {
            throw error
        } catch {
            throw APIError.networkError(error)
        }
    }
    
    // MARK: - Auth Endpoints
    
    func signup(request: SignupRequest) async throws -> (userId: String, message: String) {
        struct Response: Codable {
            let userId: String
            let message: String
        }
        let response: Response = try await self.request(
            endpoint: "/auth/signup",
            method: "POST",
            body: request,
            requiresAuth: false
        )
        return (response.userId, response.message)
    }
    
    /// POST /auth/apple can mean two different things depending on whether this Apple ID has
    /// an account yet — a 404 with code APPLE_SIGNUP_REQUIRED is an expected outcome, not an
    /// error, so this bypasses the generic `request()` helper (which treats every 4xx as a
    /// throw) to handle that case explicitly instead.
    func signInWithApple(identityToken: String) async throws -> AppleSignInOutcome {
        guard let url = URL(string: "\(baseURL)/auth/apple") else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(AppleAuthRequest(identityToken: identityToken))

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        if httpResponse.statusCode == 404,
           let errorResponse = try? decoder.decode(ErrorResponse.self, from: data),
           errorResponse.code == "APPLE_SIGNUP_REQUIRED" {
            struct SignupRequiredResponse: Codable { let email: String? }
            let details = try? decoder.decode(SignupRequiredResponse.self, from: data)
            return .needsSignup(identityToken: identityToken, email: details?.email)
        }

        if httpResponse.statusCode >= 400 {
            if let errorResponse = try? decoder.decode(ErrorResponse.self, from: data) {
                throw APIError.serverError(errorResponse.error)
            }
            throw APIError.serverError("Server error: \(httpResponse.statusCode)")
        }

        let authResponse = try decoder.decode(AuthResponse.self, from: data)
        return .authenticated(authResponse)
    }

    func verifyOTP(request: VerifyOTPRequest) async throws -> AuthResponse {
        return try await self.request(
            endpoint: "/auth/verify-otp",
            method: "POST",
            body: request,
            requiresAuth: false
        )
    }
    
    func resendOTP(email: String) async throws -> String {
        struct Request: Codable {
            let email: String
        }
        struct Response: Codable {
            let message: String
        }
        let response: Response = try await self.request(
            endpoint: "/auth/resend-otp",
            method: "POST",
            body: Request(email: email),
            requiresAuth: false
        )
        return response.message
    }
    
    func login(request: LoginRequest) async throws -> AuthResponse {
        return try await self.request(
            endpoint: "/auth/login",
            method: "POST",
            body: request,
            requiresAuth: false
        )
    }
    
    func refreshAccessToken() async throws -> Bool {
        guard let refreshToken = KeychainManager.shared.getRefreshToken() else {
            return false
        }
        
        struct Response: Codable {
            let accessToken: String
        }
        
        do {
            let response: Response = try await self.request(
                endpoint: "/auth/refresh",
                method: "POST",
                body: RefreshTokenRequest(refreshToken: refreshToken),
                requiresAuth: false
            )
            KeychainManager.shared.saveAccessToken(response.accessToken)
            return true
        } catch {
            return false
        }
    }
    
    func logout(refreshToken: String) async throws {
        struct Request: Codable {
            let refreshToken: String
        }
        struct Response: Codable {
            let message: String
        }
        let _: Response = try await self.request(
            endpoint: "/auth/logout",
            method: "POST",
            body: Request(refreshToken: refreshToken),
            requiresAuth: false
        )
    }

    /// Self-service account deletion (App Store requirement — app_spec.md Section 3.9).
    /// Permanently deletes the account and all associated data server-side.
    func deleteAccount() async throws {
        struct Response: Codable {
            let message: String
        }
        let _: Response = try await request(
            endpoint: "/account",
            method: "DELETE"
        )
    }

    // MARK: - Profile Endpoints
    
    func getMyProfile() async throws -> User {
        return try await request(endpoint: "/profile/me")
    }
    
    func getUserProfile(userId: String) async throws -> User {
        return try await request(endpoint: "/profile/\(userId)")
    }
    
    // PATCH /profile/me only echoes back the fields it accepts (bio, pronouns, styleTags,
    // cityDisplay, discoverable), not a full User — callers reload the full profile via
    // getMyProfile() afterward, so we only need to confirm the request succeeded.
    func updateProfile(update: ProfileUpdate) async throws {
        struct Response: Codable {
            let message: String
        }
        let _: Response = try await request(
            endpoint: "/profile/me",
            method: "PATCH",
            body: update
        )
    }

    /// Registers this device's APNs token with the backend so it knows where to send real push
    /// notifications once the app is backgrounded/closed — see PushNotificationManager.swift.
    func registerPushToken(_ token: String) async throws {
        struct TokenBody: Codable {
            let token: String
            let platform: String
        }
        struct Response: Codable {
            let message: String
        }
        let _: Response = try await request(
            endpoint: "/profile/push-token",
            method: "POST",
            body: TokenBody(token: token, platform: "ios")
        )
    }

    /// Self-hosted onboarding funnel — see OnboardingEvent's own comment in schema.prisma for
    /// why this isn't a third-party analytics SDK. Deliberately fire-and-forget: callers should
    /// never block the onboarding flow itself on this, and a dropped event just slightly
    /// undercounts a step in the admin funnel view, not something a real user would ever notice.
    func logOnboardingStep(_ step: String) async {
        struct Body: Codable { let step: String }
        struct Response: Codable { let recorded: Bool }
        do {
            let _: Response = try await request(
                endpoint: "/profile/onboarding-event",
                method: "POST",
                body: Body(step: step)
            )
        } catch {
            // Fire-and-forget, see the doc comment above — nothing to surface here.
        }
    }

    /// No auth — a crash can happen while logged out, or before a session even exists, and the
    /// whole point of this endpoint is to still capture that. See CrashReporter.swift.
    func reportDiagnostic(_ report: DiagnosticReport) async throws {
        struct Response: Codable {
            let message: String
        }
        let _: Response = try await request(
            endpoint: "/diagnostics/report",
            method: "POST",
            body: report,
            requiresAuth: false
        )
    }

    /// Uploads a photo as multipart/form-data — separate from the JSON `request` helper above
    /// since POST /profile/photos expects a file part, not a JSON body.
    func uploadPhoto(imageData: Data) async throws -> Photo {
        guard let url = URL(string: "\(baseURL)/profile/photos") else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        if let token = KeychainManager.shared.getAccessToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"photo\"; filename=\"photo.jpg\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
        body.append(imageData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        if httpResponse.statusCode >= 400 {
            if let errorResponse = try? decoder.decode(ErrorResponse.self, from: data) {
                throw APIError.serverError(errorResponse.error)
            }
            throw APIError.serverError("Server error: \(httpResponse.statusCode)")
        }

        return try decoder.decode(Photo.self, from: data)
    }

    /// Uploads and sends a chat image in one call — mirrors `uploadPhoto`'s raw multipart
    /// construction (same reason: this is a file part, not a JSON body), posting to
    /// POST /matches/:matchId/messages/photo, which creates the Message server-side and
    /// broadcasts it the same way a text message is, so there's no separate "now send it" step.
    func sendChatImage(matchId: String, imageData: Data) async throws -> Message {
        guard let url = URL(string: "\(baseURL)/matches/\(matchId)/messages/photo") else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        if let token = KeychainManager.shared.getAccessToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"chat.jpg\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
        body.append(imageData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        if httpResponse.statusCode >= 400 {
            if let errorResponse = try? decoder.decode(ErrorResponse.self, from: data) {
                throw APIError.serverError(errorResponse.error)
            }
            throw APIError.serverError("Server error: \(httpResponse.statusCode)")
        }

        struct MessageResponse: Codable { let message: Message }
        return try decoder.decode(MessageResponse.self, from: data).message
    }

    func deletePhoto(photoId: String) async throws {
        struct Response: Codable { let message: String }
        let _: Response = try await request(
            endpoint: "/profile/photos/\(photoId)",
            method: "DELETE"
        )
    }

    /// A rejected photo is kept (not deleted) specifically so this has something to review —
    /// see routes/moderation.ts. Message is optional context for the reviewer, not required.
    func appealPhoto(photoId: String, message: String?) async throws {
        struct Request: Codable { let message: String? }
        struct Response: Codable { let message: String }
        let _: Response = try await request(
            endpoint: "/profile/photos/\(photoId)/appeal",
            method: "POST",
            body: Request(message: message)
        )
    }

    /// Sends the full photo ID list in the new order — the backend re-numbers `order` 0..n to
    /// match this array's position, so this should always be called with every photo ID, not
    /// just the ones that moved.
    func reorderPhotos(photoIds: [String]) async throws {
        struct Request: Codable { let photoIds: [String] }
        struct Response: Codable { let message: String }
        let _: Response = try await request(
            endpoint: "/profile/photos/reorder",
            method: "PUT",
            body: Request(photoIds: photoIds)
        )
    }

    // MARK: - Verification Endpoints

    func getVerificationStatus() async throws -> VerificationStatusResponse {
        return try await request(endpoint: "/verification/status")
    }

    /// Fetches a fresh pose prompt the user must actually do in their selfie — call this right
    /// before opening the camera, not earlier, since it expires after 10 minutes server-side.
    func getVerificationPose() async throws -> VerificationPoseResponse {
        return try await request(endpoint: "/verification/pose")
    }

    /// Multipart upload, same shape as uploadPhoto(imageData:) — verification selfies aren't
    /// JSON, they're a file part. `pose` is sent as a field *before* the file part deliberately:
    /// @fastify/multipart only exposes non-file fields that arrived earlier in the stream than
    /// whichever file part `request.file()` is currently parsing.
    func submitVerificationPhoto(imageData: Data, poseId: String) async throws {
        guard let url = URL(string: "\(baseURL)/verification/submit") else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        if let token = KeychainManager.shared.getAccessToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"pose\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(poseId)\r\n".data(using: .utf8)!)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"photo\"; filename=\"selfie.jpg\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
        body.append(imageData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        if httpResponse.statusCode >= 400 {
            if let errorResponse = try? decoder.decode(ErrorResponse.self, from: data) {
                throw APIError.serverError(errorResponse.error)
            }
            throw APIError.serverError("Server error: \(httpResponse.statusCode)")
        }
    }

    // MARK: - Discovery Endpoints
    
    func getDiscoveryStack(filters: DiscoveryFilters?) async throws -> [DiscoveryProfile] {
        var endpoint = "/discovery/stack"
        
        if let filters = filters {
            var queryItems: [String] = []
            if let minAge = filters.minAge {
                queryItems.append("minAge=\(minAge)")
            }
            if let maxAge = filters.maxAge {
                queryItems.append("maxAge=\(maxAge)")
            }
            if let maxDistance = filters.maxDistance {
                queryItems.append("maxDistance=\(maxDistance)")
            }
            if let minHeightInches = filters.minHeightInches {
                queryItems.append("minHeightInches=\(minHeightInches)")
            }
            if let maxHeightInches = filters.maxHeightInches {
                queryItems.append("maxHeightInches=\(maxHeightInches)")
            }
            // Only ever send `true` — the backend coerces query strings with Zod, and
            // `Boolean("false")` is `true` in JS, so a literal "false" would backfire.
            if filters.verifiedOnly == true {
                queryItems.append("verifiedOnly=true")
            }
            if let genderIdentities = filters.genderIdentities, !genderIdentities.isEmpty {
                let identitiesParam = genderIdentities.joined(separator: ",")
                queryItems.append("genderIdentities=\(identitiesParam)")
            }
            
            if !queryItems.isEmpty {
                endpoint += "?" + queryItems.joined(separator: "&")
            }
        }
        
        struct Response: Codable {
            let profiles: [DiscoveryProfile]
        }
        let response: Response = try await request(endpoint: endpoint)
        return response.profiles
    }
    
    // MARK: - Swipe Endpoints
    
    func swipe(action: SwipeAction) async throws -> SwipeResult {
        return try await request(
            endpoint: "/swipe",
            method: "POST",
            body: action
        )
    }
    
    /// Undoes only the caller's own most recent swipe, and only if it hasn't already resulted
    /// in a match — see the backend route's own comment for why. Throws `APIError.serverError`
    /// (via the generic request path's non-2xx handling) with the backend's message if it's
    /// already matched or there's nothing to undo, so callers can show that directly.
    func undoLastSwipe() async throws -> UndoSwipeResult {
        return try await request(endpoint: "/swipe/last", method: "DELETE")
    }

    func getLikedMeProfiles() async throws -> [LikeReceived] {
        struct Response: Codable {
            let profiles: [LikeReceived]
        }
        let response: Response = try await request(endpoint: "/swipe/liked-me")
        return response.profiles
    }
    
    // MARK: - Match Endpoints
    
    func getMatches() async throws -> [Match] {
        struct Response: Codable {
            let matches: [Match]
        }
        let response: Response = try await request(endpoint: "/matches")
        return response.matches
    }
    
    func getMessages(matchId: String) async throws -> [Message] {
        struct Response: Codable {
            let messages: [Message]
        }
        let response: Response = try await request(endpoint: "/matches/\(matchId)/messages")
        return response.messages
    }
    
    func sendMessage(matchId: String, message: SendMessage) async throws -> Message {
        struct Response: Codable {
            let message: Message
        }
        let response: Response = try await request(
            endpoint: "/matches/\(matchId)/messages",
            method: "POST",
            body: message
        )
        return response.message
    }
    
    func unmatch(matchId: String) async throws {
        struct Response: Codable {
            let message: String
        }
        let _: Response = try await request(
            endpoint: "/matches/\(matchId)",
            method: "DELETE"
        )
    }
    
    // MARK: - Report Endpoints
    
    func reportUser(report: ReportRequest) async throws {
        struct Response: Codable {
            let message: String
            let reportId: String
        }
        let _: Response = try await request(
            endpoint: "/reports",
            method: "POST",
            body: report
        )
    }
    
    // MARK: - Feedback Endpoints

    func submitFeedback(message: String) async throws {
        struct Request: Codable { let message: String }
        struct Response: Codable { let message: String }
        let _: Response = try await request(
            endpoint: "/feedback",
            method: "POST",
            body: Request(message: message)
        )
    }

    // MARK: - Block Endpoints
    
    func blockUser(userId: String) async throws {
        struct Response: Codable {
            let message: String
        }
        let _: Response = try await request(
            endpoint: "/blocks",
            method: "POST",
            body: BlockRequest(blockedId: userId)
        )
    }
    
    func getBlockedUsers() async throws -> [String] {
        struct BlockInfo: Codable {
            let id: String
            let userId: String
            let blockedAt: Date
        }
        struct Response: Codable {
            let blocks: [BlockInfo]
        }
        let response: Response = try await request(endpoint: "/blocks")
        return response.blocks.map { $0.userId }
    }
    
    func unblockUser(userId: String) async throws {
        struct Response: Codable {
            let message: String
        }
        let _: Response = try await request(
            endpoint: "/blocks/\(userId)",
            method: "DELETE"
        )
    }
}
