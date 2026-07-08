import SwiftUI

struct ProfileView: View {
    @EnvironmentObject var authManager: AuthenticationManager
    @State private var showingEditProfile = false
    @State private var showingSettings = false
    @State private var showingPreview = false
    @State private var showingManagePhotos = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
            LumenHeader(title: "Profile", trailing: {
                Button {
                    showingSettings = true
                } label: {
                    Image(systemName: "gearshape.fill")
                }
                .buttonStyle(LumenIconButtonStyle())
            })
            ScrollView {
                if let user = authManager.currentUser {
                    VStack(spacing: 20) {
                        heroSection(user: user)

                        if !unreviewedPhotos(user).isEmpty {
                            reviewBanner(count: unreviewedPhotos(user).count)
                        }

                        statPills(user: user)
                        detailsCard(user: user)

                        if let bio = user.bio, !bio.isEmpty {
                            bioCard(bio: bio)
                        }

                        if !user.prompts.isEmpty {
                            promptCards(user: user)
                        }

                        if !user.styleTags.isEmpty {
                            styleTagsCard(user: user)
                        }

                        managePhotosButton
                    }
                    .padding(.bottom, 24)
                } else {
                    ProgressView()
                        .padding(.top, 100)
                }
            }
            .background(Color.lumenBackground)
            }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showingEditProfile) {
                EditProfileView()
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
            // fullScreenCover, not .sheet — the whole point is to look exactly like a real
            // discovery card (see ProfilePreviewView), and .sheet's card-style presentation
            // (inset margins, rounded corners, system drag handle, background peeking through)
            // both looks like a generic system modal instead and was the likely cause of the
            // preview's layout coming out wrong intermittently — GeometryReader sizing racing
            // with the sheet's own inset/spring transition, which fullScreenCover doesn't have.
            .fullScreenCover(isPresented: $showingPreview) {
                if let user = authManager.currentUser {
                    ProfilePreviewView(user: user)
                }
            }
            .sheet(isPresented: $showingManagePhotos) {
                ManagePhotosView()
            }
        }
    }

    // MARK: - Hero

    /// Only approved photos ever show here or anywhere else discovery-adjacent — pending/
    /// rejected ones are exactly as invisible to everyone (including a quick glance at your own
    /// profile) as they are to other users, so there's no ambiguity about what's actually live.
    /// They're still fully visible (with status badges) in Manage Photos, just not mixed into
    /// this carousel.
    private func approvedPhotos(_ user: User) -> [Photo] {
        user.photos.filter { $0.moderationStatus == "approved" }
    }

    private func unreviewedPhotos(_ user: User) -> [Photo] {
        user.photos.filter { $0.moderationStatus != "approved" }
    }

    private func reviewBanner(count: Int) -> some View {
        Button {
            showingManagePhotos = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "clock.fill")
                    .foregroundColor(.orange)
                Text(count == 1 ? "1 photo is awaiting review" : "\(count) photos are awaiting review")
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(.primary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(Color.orange.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .padding(.horizontal)
    }

    private func heroSection(user: User) -> some View {
        let photos = approvedPhotos(user)

        return ZStack(alignment: .bottom) {
            if photos.isEmpty {
                Rectangle()
                    .fill(LinearGradient(
                        colors: [.pink.opacity(0.3), .purple.opacity(0.3)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ))
                    .frame(height: 460)
                    .overlay {
                        VStack(spacing: 8) {
                            Image(systemName: "clock.fill")
                                .font(.system(size: 32))
                            Text("Your photo is under review")
                                .font(.subheadline.weight(.medium))
                        }
                        .foregroundColor(.white.opacity(0.85))
                    }
            } else {
                TabView {
                    ForEach(photos) { photo in
                        // Overlay pattern (see ProfileCardView): keeps a `.fill` photo's
                        // overflowed size out of layout so a wide photo can't bleed past its
                        // own page in the pager.
                        Color.clear
                            .overlay {
                                AsyncImage(url: APIService.shared.imageURL(for: photo.url)) { image in
                                    image.resizable().scaledToFill()
                                } placeholder: {
                                    Rectangle()
                                        .fill(LinearGradient(
                                            colors: [.pink.opacity(0.3), .purple.opacity(0.3)],
                                            startPoint: .topLeading, endPoint: .bottomTrailing
                                        ))
                                        .overlay { ProgressView() }
                                }
                            }
                            .clipped()
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: photos.count > 1 ? .always : .never))
                .frame(height: 460)
            }

            LinearGradient(
                colors: [.clear, .black.opacity(0.55)],
                startPoint: .center, endPoint: .bottom
            )
            .frame(height: 460)
            .allowsHitTesting(false)

            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text("\(user.name), \(user.age ?? 0)")
                            .font(.system(size: 32, weight: .bold))
                        if user.isVerified {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.title3)
                                .foregroundColor(.blue)
                        }
                    }
                    Text(user.displayName)
                        .font(.subheadline.weight(.medium))
                }
                .foregroundColor(.white)
                .shadow(radius: 4)

                Spacer()

                HStack(spacing: 10) {
                    Button {
                        showingPreview = true
                    } label: {
                        Image(systemName: "eye.fill")
                            .font(.headline)
                            .foregroundColor(.white)
                            .frame(width: 44, height: 44)
                            .background(.ultraThinMaterial, in: Circle())
                    }

                    Button {
                        showingEditProfile = true
                    } label: {
                        Image(systemName: "pencil")
                            .font(.headline)
                            .foregroundColor(.white)
                            .frame(width: 44, height: 44)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                }
            }
            .padding(20)
        }
        .frame(height: 460)
        .clipShape(RoundedRectangle(cornerRadius: 0))
    }

    // MARK: - Stat pills

    private func statPills(user: User) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                if let heightDisplay = user.heightDisplay {
                    statPill(icon: "ruler", text: heightDisplay)
                }
                if let city = user.cityDisplay {
                    statPill(icon: "location.fill", text: city)
                }
                if let pronouns = user.pronouns {
                    statPill(icon: "person.fill", text: pronouns)
                }
                if user.isVerified {
                    statPill(icon: "checkmark.seal.fill", text: "Verified", tint: .blue)
                }
            }
            .padding(.horizontal)
        }
    }

    private func statPill(icon: String, text: String, tint: Color = .pink) -> some View {
        Label(text, systemImage: icon)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(tint.opacity(0.12))
            .foregroundColor(tint)
            .clipShape(Capsule())
    }

    // MARK: - Details

    private func detailsCard(user: User) -> some View {
        Group {
            if user.jobTitle != nil || user.school != nil {
                VStack(alignment: .leading, spacing: 12) {
                    if let jobTitle = user.jobTitle, !jobTitle.isEmpty {
                        Label(jobTitle, systemImage: "briefcase.fill")
                            .font(.subheadline)
                    }
                    if let school = user.school, !school.isEmpty {
                        Label(school, systemImage: "graduationcap.fill")
                            .font(.subheadline)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(Color.lumenCard)
                .cornerRadius(16)
                .padding(.horizontal)
            }
        }
    }

    private func bioCard(bio: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("About")
                .font(.headline)
            Text(bio)
                .font(.body)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.lumenCard)
        .cornerRadius(16)
        .padding(.horizontal)
    }

    private func promptCards(user: User) -> some View {
        VStack(spacing: 12) {
            ForEach(Array(user.prompts.enumerated()), id: \.offset) { _, prompt in
                VStack(alignment: .leading, spacing: 8) {
                    Text(prompt.question)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(prompt.answer)
                        .font(.title3.weight(.medium))
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
            }
        }
        .padding(.horizontal)
    }

    private func styleTagsCard(user: User) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Style")
                .font(.headline)

            FlowLayout(spacing: 8) {
                ForEach(user.styleTags, id: \.self) { tag in
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
        .padding()
        .background(Color.lumenCard)
        .cornerRadius(16)
        .padding(.horizontal)
    }

    private var managePhotosButton: some View {
        Button {
            showingManagePhotos = true
        } label: {
            Label("Manage Photos", systemImage: "photo.on.rectangle.angled")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(Color.lumenCard)
                .foregroundColor(.pink)
                .cornerRadius(16)
        }
        .padding(.horizontal)
    }
}

// Simple flow layout for tags
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = FlowResult(
            in: proposal.replacingUnspecifiedDimensions().width,
            subviews: subviews,
            spacing: spacing
        )
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = FlowResult(
            in: bounds.width,
            subviews: subviews,
            spacing: spacing
        )
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: bounds.minX + result.positions[index].x, y: bounds.minY + result.positions[index].y), proposal: .unspecified)
        }
    }

    struct FlowResult {
        var size: CGSize = .zero
        var positions: [CGPoint] = []

        init(in maxWidth: CGFloat, subviews: Subviews, spacing: CGFloat) {
            var x: CGFloat = 0
            var y: CGFloat = 0
            var lineHeight: CGFloat = 0

            for subview in subviews {
                let size = subview.sizeThatFits(.unspecified)

                if x + size.width > maxWidth && x > 0 {
                    x = 0
                    y += lineHeight + spacing
                    lineHeight = 0
                }

                positions.append(CGPoint(x: x, y: y))
                lineHeight = max(lineHeight, size.height)
                x += size.width + spacing
            }

            self.size = CGSize(width: maxWidth, height: y + lineHeight)
        }
    }
}

#Preview {
    ProfileView()
        .environmentObject(AuthenticationManager.shared)
}
