import Foundation
import Combine

/// The two servers a Debug build can talk to. Release builds never see this type at all — see
/// BackendEnvironmentStore below.
enum BackendEnvironment: String, CaseIterable, Identifiable {
    case local
    case production

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .local: return "Local"
        case .production: return "Production (lumenfem.app)"
        }
    }

    var baseURL: String {
        switch self {
        case .local: return "http://192.168.68.59:3000"
        case .production: return "https://lumenfem.app"
        }
    }

    var socketURL: String {
        switch self {
        case .local: return "ws://192.168.68.59:3000/ws"
        case .production: return "wss://lumenfem.app/ws"
        }
    }
}

#if DEBUG
/// Debug-only runtime override, flipped from a hidden gesture on the login screen (see
/// AuthenticationView) so you can switch between fast local iteration and testing against the
/// real deployed server without rebuilding. Persisted across launches via UserDefaults. This
/// entire type doesn't exist in Release builds — TestFlight/App Store archives always hit
/// production with no toggle and no debug surface for reviewers or real users to find.
final class BackendEnvironmentStore: ObservableObject {
    static let shared = BackendEnvironmentStore()

    private static let key = "debug.backendEnvironment"

    @Published var current: BackendEnvironment {
        didSet {
            UserDefaults.standard.set(current.rawValue, forKey: Self.key)
        }
    }

    private init() {
        if let raw = UserDefaults.standard.string(forKey: Self.key),
           let saved = BackendEnvironment(rawValue: raw) {
            current = saved
        } else {
            // Defaults to production, not local — the server is cheap to iterate on directly
            // (SSH access, a two-command deploy), so "just build and run" should work without
            // also needing `npm run dev` running on this Mac. Switch to Local with the same
            // 5-tap gesture when you specifically want to test against uncommitted local changes.
            current = .production
        }
    }
}
#endif
