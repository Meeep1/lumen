import SwiftUI

/// "Who liked you" — free for everyone, no paywall (app_spec.md Section 3.3). Shows a grid of
/// people who've liked you, what specifically they liked (a photo, a prompt, or just your
/// profile generally), and any comment they left — tapping one lets you like or pass back.
struct LikesYouView: View {
    /// See MatchListView's identical property for why this exists — MainTabView keeps this
    /// tab mounted after its first visit (just hidden via opacity), so `.task` alone would
    /// only ever load once per app session, never again just from switching back to this tab.
    var isActive: Bool = true
    @State private var likes: [LikeReceived] = []
    @State private var isLoading = false
    @State private var selectedLike: LikeReceived?

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                LumenHeader(title: "Likes You")

                ZStack {
                    // Same reasoning as MatchListView: fill the screen with the color directly,
                    // rather than backgrounding the Group (which only covers its content's
                    // intrinsic size and left the loading/empty states looking like a mismatched
                    // box against the default system background).
                    Color.lumenBackground
                        .ignoresSafeArea()

                    Group {
                        if isLoading {
                            ProgressView()
                        } else if likes.isEmpty {
                            emptyState
                        } else {
                            ScrollView {
                                LazyVGrid(columns: columns, spacing: 12) {
                                    ForEach(likes) { like in
                                        LikeTile(like: like)
                                            .onTapGesture { selectedLike = like }
                                    }
                                }
                                .padding()
                            }
                        }
                    }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .task {
                await load()
            }
            .onChange(of: isActive) { _, active in
                if active { Task { await load() } }
            }
            .refreshable {
                await load()
            }
            .sheet(item: $selectedLike) { like in
                LikeResponseView(like: like, onResponded: {
                    likes.removeAll { $0.id == like.id }
                })
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "heart.text.square")
                .resizable()
                .frame(width: 60, height: 60)
                .foregroundStyle(.pink.gradient)

            Text("No Likes Yet")
                .font(.title2.bold())

            Text("Once someone likes your profile, they'll show up here.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .padding()
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }

        do {
            likes = try await APIService.shared.getLikedMeProfiles()
        } catch {
            print("Failed to load likes: \(error)")
        }
    }
}

private struct LikeTile: View {
    let like: LikeReceived

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // Overlay pattern (see ProfileCardView): keeps a `.fill` photo's overflowed size
            // out of layout so a wide photo can't inflate this tile beyond its grid cell.
            Color.clear
                .overlay {
                    AsyncImage(url: APIService.shared.imageURL(for: like.likedPhotoUrl ?? like.primaryPhoto)) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Rectangle()
                            .fill(LinearGradient(
                                colors: [.pink.opacity(0.3), .purple.opacity(0.3)],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            ))
                    }
                }

            LinearGradient(colors: [.clear, .clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom)

            Image(systemName: "heart.fill")
                .font(.caption.weight(.semibold))
                .foregroundColor(.white)
                .padding(7)
                .background(Theme.primaryGradient, in: Circle())
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)

            VStack(alignment: .leading, spacing: 3) {
                Label(likeContextLabel, systemImage: likeContextIcon)
                    .font(.caption2.weight(.semibold))
                Text("\(like.age)")
                    .font(.system(.title3, design: .rounded).bold())
            }
            .foregroundColor(.white)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .aspectRatio(0.75, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var likeContextLabel: String {
        if like.likedPromptQuestion != nil { return "Liked your prompt" }
        if like.likedPhotoUrl != nil { return "Liked your photo" }
        return "Liked your profile"
    }

    private var likeContextIcon: String {
        if like.likedPromptQuestion != nil { return "quote.bubble.fill" }
        if like.likedPhotoUrl != nil { return "photo.fill" }
        return "heart.fill"
    }
}

#Preview {
    LikesYouView()
}
