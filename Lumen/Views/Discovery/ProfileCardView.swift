import SwiftUI

struct ProfileCardView: View {
    let profile: DiscoveryProfile
    var isTopCard: Bool = true
    let onSwipe: (SwipeDirection) async -> Void

    @State private var offset = CGSize.zero
    @State private var rotation: Double = 0
    /// True once a drag has committed to being a horizontal swipe (vs. a vertical scroll) —
    /// decided early in the gesture and held for its duration so a drag can't flip categories
    /// partway through.
    @State private var isHorizontalDrag = false
    /// Fires the "committed to swipe" haptic at most once per drag — without this it'd re-fire
    /// on every frame the drag spends past the threshold.
    @State private var hasTriggeredThresholdHaptic = false

    private let swipeThreshold: CGFloat = 100
    private let photoHeight: CGFloat = 420
    /// One consistent spring for every swipe-related motion (snap-back and fly-off alike) —
    /// mixing an implicit default animation with an explicit `.spring()` made the two feel like
    /// different speeds depending on which path triggered, which read as "snappy"/inconsistent.
    private let swipeAnimation = Animation.spring(response: 0.38, dampingFraction: 0.82)

    var body: some View {
        ZStack(alignment: .topLeading) {
            // A visibly different, slightly darker tone than the white cards that float on top
            // of it in infoSection, matching Hinge's "distinct rounded cards with gaps between
            // them" look instead of one continuous white surface.
            RoundedRectangle(cornerRadius: 24)
                .fill(Color.lumenSurface)
                .shadow(color: .black.opacity(0.16), radius: 24, y: 10)

            // Everything — every photo and the info below — lives in one scroll region, Hinge-
            // style, so scrolling down reveals more photos too rather than being stuck behind a
            // fixed header.
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(Array(profile.photos.enumerated()), id: \.element.id) { index, photo in
                        // The photo lives in an .overlay of a fixed-size base rather than being
                        // framed directly: `.fill` makes an image *report* its overflowed size to
                        // layout, and in this vertical ScrollView a wide (landscape) photo's
                        // reported width inflated the whole content column — the column re-centers,
                        // pushing every leading-aligned sibling (the age row) off-screen left while
                        // the photo spans past the card's rounded corners. Overlay content never
                        // participates in layout, so no photo aspect ratio can distort the card.
                        Color.clear
                            .frame(height: photoHeight)
                            .overlay {
                                AsyncImage(url: APIService.shared.imageURL(for: photo.url)) { image in
                                    image.resizable().scaledToFill()
                                } placeholder: {
                                    Rectangle()
                                        .fill(Color.lumenSurfaceStrong)
                                        .overlay { ProgressView() }
                                }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                            .padding(.horizontal, 16)
                            .padding(.top, index == 0 ? 16 : 0)

                        // First photo carries the name/basic-info row right under it, like a
                        // normal profile; the rest are just gallery images further down.
                        if index == 0 {
                            infoSection
                        }
                    }

                    if profile.photos.isEmpty {
                        Rectangle()
                            .fill(LinearGradient(
                                colors: [.pink.opacity(0.3), .purple.opacity(0.3)],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            ))
                            .frame(height: photoHeight)
                            .overlay {
                                Image(systemName: "person.fill")
                                    .resizable()
                                    .frame(width: 80, height: 80)
                                    .foregroundColor(.white.opacity(0.5))
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                            .padding(.horizontal, 16)
                            .padding(.top, 16)
                        infoSection
                    }
                }
                .padding(.bottom, 16)
            }
            .scrollDisabled(isHorizontalDrag)
            .clipShape(RoundedRectangle(cornerRadius: 24))

            if offset.width > 20 {
                likeIndicator.opacity(Double(offset.width / swipeThreshold))
            } else if offset.width < -20 {
                passIndicator.opacity(Double(-offset.width / swipeThreshold))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .offset(offset)
        .rotationEffect(.degrees(rotation))
        .simultaneousGesture(isTopCard ? cardDragGesture : nil)
        // triggerSwipe flies this card off-screen but never resets `offset` back — normally
        // moot, since a swiped card's index falls outside cardStack's visible range and the
        // whole card is removed. But an Undo brings that same index back into range, and
        // because this view sits inside a plain `if` in a ForEach (not a `.removed` transition
        // that fully re-initializes state), it can come back still holding its stale
        // fly-off offset — rendering (and hit-testing) off-frame instead of centered, which
        // looked like the card never returned and the stack stopped responding to swipes.
        // Resetting whenever this card (re)becomes the top card covers both the undo case and
        // the ordinary one (already zero there, so it's a no-op).
        .onChange(of: isTopCard) { _, isNowTop in
            if isNowTop {
                offset = .zero
                rotation = 0
            }
        }
    }

    private var cardDragGesture: some Gesture {
        DragGesture(minimumDistance: 15)
            .onChanged { gesture in
                if offset == .zero && !isHorizontalDrag {
                    // Decide once, at the start of the drag, whether this reads as a swipe
                    // (mostly horizontal) or a scroll (mostly vertical) — biased toward scroll
                    // since that's the more common gesture on a tall profile.
                    isHorizontalDrag = abs(gesture.translation.width) > abs(gesture.translation.height) * 1.5
                }
                guard isHorizontalDrag else { return }
                offset = gesture.translation
                // Clamped rather than unbounded — past a full-tilt drag, more distance shouldn't
                // keep rotating the card further, it reads as more "off the rails" than "swipey".
                rotation = Double(max(-12, min(12, gesture.translation.width / 20)))

                let pastThreshold = abs(offset.width) > swipeThreshold
                if pastThreshold && !hasTriggeredThresholdHaptic {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    hasTriggeredThresholdHaptic = true
                } else if !pastThreshold && hasTriggeredThresholdHaptic {
                    hasTriggeredThresholdHaptic = false
                }
            }
            .onEnded { gesture in
                defer {
                    isHorizontalDrag = false
                    hasTriggeredThresholdHaptic = false
                }
                guard isHorizontalDrag else { return }

                // A quick short flick can carry as much "intent to swipe" as a slower drag that
                // covers more raw distance — predictedEndTranslation factors in the gesture's
                // velocity (where it'd end up if it kept decelerating naturally), so a fast flick
                // commits the same way a full drag past swipeThreshold does, instead of requiring
                // every swipe to physically cross the same fixed distance regardless of speed.
                let committedByDistance = abs(gesture.translation.width) > swipeThreshold
                let committedByVelocity = abs(gesture.predictedEndTranslation.width) > swipeThreshold * 2.5

                if committedByDistance || committedByVelocity {
                    triggerSwipe(gesture.translation.width > 0 ? .like : .pass)
                } else {
                    withAnimation(swipeAnimation) {
                        offset = .zero
                        rotation = 0
                    }
                }
            }
    }

    private var infoSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("\(profile.name), \(profile.age)")
                    .font(.system(.largeTitle, design: .rounded).bold())

                if profile.isVerified {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.title3)
                        .foregroundStyle(.blue.gradient)
                }

                Spacer()
            }

