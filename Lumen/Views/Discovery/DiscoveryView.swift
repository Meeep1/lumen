import SwiftUI

struct DiscoveryView: View {
    @EnvironmentObject var authManager: AuthenticationManager
    @State private var profiles: [DiscoveryProfile] = []
    @State private var isLoading = false
    @State private var showingFilters = false
    @State private var currentIndex = 0
    @State private var matchedProfile: DiscoveryProfile?

    // Filters
    @State private var filters = DiscoveryFilters()

    var body: some View {
        NavigationStack {
            ZStack {
                Color.lumenBackground
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    filterPills

                    if isLoading {
                        Spacer()
                        ProgressView("Finding matches...")
                        Spacer()
                    } else if profiles.isEmpty {
                        Spacer()
                        emptyState
                        Spacer()
                    } else {
                        cardStack
                    }
                }
            }
            .navigationTitle("Discover")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showingFilters) {
                FilterSheet(filters: $filters) {
                    Task {
                        await loadProfiles()
                    }
                }
            }
            .task {
                await loadProfiles()
            }
            .overlay {
                if let matchedProfile {
                    matchCelebration(profile: matchedProfile)
                }
            }
        }
    }

    private var filterPills: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button {
                    showingFilters = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.subheadline.weight(.semibold))
                        .padding(10)
                        .background(Color.pink.gradient)
                        .foregroundColor(.white)
                        .clipShape(Circle())
                }
                .shadow(color: .pink.opacity(0.25), radius: 6, y: 3)

                filterPill(title: "Age", value: filters.minAge != nil || filters.maxAge != nil
                    ? "\(filters.minAge ?? 18)-\(filters.maxAge ?? 100)" : nil)
                filterPill(title: "Distance", value: filters.maxDistance.map { "\($0) mi" })
                filterPill(title: "Height", value: (filters.minHeightInches != nil || filters.maxHeightInches != nil) ? "Custom" : nil)
                filterPill(title: "Verified", value: filters.verifiedOnly == true ? "On" : nil)
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
        }
    }

    private func filterPill(title: String, value: String?) -> some View {
        Button {
            showingFilters = true
        } label: {
            Text(value.map { "\(title): \($0)" } ?? title)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(value != nil ? AnyShapeStyle(Color.pink.gradient) : AnyShapeStyle(Color(uiColor: .secondarySystemBackground)))
                .foregroundColor(value != nil ? .white : .primary)
                .clipShape(Capsule())
                .overlay(
                    Capsule().stroke(Color.pink.opacity(value != nil ? 0 : 0.15), lineWidth: 1)
                )
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "sparkles")
                .resizable()
                .frame(width: 60, height: 60)
                .foregroundStyle(.pink.gradient)

            Text("No More Profiles")
                .font(.title2.bold())

            Text("Check back soon or adjust your filters")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button {
                Task { await loadProfiles() }
            } label: {
                Text("Refresh")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(Color.pink.gradient)
                    .clipShape(Capsule())
            }
            .padding(.top, 8)
        }
        .padding()
    }

    private var cardStack: some View {
        // Cards are pinned to exactly the space available here (and clipped to it), so an
        // over-tall card can never bleed upward and cover the filter pills above — which is
        // what happened when the card sized itself to its own content.
        GeometryReader { geo in
            ZStack {
                ForEach(Array(profiles.enumerated()), id: \.element.id) { index, profile in
                    if index >= currentIndex && index < currentIndex + 3 {
                        ProfileCardView(profile: profile, isTopCard: index == currentIndex) { direction in
                            await handleSwipe(on: profile, direction: direction)
                        }
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                        .offset(y: CGFloat(index - currentIndex) * 10)
                        .scaleEffect(1.0 - CGFloat(index - currentIndex) * 0.05)
                        .zIndex(Double(profiles.count - index))
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private func loadProfiles() async {
        isLoading = true
        defer { isLoading = false }

        do {
            profiles = try await APIService.shared.getDiscoveryStack(filters: filters)
            currentIndex = 0
        } catch {
            print("Failed to load profiles: \(error)")
        }
    }

    private func handleSwipe(on profile: DiscoveryProfile, direction: SwipeDirection) async {
        do {
            let result = try await APIService.shared.swipe(
                action: SwipeAction(
                    swipedId: profile.id,
                    direction: direction,
                    likedPhotoId: nil,
                    likedPromptNumber: nil,
                    message: nil
                )
            )

            if result.matched {
                withAnimation {
                    matchedProfile = profile
                }
            }

            // Move to next profile
            withAnimation {
                currentIndex += 1
            }

            // Load more profiles if running low
            if currentIndex >= profiles.count - 5 {
                await loadProfiles()
            }
        } catch {
            print("Swipe error: \(error)")
        }
    }

    private func matchCelebration(profile: DiscoveryProfile) -> some View {
        ZStack {
            Color.black.opacity(0.75)
                .ignoresSafeArea()
                .onTapGesture { withAnimation { matchedProfile = nil } }

            VStack(spacing: 20) {
                Text("It's a Match!")
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .foregroundColor(.white)

                if let photoUrl = APIService.shared.imageURL(for: profile.primaryPhoto) {
                    AsyncImage(url: photoUrl) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Circle().fill(Color.white.opacity(0.2))
                    }
                    .frame(width: 160, height: 160)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(.white, lineWidth: 4))
                }

                Text("You and \(profile.genderIdentity.displayName.lowercased()) matched. Say hi from the Matches tab!")
                    .foregroundColor(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)

                Button {
                    withAnimation { matchedProfile = nil }
                } label: {
                    Text("Keep Swiping")
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .background(Color.pink.gradient)
                        .cornerRadius(16)
                }
                .padding(.horizontal, 40)
                .padding(.top, 12)
            }
        }
        .transition(.opacity.combined(with: .scale(scale: 0.9)))
    }
}

#Preview {
    DiscoveryView()
        .environmentObject(AuthenticationManager.shared)
}
