import Foundation

// MARK: - User Models

struct User: Codable, Identifiable {
    let id: String
    let email: String?
    let phone: String?
    let dateOfBirth: Date?
    let age: Int?
    let genderIdentity: GenderIdentity
    let genderIdentityOther: String?
    let bio: String?
    let pronouns: String?
    let styleTags: [String]
    let heightInches: Int?
    let jobTitle: String?
    let school: String?
    let prompt1Question: String?
    let prompt1Answer: String?
    let prompt2Question: String?
    let prompt2Answer: String?
    let latitude: Double?
    let longitude: Double?
    let cityDisplay: String?
    let isVerified: Bool
    let discoverable: Bool?
    let notifyNewMatch: Bool?
    let notifyNewMessage: Bool?
    let notifyNewLike: Bool?
    let photos: [Photo]

    var displayName: String {
        genderIdentity.displayName
    }

    /// Discovery requires a location, and profiles need at least one photo (Section 3.2 of
    /// app_spec.md) — a user missing either hasn't finished onboarding yet.
    var needsOnboarding: Bool {
        latitude == nil || longitude == nil || photos.isEmpty
    }

    var heightDisplay: String? {
        guard let heightInches else { return nil }
        return "\(heightInches / 12)'\(heightInches % 12)\""
    }

    var prompts: [(question: String, answer: String)] {
        [(prompt1Question, prompt1Answer), (prompt2Question, prompt2Answer)]
            .compactMap { q, a in
                guard let q, let a, !a.isEmpty else { return nil }
                return (q, a)
            }
    }
}

/// Hinge-style preset prompt questions — kept in sync by hand with PROMPT_QUESTIONS in
/// backend/src/utils/validation.ts.
enum PromptQuestion: String, CaseIterable {
    case randomFact = "A random fact I love is..."
    case idealSunday = "My ideal Sunday..."
    case winMeOver = "The way to win me over is..."
    case competitive = "I'm weirdly competitive about..."
    case twoTruths = "Two truths and a lie..."
    case loveLanguage = "My love language is..."
}

enum GenderIdentity: String, Codable, CaseIterable {
    case woman
    case femboy
    case transWoman = "trans_woman"
    case nonbinaryFeminine = "nonbinary_feminine"
    case other
    
    var displayName: String {
        switch self {
        case .woman: return "Woman"
        case .femboy: return "Femboy"
        case .transWoman: return "Trans Woman"
        case .nonbinaryFeminine: return "Nonbinary (Feminine)"
        case .other: return "Other"
        }
    }
}

struct Photo: Codable, Identifiable {
    let id: String
    let url: String
    let order: Int
    let moderationStatus: String?
    let appealStatus: String?
    let appealMessage: String?
    /// False (or absent, e.g. a freshly-uploaded photo) means either it's not rejected at all,
    /// or a human already reviewed it (manual reject, or a previously denied appeal) — either
    /// way, no appeal option should show.
    let canAppeal: Bool?
}

// MARK: - Profile Models

struct VerificationStatusResponse: Codable {
    let isVerified: Bool
    let status: String // "none" | "pending" | "approved" | "rejected"
    let photoUrl: String?
    let reviewedAt: Date?
}

struct ProfileUpdate: Codable {
    let bio: String?
    let pronouns: String?
    let styleTags: [String]?
    let heightInches: Int?
    let jobTitle: String?
    let school: String?
    let prompt1Question: String?
    let prompt1Answer: String?
    let prompt2Question: String?
    let prompt2Answer: String?
    let latitude: Double?
    let longitude: Double?
    let cityDisplay: String?
    let discoverable: Bool?
    let notifyNewMatch: Bool?
    let notifyNewMessage: Bool?
    let notifyNewLike: Bool?

