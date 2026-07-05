import XCTest
@testable import lumen

/// Integration-style, not pure unit tests — `AuthenticationManager` is a singleton hard-wired to
/// the real `APIService`/`KeychainManager`/`SocketManager` with no injected seams, and refactoring
/// that for mockability is a bigger, riskier change than adding tests justifies on its own. These
/// exercise the real state transitions (isAuthenticated/currentUser/errorMessage) against a real
/// running local dev backend instead, using one of `prisma/seed.ts`'s seeded accounts (password
/// "TestPass123!", already emailVerified — no OTP round-trip needed to log in with it).
///
/// **Requires the local dev backend running** (`npm run dev` in backend/) with seed data loaded
/// (`npm run seed`) — these will fail with a network error, not a meaningful assertion failure,
/// if it isn't. Forces `BackendEnvironmentStore` to `.local` in setUp regardless of whatever the
/// simulator's UserDefaults already has saved (e.g. from manually testing against production via
/// the debug environment picker), so a test run can never accidentally hit production.
@MainActor
final class AuthenticationManagerTests: XCTestCase {
    private let seedEmail = "mia+seed@lumen.test"
    private let seedPassword = "TestPass123!"

    override func setUp() async throws {
        try await super.setUp()
        BackendEnvironmentStore.shared.current = .local
        await AuthenticationManager.shared.logout()
    }

    override func tearDown() async throws {
        await AuthenticationManager.shared.logout()
        try await super.tearDown()
    }

    func testLoginWithValidCredentialsSetsAuthenticatedState() async {
        let manager = AuthenticationManager.shared
        let result = await manager.login(email: seedEmail, password: seedPassword)

        switch result {
        case .success:
            break
        case .failure(let error):
            XCTFail("Expected login to succeed against the local seed account, got \(error)")
        }

        XCTAssertTrue(manager.isAuthenticated)
        XCTAssertNotNil(manager.currentUser)
        XCTAssertNil(manager.errorMessage)
    }

    func testLoginWithWrongPasswordLeavesUnauthenticated() async {
        let manager = AuthenticationManager.shared
        let result = await manager.login(email: seedEmail, password: "definitely-the-wrong-password")

        if case .success = result {
            XCTFail("Expected login with a wrong password to fail")
        }

        XCTAssertFalse(manager.isAuthenticated)
        XCTAssertNil(manager.currentUser)
        XCTAssertNotNil(manager.errorMessage)
    }

    func testLoginWithUnknownEmailFails() async {
        let manager = AuthenticationManager.shared
        let result = await manager.login(email: "definitely-not-a-real-account@lumen.test", password: "whatever123")

        if case .success = result {
            XCTFail("Expected login with an unknown email to fail")
        }
        XCTAssertFalse(manager.isAuthenticated)
    }

    func testLogoutClearsAuthenticatedState() async {
        let manager = AuthenticationManager.shared
        _ = await manager.login(email: seedEmail, password: seedPassword)
        XCTAssertTrue(manager.isAuthenticated, "precondition: login should have succeeded")

        await manager.logout()

        XCTAssertFalse(manager.isAuthenticated)
        XCTAssertNil(manager.currentUser)
    }

    /// `loadCurrentUser()` is also the recovery path for a stale/expired stored token (not just
    /// something called right after a fresh login) — with no token in the Keychain at all, the
    /// backend rejects the unauthenticated profile request and this should land back in a clean
    /// logged-out state rather than getting stuck.
    func testLoadCurrentUserWithNoStoredTokenStaysLoggedOut() async {
        let manager = AuthenticationManager.shared
        KeychainManager.shared.clearAll()

        await manager.loadCurrentUser()

        XCTAssertFalse(manager.isAuthenticated)
        XCTAssertNil(manager.currentUser)
    }
}
