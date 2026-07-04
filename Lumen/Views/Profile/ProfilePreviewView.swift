import SwiftUI

/// "See what others see" — renders your own profile through the exact same card discovery
/// swipes on (DiscoveryProfile(previewing:) in Models.swift), so what you preview here is
/// guaranteed to match what a match actually sees, not a parallel look-alike that can drift.
struct ProfilePreviewView: View {
    let user: User
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color.lumenBackground
                    .ignoresSafeArea()

                ProfileCardView(
                    profile: DiscoveryProfile(previewing: user),
                    isTopCard: false,
                    onSwipe: { _ in }
                )
                .padding()
            }
            .navigationTitle("Your Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

#Preview {
    ProfilePreviewView(user: User(
        id: "1", email: nil, phone: nil, dateOfBirth: nil, age: 26,
        genderIdentity: .woman, genderIdentityOther: nil, bio: "Coffee snob, plant mom.",
        pronouns: "she/her", styleTags: ["cottagecore", "cozy"], heightInches: 65,
        jobTitle: "Barista", school: nil, prompt1Question: "A random fact I love is...",
        prompt1Answer: "Octopi have three hearts.", prompt2Question: nil, prompt2Answer: nil,
        latitude: nil, longitude: nil, cityDisplay: "Portland, OR", isVerified: true,
        discoverable: true, photos: []
    ))
}
