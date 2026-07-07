import SwiftUI

struct DiscoveryView: View {
    @EnvironmentObject var authManager: AuthenticationManager
    @State private var profiles: [DiscoveryProfile] = []
    @State private var isLoading = false
    @State private var showingFilters = false
    @State private var currentIndex = 0
    @State private var matchedProfile: DiscoveryProfile?
    @State private var matchedMatchId: String?
    @State private var chatMatch: Match?
    @State private var showingMatchChat = false
    /// Only ever the single most recent swipe, and only set when it didn't match (the backend
    /// rejects undoing a match outright — see swipe.ts's DELETE /swipe/last — so there's no
    /// point letting the button look tappable when it would just come back as an error).
    @State private var canUndoLastSwipe = false
    @State private var undoErrorMessage: String?

    // Filters
    @State private var filters = DiscoveryFilters()

    var body: some View {
        NavigationStack {
            ZStack {
                Color.lumenBackground
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    LumenHeader(title: "Discover")

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
            .toolbar(.hidden, for: .navigationBar)
            .customAlert(
                isPresented: Binding(
                    get: { undoErrorMessage != nil },
                    set: { if !$0 { undoErrorMessage = nil } }
                ),
                title: "Couldn't Undo",
                message: undoErrorMessage ?? ""
            )
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
            .fullScreenCover(item: $matchedProfile) { profile in
                MatchCelebrationView(
                    photoURL: APIService.shared.imageURL(for: profile.primaryPhoto),
                    genderIdentity: profile.genderIdentity,
                    onSendMessage: {
                        if let matchedMatchId {
                            chatMatch = Match(
                                matchId: matchedMatchId,
                                userId: profile.id,
                                age: profile.age,
                                genderIdentity: profile.genderIdentity,
                                cityDisplay: profile.cityDisplay,
                                isVerified: profile.isVerified,
                                photo: profile.primaryPhoto,
                                isOnline: nil,
                                lastActiveAt: nil,
                                lastMessage: nil,
                                matchedAt: Date()
                            )
                            showingMatchChat = true
                        }
                        matchedProfile = nil
                    },
                    onDismiss: { matchedProfile = nil }
                )
            }
            .navigationDestination(isPresented: $showingMatchChat) {
                if let chatMatch {
                    ChatView(match: chatMatch)
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
                        .background(Theme.primaryGradient)
                        .foregroundColor(.white)
                        .clipShape(Circle())
                }
                .buttonStyle(LumenPressableStyle())
                .shadow(color: .pink.opacity(0.25), radius: 6, y: 3)

                if canUndoLastSwipe {
                    Button {
                        Task { await undoLastSwipe() }
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.subheadline.weight(.semibold))
                            .padding(10)
                            .background(Color.lumenSurface)
                            .foregroundColor(.primary)
                            .clipShape(Circle())
                            .overlay(Circle().stroke(Color.pink.opacity(0.15), lineWidth: 1))
                    }
                    .buttonStyle(LumenPressableStyle())
                    .transition(.scale.combined(with: .opacity))
                }

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
                .background(value != nil ? AnyShapeStyle(Theme.primaryGradient) : AnyShapeStyle(Color.lumenSurface))
                .foregroundColor(value != nil ? .white : .primary)
                .clipShape(Capsule())
                .overlay(
                    Capsule().stroke(Color.pink.opacity(value != nil ? 0 : 0.15), lineWidth: 1)
                )
        }
        .buttonStyle(LumenPressableStyle())
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
                    .background(Theme.primaryGradient)
                    .clipShape(Capsule())
            }
            .buttonStyle(LumenPressableStyle())
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
                        // Each card behind the top one animates into its new (offset, scale)
                        // position once the card above it swipes away, instead of snapping —
                        // reads as the stack settling rather than an abrupt jump.
                        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: currentIndex)
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    /// `reset` distinguishes a genuine fresh load (initial appearance, a filter change) from the
    /// background top-up triggered mid-swipe below as the stack runs low. Both used to always
    /// replace the whole `profiles` array and snap `currentIndex` back to 0 — harmless for a
    /// fresh load, but the top-up fired *during* `handleSwipe`, after `currentIndex` had already
    /// advanced past the card just swiped. Resetting it back to 0 there raced with the swipe
    /// still in flight: the just-swiped profile's array position no longer matched `currentIndex`,
    /// so undoing it either silently no-op'd (`currentIndex > 0` was suddenly false) or brought
    /// back the wrong card, and the full-array replacement could yank the entire visible stack
    /// out from under an in-progress gesture. Appending new profiles (deduped) and leaving
    /// `currentIndex` alone keeps every already-swiped position stable.
    private func loadProfiles(reset: Bool = true) async {
        if reset {
            isLoading = true
        }
        defer { if reset { isLoading = false } }

        do {
            let fetched = try await APIService.shared.getDiscoveryStack(filters: filters)
            if reset {
                profiles = fetched
                currentIndex = 0
            } else {
                let existingIds = Set(profiles.map(\.id))
                profiles.append(contentsOf: fetched.filter { !existingIds.contains($0.id) })
            }
        } catch {
            print("Failed to load profiles: \(error)")
        }
    }