    init(
        bio: String?, pronouns: String?, styleTags: [String]?, heightInches: Int?,
        jobTitle: String?, school: String?, prompt1Question: String?, prompt1Answer: String?,
        prompt2Question: String?, prompt2Answer: String?, latitude: Double?, longitude: Double?,
        cityDisplay: String?, discoverable: Bool?,
        notifyNewMatch: Bool? = nil, notifyNewMessage: Bool? = nil, notifyNewLike: Bool? = nil
    ) {
        self.bio = bio
        self.pronouns = pronouns
        self.styleTags = styleTags
        self.heightInches = heightInches
        self.jobTitle = jobTitle
        self.school = school
        self.prompt1Question = prompt1Question
        self.prompt1Answer = prompt1Answer
        self.prompt2Question = prompt2Question
        self.prompt2Answer = prompt2Answer
        self.latitude = latitude
        self.longitude = longitude
        self.cityDisplay = cityDisplay
        self.discoverable = discoverable
        self.notifyNewMatch = notifyNewMatch
        self.notifyNewMessage = notifyNewMessage
        self.notifyNewLike = notifyNewLike
    }
}

// MARK: - Discovery Models

struct DiscoveryProfile: Codable, Identifiable {
    let id: String
    let age: Int
    let genderIdentity: GenderIdentity
    let genderIdentityOther: String?
    let bio: String?
    let pronouns: String?
    let styleTags: [String]
    let heightInches: Int?
    let jobTitle: String?
    let school: String?
    let prompt1Question: String?
    let prompt1Answer: String?
    let prompt2Question: String?
    let prompt2Answer: String?
    let cityDisplay: String?
    let isVerified: Bool
    let distance: Int
    let primaryPhoto: String?
    let photos: [Photo]

    var heightDisplay: String? {
        guard let heightInches else { return nil }
        return "\(heightInches / 12)'\(heightInches % 12)\""
    }

    var prompts: [(question: String, answer: String)] {
        [(prompt1Question, prompt1Answer), (prompt2Question, prompt2Answer)]
            .compactMap { q, a in
                guard let q, let a, !a.isEmpty else { return nil }
                return (q, a)
            }
    }

    /// Same as `prompts`, but keeps the prompt number (1 or 2) so a targeted like can reference
    /// which one was liked — see SwipeAction.likedPromptNumber.
    var numberedPrompts: [(number: Int, question: String, answer: String)] {
        [(1, prompt1Question, prompt1Answer), (2, prompt2Question, prompt2Answer)]
            .compactMap { number, q, a in
                guard let q, let a, !a.isEmpty else { return nil }
                return (number, q, a)
            }
    }

    /// Renders your own profile through the exact same card the rest of the app swipes on, so
    /// "preview my profile" shows the real thing rather than a lookalike built separately.
    init(previewing user: User) {
        id = user.id
        age = user.age ?? 0
        genderIdentity = user.genderIdentity
        genderIdentityOther = user.genderIdentityOther
        bio = user.bio
        pronouns = user.pronouns
        styleTags = user.styleTags
        heightInches = user.heightInches
        jobTitle = user.jobTitle
        school = user.school
        prompt1Question = user.prompt1Question
        prompt1Answer = user.prompt1Answer
        prompt2Question = user.prompt2Question
        prompt2Answer = user.prompt2Answer
        cityDisplay = user.cityDisplay
        isVerified = user.isVerified
        distance = 0
        // GET /profile/me (unlike every real DiscoveryProfile-shaped response) deliberately
        // returns every photo regardless of moderation status, so Edit Profile can show why a
        // pending/rejected one isn't live — but that means unfiltered `user.photos` here would
        // preview photos matches never actually see, defeating the entire point of "see what
        // others see" (guaranteed to match, not just resemble, real discovery cards).
        let approvedPhotos = user.photos.filter { $0.moderationStatus == "approved" }
        primaryPhoto = approvedPhotos.first?.url
        photos = approvedPhotos
    }
}

struct DiscoveryFilters: Codable {
    var minAge: Int?
    var maxAge: Int?
    var maxDistance: Int?
    var minHeightInches: Int?
    var maxHeightInches: Int?
    var verifiedOnly: Bool?
    var genderIdentities: [String]?
}

// MARK: - Swipe Models

enum SwipeDirection: String, Codable {
    case like
    case pass
    case superLike = "super_like"
}

struct SwipeAction: Codable {
    let swipedId: String
    let direction: SwipeDirection
    let likedPhotoId: String?
    let likedPromptNumber: Int?
    let message: String?
}

struct SwipeResult: Codable {
    let matched: Bool
    let matchId: String?
    let matchedUser: MatchedUser?
}

// MARK: - Likes You Models