            factsCard

            if let bio = profile.bio, !bio.isEmpty {
                Text(bio)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(Color.lumenCard)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            }

            ForEach(profile.numberedPrompts, id: \.number) { prompt in
                VStack(alignment: .leading, spacing: 6) {
                    Text(prompt.question)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(prompt.answer)
                        .font(.subheadline.weight(.medium))
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    LinearGradient(
                        colors: [Color.pink.opacity(0.12), Color.purple.opacity(0.12)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.pink.opacity(0.1), lineWidth: 1)
                )
            }

            if !profile.styleTags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(profile.styleTags, id: \.self) { tag in
                            Text(tag)
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color.pink.opacity(0.15))
                                .foregroundColor(.pink)
                                .clipShape(Capsule())
                        }
                    }
                    .padding(12)
                }
                .background(Color.lumenCard)
                .clipShape(RoundedRectangle(cornerRadius: 16))
            }
        }
        // Top gap comes from the outer VStack's own spacing (it sits right after a photo or
        // placeholder), not from padding here — padding on both would double it up.
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }

    /// One floating white card holding every "fact" about the profile — a top row of quick
    /// stats separated by hairline verticals, then a divided list of icon rows below. Modeled
    /// directly on Hinge's profile card layout (distinct rounded cards with visible gaps
    /// between them, rather than one continuous surface).
    private var factsCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                factSegment(icon: "location.fill", text: "\(profile.distance) mi")
                if let heightDisplay = profile.heightDisplay {
                    Divider().frame(height: 20)
                    factSegment(icon: "ruler", text: heightDisplay)
                }
                if let pronouns = profile.pronouns {
                    Divider().frame(height: 20)
                    factSegment(icon: "person.fill", text: pronouns)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            factRow(icon: "person.crop.circle", text: profile.genderIdentity.displayName)

            if let cityDisplay = profile.cityDisplay, !cityDisplay.isEmpty {
                Divider().padding(.leading, 48)
                factRow(icon: "house.fill", text: cityDisplay)
            }
            if let jobTitle = profile.jobTitle, !jobTitle.isEmpty {
                Divider().padding(.leading, 48)
                factRow(icon: "briefcase.fill", text: jobTitle)
            }
            if let school = profile.school, !school.isEmpty {
                Divider().padding(.leading, 48)
                factRow(icon: "graduationcap.fill", text: school)
            }
        }
        .background(Color.lumenCard)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func factSegment(icon: String, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption)
            Text(text)
                .font(.subheadline.weight(.medium))
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
    }

    private func factRow(icon: String, text: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.subheadline)
                .foregroundColor(.pink)
                .frame(width: 22)
            Text(text)
                .font(.subheadline)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func triggerSwipe(_ direction: SwipeDirection) {
        withAnimation(swipeAnimation) {
            offset = CGSize(width: direction == .like ? 600 : -600, height: 0)
        }
        Task {
            await onSwipe(direction)
        }
    }

    private var likeIndicator: some View {
        swipeStamp(text: "LIKE", systemImage: "heart.fill", color: .green, rotation: -15)
            .padding(.top, 48)
            .padding(.leading, 24)
    }

    private var passIndicator: some View {
        HStack {
            Spacer()
            swipeStamp(text: "PASS", systemImage: "xmark", color: .red, rotation: 15)
                .padding(.top, 48)
                .padding(.trailing, 24)
        }
    }

    private func swipeStamp(text: String, systemImage: String, color: Color, rotation: Double) -> some View {
        Label(text, systemImage: systemImage)
            .font(.system(size: 22, weight: .heavy, design: .rounded))
            .foregroundColor(color)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(color, lineWidth: 3)
            )
            .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
            .rotationEffect(.degrees(rotation))
    }
}