    private func handleSwipe(on profile: DiscoveryProfile, direction: SwipeDirection) async {
        // Advance immediately, before the network call — the card's own fly-off animation
        // (see ProfileCardView.triggerSwipe) already completed by the time this runs, and
        // `isTopCard` (which gates whether the next card's drag gesture even responds) is driven
        // by `currentIndex`. Keeping that in lockstep with a real network round-trip meant a fast
        // swiper could tap/drag the new top card during that window and have it silently do
        // nothing — invisible on localhost, very noticeable once this started hitting the real
        // production server instead.
        withAnimation {
            currentIndex += 1
        }

        if currentIndex >= profiles.count - 5 {
            await loadProfiles(reset: false)
        }

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
                matchedMatchId = result.matchId
                // A plain .overlay here previously (to avoid a sheet-presentation dependency),
                // but that only ever covered up to wherever MainTabView's tab bar reserved space
                // began, leaving it visible underneath — and toggling that space away via a
                // TabBarVisibility flag needed an extra safeAreaInset layout pass to propagate,
                // which showed up as the celebration's own top/bottom edges visibly lagging a
                // moment behind the rest of it. A fullScreenCover is a real, separate modal
                // presentation — guaranteed genuinely full-screen from its very first frame,
                // completely independent of whatever the tab bar underneath is doing.
                matchedProfile = profile
                // First natural moment there's actually something worth notifying about —
                // see PushNotificationManager for why this isn't requested at launch instead.
                PushNotificationManager.shared.requestPermissionIfNeeded()
            }

            // Only a swipe that didn't match can be undone — see swipe.ts's DELETE /swipe/last.
            canUndoLastSwipe = !result.matched
        } catch {
            // The swipe never made it to the server, but the card is already gone locally (see
            // above) — rolling currentIndex back would yank a card back onto screen after the
            // user's visibly moved past it, which reads as worse/more confusing than just letting
            // it stand. Rare in practice (APIService already retries once on an expired token),
            // and a fresh loadProfiles() re-fetches the true server-side unswiped set regardless.
            print("Swipe error: \(error)")
        }
    }

    private func undoLastSwipe() async {
        guard currentIndex > 0 else { return }

        do {
            _ = try await APIService.shared.undoLastSwipe()
            withAnimation {
                currentIndex -= 1
            }
            // Deliberately not chained — this only ever undoes the single swipe the button
            // just appeared for. Rehiding it also means a mis-tap can't retry against a swipe
            // the server no longer has (already deleted).
            canUndoLastSwipe = false
        } catch {
            canUndoLastSwipe = false
            undoErrorMessage = error.localizedDescription
        }
    }

}

#Preview {
    DiscoveryView()
        .environmentObject(AuthenticationManager.shared)
}

/// The "It's a Match!" celebration screen — shared between DiscoveryView (matching while
/// swiping) and LikeResponseView (matching by liking someone back from Likes You), so both
/// paths to a match land on the exact same screen rather than two hand-maintained lookalikes.
struct MatchCelebrationView: View {
    let photoURL: URL?
    let genderIdentity: GenderIdentity
    let onSendMessage: () -> Void
    let onDismiss: () -> Void

    @State private var matchTextPop = false
    @State private var matchPhotoPop = false
    @State private var matchRingPulse = false

    var body: some View {
        ZStack {
            // A soft radial glow behind everything reads as more of an occasion than a flat
            // black scrim alone, and doubles as the surface the pulsing ring animates against.
            RadialGradient(
                colors: [Color.pink.opacity(0.35), Color.black.opacity(0.9)],
                center: .center,
                startRadius: 0,
                endRadius: 320
            )
            .ignoresSafeArea()
            .onTapGesture { onDismiss() }

            VStack(spacing: 22) {
                Text("It's a Match!")
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.primaryGradient)
                    .scaleEffect(matchTextPop ? 1 : 0.6)
                    .opacity(matchTextPop ? 1 : 0)

                ZStack {
                    Circle()
                        .stroke(Theme.primaryGradient, lineWidth: 3)
                        .frame(width: 180, height: 180)
                        .scaleEffect(matchRingPulse ? 1.15 : 0.9)
                        .opacity(matchRingPulse ? 0 : 0.8)

                    if let photoURL {
                        AsyncImage(url: photoURL) { image in
                            image.resizable().aspectRatio(contentMode: .fill)
                        } placeholder: {
                            Circle().fill(Color.white.opacity(0.2))
                        }
                        .frame(width: 160, height: 160)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(.white, lineWidth: 4))
                        .scaleEffect(matchPhotoPop ? 1 : 0.4)
                        .opacity(matchPhotoPop ? 1 : 0)
                    }
                }

                Text("You and \(genderIdentity.displayName.lowercased()) matched. Break the ice and send the first message.")
                    .foregroundColor(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)

                VStack(spacing: 12) {
                    Button {
                        onSendMessage()
                    } label: {
                        Label("Send a Message", systemImage: "paperplane.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(LumenPrimaryButtonStyle())

                    Button {
                        onDismiss()
                    } label: {
                        Text("Keep Swiping")
                            .foregroundColor(.white.opacity(0.85))
                    }
                    .buttonStyle(LumenPressableStyle())
                    .padding(.top, 2)
                }
                .padding(.horizontal, 40)
                .padding(.top, 12)
            }
        }
        .onAppear {
            matchTextPop = false
            matchPhotoPop = false
            matchRingPulse = false
            withAnimation(.spring(response: 0.45, dampingFraction: 0.6)) {
                matchPhotoPop = true
            }
            withAnimation(.spring(response: 0.45, dampingFraction: 0.65).delay(0.1)) {
                matchTextPop = true
            }
            // A single ripple reads as a celebratory flourish; looping it forever (the previous
            // `.repeatForever(autoreverses: false)` here) instead reads as a stuck/broken
            // animation the longer the screen stays open.
            withAnimation(.easeOut(duration: 1.4)) {
                matchRingPulse = true
            }
        }
    }
}