struct LikeReceived: Codable, Identifiable {
    let id: String
    let age: Int
    let genderIdentity: GenderIdentity
    let genderIdentityOther: String?
    let bio: String?
    let pronouns: String?
    let styleTags: [String]
    let heightInches: Int?
    let jobTitle: String?
    let school: String?
    let prompt1Question: String?
    let prompt1Answer: String?
    let prompt2Question: String?
    let prompt2Answer: String?
    let cityDisplay: String?
    let isVerified: Bool
    let distance: Int
    let primaryPhoto: String?
    /// Set when they liked one of your specific photos rather than your profile generally.
    let likedPhotoUrl: String?
    /// Set when they liked one of your specific prompts rather than your profile generally.
    let likedPromptQuestion: String?
    let likedPromptAnswer: String?
    let message: String?
    let likedAt: Date

    var heightDisplay: String? {
        guard let heightInches else { return nil }
        return "\(heightInches / 12)'\(heightInches % 12)\""
    }
}

struct MatchedUser: Codable {
    let id: String
}

// MARK: - Match Models

struct Match: Codable, Identifiable {
    let matchId: String
    let userId: String
    let age: Int
    let genderIdentity: GenderIdentity
    let cityDisplay: String?
    let isVerified: Bool
    let photo: String?
    let lastMessage: LastMessage?
    let matchedAt: Date
    
    var id: String { matchId }
}

struct LastMessage: Codable {
    let content: String?
    let senderId: String
    let createdAt: Date
}

// MARK: - Message Models

struct Message: Codable, Identifiable {
    let id: String
    let matchId: String
    let senderId: String
    let content: String?
    let imageUrl: String?
    let createdAt: Date
    let readAt: Date?
}

struct SendMessage: Codable {
    let content: String?
    let imageUrl: String?
}

// MARK: - Auth Models

struct SignupRequest: Codable {
    let email: String
    let phone: String
    // Absent for an Apple sign-up (appleIdentityToken set instead) — Apple's identity token is
    // the entire authentication for that account, there's no password to set. The *token* is
    // sent again here (not a raw appleUserId) so the backend re-verifies it and derives the
    // Apple user ID itself — never trust a client-supplied ID directly, anyone could claim any
    // value without proving they actually own that Apple account.
    let password: String?
    let appleIdentityToken: String?
    let dateOfBirth: String
    let genderIdentity: String
    let genderIdentityOther: String?
    let femAttestationAccepted: Bool
}

struct AppleAuthRequest: Codable {
    let identityToken: String
}

/// What POST /auth/apple can come back with — either a normal login (existing account,
/// tokens ready to use) or a signal that this Apple ID has no account yet, so the client should
/// fall through to the normal signup form (pre-filled with whatever email Apple provided, minus
/// the password step).
enum AppleSignInOutcome {
    case authenticated(AuthResponse)
    case needsSignup(identityToken: String, email: String?)
}

struct VerifyOTPRequest: Codable {
    let email: String
    let code: String
}

struct LoginRequest: Codable {
    let email: String
    let password: String
}

struct AuthResponse: Codable {
    let accessToken: String
    let refreshToken: String
    let user: UserInfo
}

struct UserInfo: Codable {
    let id: String
    let email: String
    let phone: String
    let genderIdentity: String
}

struct RefreshTokenRequest: Codable {
    let refreshToken: String
}

// MARK: - Report Models

enum ReportReason: String, Codable, CaseIterable {
    case harassment
    case fakeProfile = "fake_profile"
    case misrepresentingPresentation = "misrepresenting_presentation"
    case inappropriateContent = "inappropriate_content"
    case underageSuspicion = "underage_suspicion"
    case other
    
    var displayName: String {
        switch self {
        case .harassment: return "Harassment"
        case .fakeProfile: return "Fake Profile"
        case .misrepresentingPresentation: return "Misrepresenting Presentation"
        case .inappropriateContent: return "Inappropriate Content"
        case .underageSuspicion: return "Underage Suspicion"
        case .other: return "Other"
        }
    }
}

struct ReportRequest: Codable {
    let reportedId: String
    let reason: ReportReason
    let details: String?
}

// MARK: - Block Models

struct BlockRequest: Codable {
    let blockedId: String
}

// MARK: - API Response Models

struct APIResponse<T: Codable>: Codable {
    let message: String?
    let error: String?
    let data: T?
}

struct ErrorResponse: Codable {
    let error: String
    let code: String?
}
