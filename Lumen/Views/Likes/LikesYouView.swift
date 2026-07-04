import SwiftUI

/// "Who liked you" — free for everyone, no paywall (app_spec.md Section 3.3). Shows a grid of
/// people who've liked you, what specifically they liked (a photo, a prompt, or just your
/// profile generally), and any comment they left — tapping one lets you like or pass back.
struct LikesYouView: View {
    @State private var likes: [LikeReceived] = []
    @State private var isLoading = false
    @State private var selectedLike: LikeReceived?

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        NavigationStack {
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
            .navigationTitle("Likes You")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                await load()
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
            AsyncImage(url: APIService.shared.imageURL(for: like.likedPhotoUrl ?? like.primaryPhoto)) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Rectangle()
                    .fill(LinearGradient(
                        colors: [.pink.opacity(0.3), .purple.opacity(0.3)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ))
            }
            .aspectRatio(0.75, contentMode: .fill)
            .clipped()

            LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .center, endPoint: .bottom)

            VStack(alignment: .leading, spacing: 2) {
                if like.likedPromptQuestion != nil {
                    Label("Liked your prompt", systemImage: "quote.bubble.fill")
                        .font(.caption2.weight(.semibold))
                } else if like.likedPhotoUrl != nil {
                    Label("Liked your photo", systemImage: "photo.fill")
                        .font(.caption2.weight(.semibold))
                }
                Text("\(like.age)")
                    .font(.headline)
            }
            .foregroundColor(.white)
            .padding(10)
        }
        .aspectRatio(0.75, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

#Preview {
    LikesYouView()
}
