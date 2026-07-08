import SwiftUI

/// Detail sheet for a single incoming like — shows what they liked (with their comment, if any)
/// and lets you like or pass back. Liking back always creates a match (they already liked you).
struct LikeResponseView: View {
    let like: LikeReceived
    let onResponded: () -> Void

    @Environment(\.dismiss) var dismiss
    @State private var isResponding = false
    @State private var errorMessage: String?
    @State private var matched = false
    @State private var matchedMatchId: String?
    @State private var chatMatch: Match?
    @State private var showingMatchChat = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
            LumenHeader(title: "", leading: {
                LumenBackButton(systemImage: "xmark")
            })
            ScrollView {
                VStack(spacing: 20) {
                    // Overlay pattern (see ProfileCardView): a `.fill` photo reports its
                    // overflowed size to layout, and a wide photo here would inflate the whole
                    // ScrollView's content width, shifting everything else off-center. Overlay
                    // content is excluded from layout entirely.
                    Color.clear
                        .frame(height: 360)
                        .overlay {
                            AsyncImage(url: APIService.shared.imageURL(for: like.primaryPhoto)) { image in
                                image.resizable().scaledToFill()
                            } placeholder: {
                                Rectangle()
                                    .fill(LinearGradient(
                                        colors: [.pink.opacity(0.3), .purple.opacity(0.3)],
                                        startPoint: .topLeading, endPoint: .bottomTrailing
                                    ))
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                        .padding(.horizontal)

                    if like.likedPhotoUrl != nil || like.likedPromptQuestion != nil || like.message != nil {
                        likeContextCard
                    }

                    HStack {
                        Text("\(like.age)")
                            .font(.system(.largeTitle, design: .rounded).bold())
                        if like.isVerified {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.title3)
                                .foregroundStyle(.blue.gradient)
                        }
                        Spacer()
                    }
                    .padding(.horizontal)

                    statPills

                    if like.jobTitle != nil || like.school != nil {
                        detailsCard
                    }

                    if let bio = like.bio, !bio.isEmpty {
                        Text(bio)
                            .font(.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                            .background(Color.lumenCard)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.medium))
                            .padding(.horizontal)
                    }

                    if !like.styleTags.isEmpty {
                        styleTagsCard
                    }

                    if let errorMessage {
                        Text(errorMessage).foregroundStyle(.red).font(.caption)
                    }
                }
                .padding(.bottom, 100)
            }
            .background(Color.lumenBackground)
            .safeAreaInset(edge: .bottom) {
                responseButtons
            }
            }
            .toolbar(.hidden, for: .navigationBar)
            // A plain `.overlay` here previously — but this whole view is itself presented as a
            // card-style `.sheet` from LikesYouView, which is inset from the true screen bounds
            // (a margin at the top, rounded/inset corners at the bottom). An overlay only fills
            // whatever container it's placed in, so `MatchCelebrationView`'s own
            // `.ignoresSafeArea()` was filling the *sheet's* bounds, not the actual screen —
            // exactly the gaps reported at the top and bottom corners. `.fullScreenCover` is a
            // real, separate full-screen modal, the same fix DiscoveryView's own celebration
            // needed for the same reason (see its own comment).
            .fullScreenCover(isPresented: $matched) {
                MatchCelebrationView(
                    photoURL: APIService.shared.imageURL(for: like.primaryPhoto),
                    name: like.name,
                    dismissLabel: "Not Now",
                    onSendMessage: {
                        if let matchedMatchId {
                            chatMatch = Match(
                                matchId: matchedMatchId,
                                userId: like.id,
                                name: like.name,
                                age: like.age,
                                genderIdentity: like.genderIdentity,
                                cityDisplay: like.cityDisplay,
                                isVerified: like.isVerified,
                                photo: like.primaryPhoto,
                                isOnline: nil,
                                lastActiveAt: nil,
                                lastMessage: nil,
                                matchedAt: Date()
                            )
                            matched = false
                            showingMatchChat = true
                        } else {
                            dismiss()
                        }
                    },
                    onDismiss: {
                        dismiss()
                    }
                )
            }
            .navigationDestination(isPresented: $showingMatchChat) {
                if let chatMatch {
                    ChatView(match: chatMatch)
                }
            }
        }
    }

    private var statPills: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                statPill(icon: "location.fill", text: "\(like.distance) mi")
                if let heightDisplay = like.heightDisplay {
                    statPill(icon: "ruler", text: heightDisplay)
                }
                if let pronouns = like.pronouns {
                    statPill(icon: "person.fill", text: pronouns)
                }
                if let city = like.cityDisplay, !city.isEmpty {
                    statPill(icon: "house.fill", text: city)
                }
            }
            .padding(.horizontal)
        }
    }

    private func statPill(icon: String, text: String) -> some View {
        Label(text, systemImage: icon)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.pink.opacity(0.12))
            .foregroundColor(.pink)
            .clipShape(Capsule())
    }

    private var detailsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let jobTitle = like.jobTitle, !jobTitle.isEmpty {
                Label(jobTitle, systemImage: "briefcase.fill")
                    .font(.subheadline)
            }
            if let school = like.school, !school.isEmpty {
                Label(school, systemImage: "graduationcap.fill")
                    .font(.subheadline)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.lumenCard)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.medium))
        .padding(.horizontal)
    }

    private var styleTagsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Style")
                .font(.headline)

            FlowLayout(spacing: 8) {
                ForEach(like.styleTags, id: \.self) { tag in
                    Text(tag)
                        .font(.caption)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.pink.opacity(0.2))
                        .foregroundColor(.pink)
                        .cornerRadius(16)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.lumenCard)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.medium))
        .padding(.horizontal)
    }

    private var likeContextCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let question = like.likedPromptQuestion, let answer = like.likedPromptAnswer {
                Text(question)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(answer)
                    .font(.title3.weight(.medium))
            } else if like.likedPhotoUrl != nil {
                Label("Liked this photo", systemImage: "photo.fill")
                    .font(.subheadline.weight(.semibold))
            }

            if let message = like.message, !message.isEmpty {
                Text("\u{201C}\(message)\u{201D}")
                    .font(.body.italic())
                    .padding(.top, like.likedPromptQuestion != nil || like.likedPhotoUrl != nil ? 4 : 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(
            LinearGradient(
                colors: [Color.pink.opacity(0.12), Color.purple.opacity(0.12)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        )
        .cornerRadius(16)
        .padding(.horizontal)
    }

    private var responseButtons: some View {
        VStack(spacing: 0) {
            Divider()

            HStack(spacing: 24) {
                Button {
                    Task { await respond(.pass) }
                } label: {
                    Image(systemName: "xmark")
                        .font(.title2.weight(.bold))
                        .foregroundColor(.red)
                        .frame(width: 56, height: 56)
                        .background(Color.lumenSurface, in: Circle())
                }

                Button {
                    Task { await respond(.like) }
                } label: {
                    Image(systemName: "heart.fill")
                        .font(.title2.weight(.bold))
                        .foregroundColor(.white)
                        .frame(width: 64, height: 64)
                        .background(Theme.primaryGradient, in: Circle())
                }
            }
            .buttonStyle(LumenPressableStyle())
            .disabled(isResponding)
            .padding()
        }
        .background(Color.lumenBackground)
    }

    private func respond(_ direction: SwipeDirection) async {
        isResponding = true
        errorMessage = nil
        defer { isResponding = false }

        do {
            let result = try await APIService.shared.swipe(action: SwipeAction(
                swipedId: like.id,
                direction: direction,
                likedPhotoId: nil,
                likedPromptNumber: nil,
                message: nil
            ))
            if result.matched {
                matchedMatchId = result.matchId
                matched = true
                // The like is already consumed server-side the moment this fires — refresh the
                // underlying Likes You list now rather than waiting for the celebration screen
                // to be dismissed, so it's not stale if the user navigates to chat instead.
                onResponded()
            } else {
                onResponded()
                dismiss()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

#Preview {
    LikeResponseView(like: LikeReceived(
        id: "preview", name: "Preview", age: 25, genderIdentity: .woman, genderIdentityOther: nil,
        bio: "Preview bio", pronouns: "she/her", styleTags: [], heightInches: nil,
        jobTitle: nil, school: nil, prompt1Question: nil, prompt1Answer: nil,
        prompt2Question: nil, prompt2Answer: nil, prompt3Question: nil, prompt3Answer: nil, cityDisplay: nil, isVerified: false,
        distance: 3, primaryPhoto: nil, likedPhotoUrl: nil, likedPromptQuestion: nil,
        likedPromptAnswer: nil, message: nil, likedAt: Date()
    ), onResponded: {})
}
