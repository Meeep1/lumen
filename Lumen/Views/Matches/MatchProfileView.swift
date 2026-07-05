import SwiftUI

/// Read-only profile view for a matched user — reachable by tapping their photo in the match
/// list, or "View Profile" from the chat options menu.
struct MatchProfileView: View {
    let userId: String
    var onUnmatch: (() -> Void)? = nil

    @Environment(\.dismiss) var dismiss
    @State private var profile: User?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var showingReportSheet = false
    @State private var showingUnmatchConfirmation = false
    @State private var showingOptions = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
            LumenHeader(title: "", leading: {
                LumenBackButton(systemImage: "xmark")
            }, trailing: {
                Button {
                    showingOptions = true
                } label: {
                    Image(systemName: "ellipsis")
                }
                .buttonStyle(LumenIconButtonStyle())
            })
            ScrollView {
                if let profile {
                    VStack(spacing: 20) {
                        heroSection(profile: profile)
                        statPills(profile: profile)
                        detailsCard(profile: profile)

                        if let bio = profile.bio, !bio.isEmpty {
                            bioCard(bio: bio)
                        }

                        if !profile.prompts.isEmpty {
                            promptCards(profile: profile)
                        }

                        if !profile.styleTags.isEmpty {
                            styleTagsCard(profile: profile)
                        }
                    }
                    .padding(.bottom, 24)
                } else if isLoading {
                    ProgressView()
                        .padding(.top, 100)
                } else {
                    VStack(spacing: 12) {
                        Text(errorMessage ?? "Couldn't load this profile.")
                            .foregroundStyle(.secondary)
                        Button("Try Again") {
                            Task { await load() }
                        }
                    }
                    .padding(.top, 100)
                }
            }
            .background(Color.lumenBackground)
            }
            .toolbar(.hidden, for: .navigationBar)
            .customConfirmation(
                isPresented: $showingOptions,
                title: "Options",
                actions: [
                    CustomSheetAction(title: "Report", systemImage: "flag", isDestructive: true) {
                        showingReportSheet = true
                    },
                ] + (onUnmatch != nil ? [
                    CustomSheetAction(title: "Unmatch", systemImage: "heart.slash", isDestructive: true) {
                        showingUnmatchConfirmation = true
                    },
                ] : [])
            )
            .customConfirmation(
                isPresented: $showingUnmatchConfirmation,
                title: "Unmatch",
                message: "This will remove the match and delete your conversation.",
                actions: [
                    CustomSheetAction(title: "Unmatch", systemImage: "heart.slash", isDestructive: true) {
                        onUnmatch?()
                        dismiss()
                    },
                ]
            )
            .sheet(isPresented: $showingReportSheet) {
                ReportUserSheet(reportedId: userId)
            }
        }
        .task {
            await load()
        }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            profile = try await APIService.shared.getUserProfile(userId: userId)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func heroSection(profile: User) -> some View {
        ZStack(alignment: .bottom) {
            TabView {
                ForEach(profile.photos) { photo in
                    // Overlay pattern (see ProfileCardView): keeps a `.fill` photo's overflowed
                    // size out of layout so a wide photo can't bleed past its own page.
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
            .tabViewStyle(.page(indexDisplayMode: profile.photos.count > 1 ? .always : .never))
            .frame(height: 460)

            LinearGradient(
                colors: [.clear, .black.opacity(0.55)],
                startPoint: .center, endPoint: .bottom
            )
            .frame(height: 460)
            .allowsHitTesting(false)

            HStack(alignment: .bottom) {
                HStack(spacing: 6) {
                    Text("\(profile.age ?? 0)")
                        .font(.system(size: 32, weight: .bold))
                    if profile.isVerified {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.title3)
                            .foregroundColor(.blue)
                    }
                }
                .foregroundColor(.white)
                .shadow(radius: 4)

                Spacer()
            }
            .padding(20)
        }
        .frame(height: 460)
    }

    private func statPills(profile: User) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                if let heightDisplay = profile.heightDisplay {
                    statPill(icon: "ruler", text: heightDisplay)
                }
                if let city = profile.cityDisplay {
                    statPill(icon: "location.fill", text: city)
                }
                if let pronouns = profile.pronouns {
                    statPill(icon: "person.fill", text: pronouns)
                }
                if profile.isVerified {
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

    private func detailsCard(profile: User) -> some View {
        Group {
            if profile.jobTitle != nil || profile.school != nil {
                VStack(alignment: .leading, spacing: 12) {
                    if let jobTitle = profile.jobTitle, !jobTitle.isEmpty {
                        Label(jobTitle, systemImage: "briefcase.fill")
                            .font(.subheadline)
                    }
                    if let school = profile.school, !school.isEmpty {
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

    private func promptCards(profile: User) -> some View {
        VStack(spacing: 12) {
            ForEach(Array(profile.prompts.enumerated()), id: \.offset) { _, prompt in
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

    private func styleTagsCard(profile: User) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Style")
                .font(.headline)

            FlowLayout(spacing: 8) {
                ForEach(profile.styleTags, id: \.self) { tag in
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
}

/// Minimal report sheet — reused by MatchProfileView and (soon) ChatView.
struct ReportUserSheet: View {
    let reportedId: String
    @Environment(\.dismiss) var dismiss

    @State private var reason: ReportReason = .harassment
    @State private var details = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var didSubmit = false

    var body: some View {
        ZStack {
            Color.lumenBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                LumenHeader(title: "Report", leading: {
                    LumenHeaderTextButton(title: "Cancel") { dismiss() }
                }, trailing: {
                    LumenHeaderTextButton(title: "Submit", isDisabled: isSubmitting) {
                        Task { await submit() }
                    }
                })

                ScrollView {
                    VStack(spacing: 20) {
                        SettingsSection(title: "Reason") {
                            SettingsCard {
                                ForEach(Array(ReportReason.allCases.enumerated()), id: \.element) { index, r in
                                    if index > 0 {
                                        Divider().padding(.leading, 16)
                                    }
                                    Button {
                                        reason = r
                                    } label: {
                                        HStack {
                                            Text(r.displayName)
                                                .font(.subheadline)
                                                .foregroundColor(.primary)
                                            Spacer()
                                            if reason == r {
                                                Image(systemName: "checkmark")
                                                    .font(.subheadline.weight(.semibold))
                                                    .foregroundColor(.pink)
                                            }
                                        }
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 12)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(LumenPressableStyle(scale: 0.99))
                                }
                            }
                        }

                        SettingsSection(title: "Details (optional)") {
                            SettingsCard {
                                TextField("Anything else we should know", text: $details, axis: .vertical)
                                    .lineLimit(3...6)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 12)
                            }
                        }

                        if let errorMessage {
                            Text(errorMessage).foregroundStyle(.red).font(.caption)
                        }
                    }
                    .padding()
                }
            }
        }
        .customAlert(
            isPresented: $didSubmit,
            title: "Report Submitted",
            message: "Thanks, our team will review it.",
            onDismiss: { dismiss() }
        )
    }

    private func submit() async {
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }

        do {
            try await APIService.shared.reportUser(report: ReportRequest(
                reportedId: reportedId,
                reason: reason,
                details: details.isEmpty ? nil : details
            ))
            didSubmit = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

#Preview {
    MatchProfileView(userId: "preview")
}
