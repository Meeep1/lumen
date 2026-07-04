import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var authManager: AuthenticationManager
    @Environment(\.dismiss) var dismiss

    @State private var discoverable = true
    @State private var showingLogoutConfirmation = false
    @State private var showingDeleteConfirmation = false
    @State private var showingDeleteError = false
    @State private var deleteErrorMessage = ""

    var body: some View {
        NavigationStack {
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
                            } label: {
                                SettingsRow(icon: "bell.fill", title: "Notification Preferences")
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    SettingsSection(title: "About") {
                        SettingsCard {
                            Link(destination: URL(string: "https://example.com/terms")!) {
                                SettingsRow(icon: "doc.text.fill", title: "Terms of Service")
                            }
                            Divider().padding(.leading, 52)
                            Link(destination: URL(string: "https://example.com/privacy")!) {
                                SettingsRow(icon: "hand.raised.fill", title: "Privacy Policy")
                            }
                            Divider().padding(.leading, 52)
                            Link(destination: URL(string: "https://example.com/guidelines")!) {
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
                                .background(Color(uiColor: .systemBackground))
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                        }

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
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 20)
            }
            .background(Color.lumenBackground)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
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
        .background(Color(uiColor: .systemBackground))
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
        .navigationTitle("Blocked Users")
        .navigationBarTitleDisplayMode(.inline)
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
    @State private var newMatchNotifications = true
    @State private var newMessageNotifications = true
    @State private var newLikeNotifications = true

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                SettingsCard {
                    SettingsToggleRow(icon: "heart.fill", title: "New Matches", isOn: $newMatchNotifications)
                    Divider().padding(.leading, 52)
                    SettingsToggleRow(icon: "message.fill", title: "New Messages", isOn: $newMessageNotifications)
                    Divider().padding(.leading, 52)
                    SettingsToggleRow(icon: "star.fill", title: "New Likes", isOn: $newLikeNotifications)
                }

                Text("Notification preferences are stored on your device. You can also manage notifications in iOS Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }
            .padding()
        }
        .background(Color.lumenBackground)
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    SettingsView()
        .environmentObject(AuthenticationManager.shared)
}
