import SwiftUI

private struct ProfileSheetTarget: Identifiable { let id: String }

struct MatchListView: View {
    @EnvironmentObject var authManager: AuthenticationManager
    @State private var matches: [Match] = []
    @State private var isLoading = false
    @State private var profileTarget: ProfileSheetTarget?

    var body: some View {
        NavigationStack {
            ZStack {
                // Color needs to sit behind everything and fill the screen itself — a
                // `.background()` on the Group below only covers whatever size that Group's
                // content happens to be, which for the loading spinner / empty state is just
                // their intrinsic size, leaving the rest of the screen showing the default
                // system background as a visibly different-colored box around them.
                Color.lumenBackground
                    .ignoresSafeArea()

                Group {
                    if isLoading {
                        ProgressView()
                    } else if matches.isEmpty {
                        emptyState
                    } else {
                        matchList
                    }
                }
            }
            .navigationTitle("Matches")
            .task {
                await loadMatches()
            }
            .refreshable {
                await loadMatches()
            }
            .sheet(item: $profileTarget) { target in
                MatchProfileView(userId: target.id)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "heart.slash")
                .resizable()
                .frame(width: 60, height: 60)
                .foregroundStyle(.secondary)

            Text("No Matches Yet")
                .font(.title2.bold())

            Text("Start swiping to find your matches!")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }

    // "Your turn" = they messaged last and you haven't replied. "Their turn" = you messaged
    // last. "New" = matched but nobody has said anything yet. Derived from lastMessage.senderId
    // rather than a stored field, since that's all the backend already gives us.
    private var newMatches: [Match] { matches.filter { $0.lastMessage == nil } }
    private var yourTurn: [Match] {
        matches.filter { $0.lastMessage != nil && $0.lastMessage?.senderId != authManager.currentUser?.id }
    }
    private var theirTurn: [Match] {
        matches.filter { $0.lastMessage != nil && $0.lastMessage?.senderId == authManager.currentUser?.id }
    }

    private var matchList: some View {
        List {
            matchSection(title: "New Matches", items: newMatches)
            matchSection(title: "Your Turn", items: yourTurn)
            matchSection(title: "Their Turn", items: theirTurn)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private func matchSection(title: String, items: [Match]) -> some View {
        if !items.isEmpty {
            Section {
                ForEach(items) { match in
                    NavigationLink(destination: ChatView(match: match)) {
                        MatchRowView(match: match, onTapAvatar: { profileTarget = ProfileSheetTarget(id: match.userId) })
                    }
                    .listRowBackground(Color.lumenBackground)
                }
            } header: {
                Text("\(title) (\(items.count))")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func loadMatches() async {
        isLoading = true
        defer { isLoading = false }

        do {
            matches = try await APIService.shared.getMatches()
        } catch {
            print("Failed to load matches: \(error)")
        }
    }
}

struct MatchRowView: View {
    let match: Match
    let onTapAvatar: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onTapAvatar) {
                avatarImage
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("\(match.age)")
                        .font(.headline)

                    if match.isVerified {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.caption)
                            .foregroundColor(.blue)
                    }
                }

                if let lastMessage = match.lastMessage {
                    Text(lastMessage.content ?? "Photo")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text("Say hi 👋")
                        .font(.subheadline)
                        .foregroundStyle(.pink)
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 8)
    }

    private var avatarImage: some View {
        Group {
            if let photoUrl = APIService.shared.imageURL(for: match.photo) {
                AsyncImage(url: photoUrl) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    Rectangle()
                        .fill(Color(uiColor: .systemGray5))
                        .overlay {
                            ProgressView()
                        }
                }
            } else {
                LinearGradient(
                    colors: [.pink.opacity(0.3), .purple.opacity(0.3)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .overlay {
                    Image(systemName: "person.fill")
                        .foregroundColor(.white.opacity(0.7))
                }
            }
        }
        .frame(width: 60, height: 60)
        .clipShape(Circle())
    }
}

#Preview {
    MatchListView()
        .environmentObject(AuthenticationManager.shared)
}
