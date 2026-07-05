import XCTest
@testable import lumen

/// Exercises APIService's actual decoder configuration (not a reimplementation of it) against
/// real backend response shapes, so a change to either side (Swift model or backend response)
/// that breaks decoding fails a test instead of only being caught by manually running the app.
final class APIServiceDecodingTests: XCTestCase {
    private var decoder: JSONDecoder { APIService.shared.decoder }

    // MARK: - Date handling

    /// The backend's Prisma/Postgres timestamps come back with fractional seconds
    /// (e.g. "2026-07-05T06:16:07.123Z") — this is the common case.
    func testDecodesDateWithFractionalSeconds() throws {
        let json = #"{"id":"m1","matchId":"match1","senderId":"u1","content":"hi","imageUrl":null,"createdAt":"2026-07-05T06:16:07.123Z","readAt":null}"#
        let message = try decoder.decode(Message.self, from: Data(json.utf8))

        let expected = ISO8601DateFormatter()
        expected.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        XCTAssertEqual(message.createdAt, expected.date(from: "2026-07-05T06:16:07.123Z"))
    }

    /// The decoder has an explicit fallback for a timestamp with no fractional component at
    /// all — worth its own test since it's a real second branch in the decode logic, not just
    /// theoretical.
    func testDecodesDateWithoutFractionalSeconds() throws {
        let json = #"{"id":"m1","matchId":"match1","senderId":"u1","content":"hi","imageUrl":null,"createdAt":"2026-07-05T06:16:07Z","readAt":null}"#
        let message = try decoder.decode(Message.self, from: Data(json.utf8))

        let expected = ISO8601DateFormatter()
        expected.formatOptions = [.withInternetDateTime]
        XCTAssertEqual(message.createdAt, expected.date(from: "2026-07-05T06:16:07Z"))
    }

    func testMalformedDateThrowsRatherThanSilentlyDecoding() {
        let json = #"{"id":"m1","matchId":"match1","senderId":"u1","content":"hi","imageUrl":null,"createdAt":"not-a-date","readAt":null}"#
        XCTAssertThrowsError(try decoder.decode(Message.self, from: Data(json.utf8)))
    }

    // MARK: - Message

    func testDecodesMessageWithImageAndReadReceipt() throws {
        let json = #"""
        {"id":"m2","matchId":"match1","senderId":"u2","content":null,"imageUrl":"/uploads/photos/u2/x.jpg",
         "createdAt":"2026-07-05T06:16:07.000Z","readAt":"2026-07-05T06:20:00.000Z"}
        """#
        let message = try decoder.decode(Message.self, from: Data(json.utf8))
        XCTAssertNil(message.content)
        XCTAssertEqual(message.imageUrl, "/uploads/photos/u2/x.jpg")
        XCTAssertNotNil(message.readAt)
    }

    // MARK: - Photo (matches routes/profile.ts's GET /me shape, incl. appeal fields)

    func testDecodesPendingPhotoWithNoAppealYet() throws {
        let json = #"""
        {"id":"p1","url":"/uploads/photos/u1/a.jpg","order":0,"moderationStatus":"pending",
         "appealStatus":"none","appealMessage":null,"canAppeal":false}
        """#
        let photo = try decoder.decode(Photo.self, from: Data(json.utf8))
        XCTAssertEqual(photo.moderationStatus, "pending")
        XCTAssertEqual(photo.canAppeal, false)
    }

    func testDecodesRejectedPhotoEligibleForAppeal() throws {
        let json = #"""
        {"id":"p2","url":"/uploads/photos/u1/b.jpg","order":1,"moderationStatus":"rejected",
         "appealStatus":"none","appealMessage":null,"canAppeal":true}
        """#
        let photo = try decoder.decode(Photo.self, from: Data(json.utf8))
        XCTAssertEqual(photo.moderationStatus, "rejected")
        XCTAssertEqual(photo.canAppeal, true)
    }

    // MARK: - User (matches routes/profile.ts's GET /me shape)

    func testDecodesFullUserProfile() throws {
        let json = #"""
        {"id":"u1","email":"mia+seed@lumen.test","phone":"+15551234567",
         "dateOfBirth":"2000-01-01T00:00:00.000Z","age":26,"genderIdentity":"woman",
         "genderIdentityOther":null,"bio":"hi there","pronouns":"she/her",
         "styleTags":["cottagecore","gamer girl"],"heightInches":65,"jobTitle":"Designer",
         "school":null,"prompt1Question":"My ideal Sunday...","prompt1Answer":"coffee and a book",
         "prompt2Question":null,"prompt2Answer":null,"latitude":40.7,"longitude":-74.0,
         "cityDisplay":"New York","isVerified":true,"discoverable":true,"notifyNewMatch":true,
         "notifyNewMessage":true,"notifyNewLike":false,
         "photos":[{"id":"p1","url":"/uploads/photos/u1/a.jpg","order":0,"moderationStatus":"approved",
                    "appealStatus":"none","appealMessage":null,"canAppeal":false}]}
        """#
        let user = try decoder.decode(User.self, from: Data(json.utf8))

        XCTAssertEqual(user.genderIdentity, .woman)
        XCTAssertEqual(user.styleTags, ["cottagecore", "gamer girl"])
        XCTAssertEqual(user.heightDisplay, "5'5\"")
        XCTAssertEqual(user.prompts.count, 1)
        XCTAssertFalse(user.needsOnboarding)
        XCTAssertEqual(user.photos.count, 1)
    }

    /// A user with no photos and no location hasn't finished onboarding — this drives whether
    /// the app routes into onboarding or straight to Discovery, so it's worth locking down.
    func testUserMissingLocationOrPhotosNeedsOnboarding() throws {
        let json = #"""
        {"id":"u2","email":"new@lumen.test","phone":"+15551234568",
         "dateOfBirth":"2000-01-01T00:00:00.000Z","age":26,"genderIdentity":"nonbinary_feminine",
         "genderIdentityOther":null,"bio":null,"pronouns":null,"styleTags":[],"heightInches":null,
         "jobTitle":null,"school":null,"prompt1Question":null,"prompt1Answer":null,
         "prompt2Question":null,"prompt2Answer":null,"latitude":null,"longitude":null,
         "cityDisplay":null,"isVerified":false,"discoverable":true,"notifyNewMatch":true,
         "notifyNewMessage":true,"notifyNewLike":true,"photos":[]}
        """#
        let user = try decoder.decode(User.self, from: Data(json.utf8))
        XCTAssertEqual(user.genderIdentity, .nonbinaryFeminine)
        XCTAssertTrue(user.needsOnboarding)
    }

    // MARK: - Match

    func testDecodesMatchWithLastMessage() throws {
        let json = #"""
        {"matchId":"match1","userId":"u2","age":27,"genderIdentity":"femboy","cityDisplay":"Austin",
         "isVerified":false,"photo":"/uploads/photos/u2/a.jpg",
         "lastMessage":{"content":"hey!","createdAt":"2026-07-05T06:00:00.000Z","senderId":"u2"},
         "matchedAt":"2026-07-04T12:00:00.000Z"}
        """#
        let match = try decoder.decode(Match.self, from: Data(json.utf8))
        XCTAssertEqual(match.id, "match1")
        XCTAssertEqual(match.genderIdentity, .femboy)
        XCTAssertNotNil(match.lastMessage)
    }
}
