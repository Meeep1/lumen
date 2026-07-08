import SwiftUI

/// "See what others see" — shows your own profile rendered through the exact same
/// `ProfileCardView` component the Discover tab uses (via `DiscoveryProfile(previewing:)` in
/// Models.swift), so this is guaranteed to match what a match actually sees rather than a
/// parallel look-alike that can drift out of sync.
///
/// Zero system chrome — no `NavigationStack`, no `.toolbar`, uses the same shared `LumenHeader`
/// every other screen does. Matching Discovery's card size still means matching the space its
/// own header leaves below it, which `LumenHeader`'s fixed 44pt height (same as Discovery's)
/// takes care of automatically.
struct ProfilePreviewView: View {
    let user: User

    var body: some View {
        ZStack {
            Color.lumenBackground
                .ignoresSafeArea()

            VStack(spacing: 0) {
                LumenHeader(title: "Your Profile", trailing: {
                    LumenBackButton(systemImage: "xmark")
                })

                // `.clipped()` matches what DiscoveryView's cardStack applies to every card, so
                // nothing the card draws can escape this container. It only guards *drawing*,
                // though — the "photo stretched edge-to-edge / age off-screen" bug was a layout
                // problem inside ProfileCardView itself (a `.fill` photo reporting an oversized
                // width), fixed there with the overlay pattern.
                GeometryReader { geo in
                    ProfileCardView(
                        profile: DiscoveryProfile(previewing: user),
                        isTopCard: false,
                        onSwipe: { _ in }
                    )
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
                }
            }
        }
    }
}

#Preview {
    ProfilePreviewView(user: User(
        id: "1", name: "Mia", email: nil, phone: nil, dateOfBirth: nil, age: 26,
        genderIdentity: .woman, genderIdentityOther: nil, bio: "Coffee snob, plant mom.",
        pronouns: "she/her", styleTags: ["cottagecore", "cozy"], heightInches: 65,
        jobTitle: "Barista", school: nil, prompt1Question: "A random fact I love is...",
        prompt1Answer: "Octopi have three hearts.", prompt2Question: nil, prompt2Answer: nil,
        prompt3Question: nil, prompt3Answer: nil,
        latitude: nil, longitude: nil, cityDisplay: "Portland, OR", isVerified: true,
        discoverable: true, notifyNewMatch: true, notifyNewMessage: true, notifyNewLike: true,
        photos: []
    ))
}
