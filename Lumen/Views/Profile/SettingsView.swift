import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var authManager: AuthenticationManager
    @Environment(\.dismiss) var dismiss

    @State private var discoverable = true
    @State private var showingLogoutConfirmation = false
    @State private var showingDeleteConfirmation = false
    @State private var showingDeleteError = false
    @State private var deleteErrorMessage = ""

    // Keep in sync with APIService.baseURL / SocketManager.socketURL.
    #if DEBUG
    private var legalBaseURL: String { BackendEnvironmentStore.shared.current.baseURL }
    #else
    private let legalBaseURL = "https://lumenfem.app"
    #endif

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
            LumenHeader(title: "Settings", trailing: {
                LumenHeaderTextButton(title: "Done") { dismiss() }
            })
            ScrollView {
                VStack(spacing: 24) {
                    SettingsCard {
                        NavigationLink {
                            VerificationView()
                        } label: {
                            SettingsRow(
                                icon: "checkmark.seal.fill",
                                iconTint: authManager.currentUser?.isVerified == true ? .blue : .pink,
                                title: authManager.currentUser?.isVerified == true ? "Verified" : "Get Verified"
                            )
                        }
                        .buttonStyle(.plain)
                    }

                    SettingsSection(title: "Privacy") {
                        SettingsCard {
                            SettingsToggleRow(icon: "eye.fill", title: "Discoverable", isOn: $discoverable)
                                .onChange(of: discoverable) { _, newValue in
                                    Task { await updateDiscoverability(newValue) }
                                }

                            Divider().padding(.leading, 52)

                            NavigationLink {
                                UpdateLocationView()
                            } label: {
                                SettingsRow(icon: "location.fill", title: "Update Location", valueText: authManager.currentUser?.cityDisplay)
                            }
                            .buttonStyle(.plain)

                            Divider().padding(.leading, 52)

                            NavigationLink {
                                BlockedUsersView()
                            } label: {
                                SettingsRow(icon: "person.crop.circle.badge.xmark", title: "Blocked Users")
                            }
                            .buttonStyle(.plain)
                        }

                        Text("When off, you won't appear in other users' discovery stack.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                    }

                    SettingsSection(title: "Notifications") {
                        SettingsCard {
                            NavigationLink {
                                NotificationPreferencesView()
                                    .environmentObject(authManager)
                            } label: {
                                SettingsRow(icon: "bell.fill", title: "Notification Preferences")
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    SettingsSection(title: "Support") {
                        SettingsCard {
                            NavigationLink {
                                FeedbackView()
                            } label: {
                                SettingsRow(icon: "bubble.left.and.exclamationmark.bubble.right.fill", title: "Send Feedback")
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    SettingsSection(title: "About") {
                        SettingsCard {
                            // Real pages (backend/public/site/), served by the same backend as
                            // everything else.
                            Link(destination: URL(string: "\(legalBaseURL)/terms")!) {
                                SettingsRow(icon: "doc.text.fill", title: "Terms of Service")
                            }
                            Divider().padding(.leading, 52)
                            Link(destination: URL(string: "\(legalBaseURL)/privacy")!) {
                                SettingsRow(icon: "hand.raised.fill", title: "Privacy Policy")
                            }
                            Divider().padding(.leading, 52)
                            Link(destination: URL(string: "\(legalBaseURL)/community-guidelines")!) {
                                SettingsRow(icon: "book.fill", title: "Community Guidelines")
                            }
                        }
                    }

                    VStack(spacing: 10) {
                        Button {
                            showingLogoutConfirmation = true
                        } label: {
                            Text("Log Out")
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(.red)
                                .frame(maxWidth: .infinity)
                                .frame(height: 50)
                                .background(Color.lumenCard)
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                        }
                        .buttonStyle(LumenPressableStyle())

                        Button {
                            showingDeleteConfirmation = true
                        } label: {
                            Text("Delete Account")
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 50)
                                .background(Color.red.gradient)
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                        }
                        .buttonStyle(LumenPressableStyle())
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 20)
            }
            .background(Color.lumenBackground)
            }
            .toolbar(.hidden, for: .navigationBar)
            .onAppear {
                loadSettings()
            }
            .customConfirmation(
                isPresented: $showingLogoutConfirmation,
                title: "Log Out",
                message: "Are you sure you want to log out?",
                actions: [
                    CustomSheetAction(title: "Log Out", systemImage: "rectangle.portrait.and.arrow.right", isDestructive: true) {
                        Task {
                            await authManager.logout()
                            dismiss()
                        }
                    },
                ]
            )
            .customConfirmation(
                isPresented: $showingDeleteConfirmation,
                title: "Delete Account",
                message: "This action cannot be undone. All your data will be permanently deleted.",
                actions: [
                    CustomSheetAction(title: "Delete Account", systemImage: "trash", isDestructive: true) {
                        Task { await deleteAccount() }
                    },
                ]
            )
            .customAlert(
                isPresented: $showingDeleteError,
                title: "Couldn't Delete Account",
                message: deleteErrorMessage
            )
        }
    }

    private func loadSettings() {
        discoverable = authManager.currentUser?.discoverable ?? true
    }

    private func updateDiscoverability(_ value: Bool) async {
        let update = ProfileUpdate(
            bio: nil,
            pronouns: nil,
            styleTags: nil,
            heightInches: nil,
            jobTitle: nil,
            school: nil,
            prompt1Question: nil,
            prompt1Answer: nil,
            prompt2Question: nil,
            prompt2Answer: nil,
            latitude: nil,
            longitude: nil,
            cityDisplay: nil,
            discoverable: value
        )

        _ = await authManager.updateProfile(update)
    }

    private func deleteAccount() async {
        let result = await authManager.deleteAccount()

        switch result {
        case .success:
            dismiss()
        case .failure(let error):
            deleteErrorMessage = error.localizedDescription
            showingDeleteError = true
        }
    }
}

// MARK: - Shared settings building blocks

/// Small-caps label above a card, matching the section-header language ProfileView already
/// uses for "About"/"Style" cards — kept here so every settings screen (this one, Blocked
/// Users, Notification Preferences) reads as one consistent design instead of stock Form
/// grouping.
struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
            content
        }
    }
}

struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .background(Color.lumenCard)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

struct SettingsRow: View {
    let icon: String
    var iconTint: Color = .pink
    let title: String
    var valueText: String? = nil

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(iconTint)
                .frame(width: 28, height: 28)
                .background(iconTint.opacity(0.12))
                .clipShape(Circle())

            Text(title)
                .font(.subheadline)
                .foregroundColor(.primary)

            Spacer()

            if let valueText {
                Text(valueText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }
}

/// Onboarding's LocationStepView only ever runs once, at signup — there was previously no way
/// for someone to correct or refresh their saved city afterward (a stale value from before a
/// reverse-geocoding fix, or just having moved), short of deleting and recreating their account.
/// This mirrors that same request-location-then-save flow, just reachable from Settings instead
/// and without an onContinue step to chain into.
struct UpdateLocationView: View {
    @EnvironmentObject var authManager: AuthenticationManager
    @Environment(\.dismiss) var dismiss
    @StateObject private var locationManager = LocationManager.shared
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var didSave = false

    var body: some View {
        VStack(spacing: 0) {
            LumenHeader(title: "Update Location", leading: {
                LumenBackButton()
            })

            VStack(spacing: 24) {
                Spacer()

                Image(systemName: "location.circle.fill")
                    .resizable()
                    .frame(width: 80, height: 80)
                    .foregroundStyle(Theme.primaryGradient)

                Text("Update your location")
                    .font(.title.bold())

                Text("Refreshes your city from your current location. We only ever show your city and distance to others, never your exact location.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 32)

                if let current = authManager.currentUser?.cityDisplay, locationManager.resolvedLocation == nil {
                    Label("Currently: \(current)", systemImage: "mappin.circle")
                        .foregroundStyle(.secondary)
                }

                if let city = locationManager.resolvedLocation?.cityDisplay {
                    Label(didSave ? "Updated to \(city)" : city, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }

                if let error = locationManager.errorMessage ?? saveError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)

                    if locationManager.authorizationStatus == .denied {
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                        .font(.subheadline)
                        .buttonStyle(LumenPressableStyle())
                    }
                }

                Spacer()

                Button {
                    if didSave {
                        dismiss()
                    } else if locationManager.resolvedLocation != nil {
                        Task { await save() }
                    } else {
                        locationManager.requestLocation()
                    }
                } label: {
                    if locationManager.isResolving || isSaving {
                        ProgressView().tint(.white)
                    } else if didSave {
                        Text("Done")
                    } else {
                        Text(locationManager.resolvedLocation != nil ? "Save" : "Refresh Location")
                    }
                }
                .buttonStyle(LumenPrimaryButtonStyle())
                .padding(.horizontal, 32)
                .disabled(locationManager.isResolving || isSaving)
                .padding(.bottom, 32)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    private func save() async {
        guard let resolved = locationManager.resolvedLocation else { return }
        isSaving = true
        saveError = nil
        defer { isSaving = false }

        let update = ProfileUpdate(
            bio: nil,
            pronouns: nil,
            styleTags: nil,
            heightInches: nil,
            jobTitle: nil,
            school: nil,
            prompt1Question: nil,
            prompt1Answer: nil,
            prompt2Question: nil,
            prompt2Answer: nil,
            latitude: resolved.latitude,
            longitude: resolved.longitude,
            cityDisplay: resolved.cityDisplay,
            discoverable: nil
        )

        switch await authManager.updateProfile(update) {
        case .success:
            didSave = true
        case .failure(let error):
            saveError = error.localizedDescription
        }
    }
}

/// One-way "tell us something" box, read from the admin panel's Feedback tab, not a support
/// ticket with a reply loop — matches backend/prisma/schema.prisma's Feedback model comment.
struct FeedbackView: View {
    @Environment(\.dismiss) var dismiss
    @State private var message = ""
    @State private var isSending = false
    @State private var sendError: String?
    @State private var didSend = false

    var body: some View {
        VStack(spacing: 0) {
            LumenHeader(title: "Send Feedback", leading: {
                LumenBackButton()
            })

            VStack(spacing: 20) {
                if didSend {
                    Spacer()

                    Image(systemName: "checkmark.circle.fill")
                        .resizable()
                        .frame(width: 64, height: 64)
                        .foregroundStyle(.green.gradient)

                    Text("Thanks!")
                        .font(.title2.bold())

                    Text("Your feedback goes straight to the team.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button {
                        dismiss()
                    } label: {
                        Text("Done")
                    }
                    .buttonStyle(LumenPrimaryButtonStyle())
                    .padding(.horizontal, 32)
                    .padding(.bottom, 32)
                } else {
                    Text("What's on your mind?")
                        .font(.title2.bold())
                        .padding(.top, 24)

                    Text("Bug reports, feature ideas, anything at all. This goes directly to the team, not a bot.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)

                    TextEditor(text: $message)
                        .padding(8)
                        .background(Color.lumenSurface)
                        .cornerRadius(14)
                        .frame(height: 180)
                        .padding(.horizontal, 24)

                    if let sendError {
                        Text(sendError)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }

                    Spacer()

                    Button {
                        Task { await send() }
                    } label: {
                        if isSending {
                            ProgressView().tint(.white)
                        } else {
                            Text("Send")
                        }
                    }
                    .buttonStyle(LumenPrimaryButtonStyle(isEnabled: !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                    .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)
                    .padding(.horizontal, 32)
                    .padding(.bottom, 32)
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    private func send() async {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        isSending = true
        sendError = nil
        defer { isSending = false }

        do {
            try await APIService.shared.submitFeedback(message: trimmed)
            didSend = true
        } catch {
            sendError = error.localizedDescription
        }
    }
}

struct SettingsToggleRow: View {
    let icon: String
    var iconTint: Color = .pink
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(iconTint)
                .frame(width: 28, height: 28)
                .background(iconTint.opacity(0.12))
                .clipShape(Circle())

            Text(title)
                .font(.subheadline)
                .foregroundColor(.primary)

            Spacer()

            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(.pink)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

// MARK: - Blocked Users

struct BlockedUsersView: View {
    @State private var blockedUserIds: [String] = []
    @State private var isLoading = false

    var body: some View {
        VStack(spacing: 0) {
        LumenHeader(title: "Blocked Users", leading: {
            LumenBackButton()
        })
        ZStack {
            Color.lumenBackground
                .ignoresSafeArea()

            Group {
                if isLoading {
                    ProgressView()
                } else if blockedUserIds.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "person.slash")
                            .resizable()
                            .frame(width: 60, height: 60)
                            .foregroundStyle(.secondary)

                        Text("No Blocked Users")
                            .font(.headline)

                        Text("Users you block will appear here")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                } else {
                    ScrollView {
                        SettingsCard {
                            ForEach(Array(blockedUserIds.enumerated()), id: \.element) { index, userId in
                                if index > 0 {
                                    Divider().padding(.leading, 16)
                                }
                                HStack {
                                    Text("User \(userId.prefix(8))...")
                                        .font(.subheadline)

                                    Spacer()

                                    Button("Unblock") {
                                        Task { await unblock(userId: userId) }
                                    }
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundColor(.pink)
                                    .buttonStyle(LumenPressableStyle())
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
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
            await loadBlockedUsers()
        }
    }

    private func loadBlockedUsers() async {
        isLoading = true
        defer { isLoading = false }

        do {
            blockedUserIds = try await APIService.shared.getBlockedUsers()
        } catch {
            print("Failed to load blocked users: \(error)")
        }
    }

    private func unblock(userId: String) async {
        do {
            try await APIService.shared.unblockUser(userId: userId)
            blockedUserIds.removeAll { $0 == userId }
        } catch {
            print("Failed to unblock user: \(error)")
        }
    }
}

// MARK: - Notification Preferences

struct NotificationPreferencesView: View {
    @EnvironmentObject var authManager: AuthenticationManager
    @State private var newMatchNotifications = true
    @State private var newMessageNotifications = true
    @State private var newLikeNotifications = true

    var body: some View {
        VStack(spacing: 0) {
        LumenHeader(title: "Notifications", leading: {
            LumenBackButton()
        })
        ScrollView {
            VStack(spacing: 16) {
                SettingsCard {
                    SettingsToggleRow(icon: "heart.fill", title: "New Matches", isOn: $newMatchNotifications)
                        .onChange(of: newMatchNotifications) { _, newValue in
                            Task { await updatePreference(notifyNewMatch: newValue) }
                        }
                    Divider().padding(.leading, 52)
                    SettingsToggleRow(icon: "message.fill", title: "New Messages", isOn: $newMessageNotifications)
                        .onChange(of: newMessageNotifications) { _, newValue in
                            Task { await updatePreference(notifyNewMessage: newValue) }
                        }
                    Divider().padding(.leading, 52)
                    SettingsToggleRow(icon: "star.fill", title: "New Likes", isOn: $newLikeNotifications)
                        .onChange(of: newLikeNotifications) { _, newValue in
                            Task { await updatePreference(notifyNewLike: newValue) }
                        }
                }

                Text("You can also manage notifications in iOS Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }
            .padding()
        }
        .background(Color.lumenBackground)
        }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            newMatchNotifications = authManager.currentUser?.notifyNewMatch ?? true
            newMessageNotifications = authManager.currentUser?.notifyNewMessage ?? true
            newLikeNotifications = authManager.currentUser?.notifyNewLike ?? true
        }
    }

    private func updatePreference(
        notifyNewMatch: Bool? = nil,
        notifyNewMessage: Bool? = nil,
        notifyNewLike: Bool? = nil
    ) async {
        let update = ProfileUpdate(
            bio: nil, pronouns: nil, styleTags: nil, heightInches: nil, jobTitle: nil, school: nil,
            prompt1Question: nil, prompt1Answer: nil, prompt2Question: nil, prompt2Answer: nil,
            latitude: nil, longitude: nil, cityDisplay: nil, discoverable: nil,
            notifyNewMatch: notifyNewMatch, notifyNewMessage: notifyNewMessage, notifyNewLike: notifyNewLike
        )
        _ = await authManager.updateProfile(update)
    }
}

#Preview {
    SettingsView()
        .environmentObject(AuthenticationManager.shared)
}
