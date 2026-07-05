import SwiftUI
import PhotosUI

/// Selfie-vs-profile-photo verification. No liveness check here — just a clear selfie an admin
/// compares against your existing profile photos (app_spec.md Section 3.6's "manual queue"
/// option), reviewable from the admin site's Verification tab.
struct VerificationView: View {
    @State private var status: VerificationStatusResponse?
    @State private var isLoading = true
    @State private var pickerItem: PhotosPickerItem?
    @State private var selectedImageData: Data?
    @State private var isSubmitting = false
    @State private var submitError: String?

    var body: some View {
        VStack(spacing: 0) {
            LumenHeader(title: "Get Verified", leading: {
                LumenBackButton()
            })
            ScrollView {
                VStack(spacing: 20) {
                    if isLoading {
                        ProgressView()
                            .padding(.top, 60)
                    } else if let status {
                        statusBadge(for: status)

                        if status.status == "approved" {
                            Text("Your profile shows a verified badge to everyone who sees it.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 32)
                        } else {
                            submissionCard(status: status)
                        }
                    }
                }
                .padding(.vertical, 24)
            }
            .background(Color.lumenBackground)
        }
        .toolbar(.hidden, for: .navigationBar)
        .task { await load() }
        .onChange(of: pickerItem) { _, newItem in
            Task {
                guard let newItem, let data = try? await newItem.loadTransferable(type: Data.self) else { return }
                selectedImageData = data
            }
        }
        .customAlert(
            isPresented: Binding(get: { submitError != nil }, set: { if !$0 { submitError = nil } }),
            title: "Couldn't Submit",
            message: submitError ?? ""
        )
    }

    @ViewBuilder
    private func statusBadge(for status: VerificationStatusResponse) -> some View {
        VStack(spacing: 12) {
            Image(systemName: iconName(for: status.status))
                .resizable()
                .frame(width: 64, height: 64)
                .foregroundStyle(iconColor(for: status.status).gradient)

            Text(title(for: status.status))
                .font(.title2.bold())

            Text(subtitle(for: status.status))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }

    private func submissionCard(status: VerificationStatusResponse) -> some View {
        VStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color.lumenCard)
                    .frame(height: 260)

                if let selectedImageData, let uiImage = UIImage(data: selectedImageData) {
                    // Overlay pattern (see ProfileCardView): a `.fill` image reports its
                    // overflowed size to layout — a wide selfie would inflate this view's width.
                    Color.clear
                        .frame(height: 260)
                        .overlay {
                            Image(uiImage: uiImage)
                                .resizable()
                                .scaledToFill()
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                } else if let photoUrl = status.photoUrl, let url = APIService.shared.imageURL(for: photoUrl) {
                    Color.clear
                        .frame(height: 260)
                        .overlay {
                            AsyncImage(url: url) { image in
                                image.resizable().scaledToFill()
                            } placeholder: {
                                ProgressView()
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "camera.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(.secondary)
                        Text("No selfie selected yet")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal)

            PhotosPicker(selection: $pickerItem, matching: .images) {
                Label(selectedImageData == nil ? "Choose a Selfie" : "Choose a Different Selfie", systemImage: "photo.on.rectangle")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(Color.lumenCard)
                    .foregroundColor(.pink)
                    .cornerRadius(14)
            }
            .buttonStyle(LumenPressableStyle())
            .padding(.horizontal)

            Button {
                Task { await submit() }
            } label: {
                if isSubmitting {
                    ProgressView().tint(.white)
                } else {
                    Text(status.status == "rejected" ? "Resubmit" : "Submit for Review")
                }
            }
            .buttonStyle(LumenPrimaryButtonStyle(isEnabled: selectedImageData != nil))
            .disabled(selectedImageData == nil || isSubmitting)
            .padding(.horizontal)

            Text("A real person compares your selfie to your profile photos before approving — this usually takes less than a day.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }

    private func iconName(for status: String) -> String {
        switch status {
        case "approved": return "checkmark.seal.fill"
        case "pending": return "clock.fill"
        case "rejected": return "xmark.seal.fill"
        default: return "checkmark.seal"
        }
    }

    private func iconColor(for status: String) -> Color {
        switch status {
        case "approved": return .blue
        case "pending": return .orange
        case "rejected": return .red
        default: return .pink
        }
    }

    private func title(for status: String) -> String {
        switch status {
        case "approved": return "You're Verified"
        case "pending": return "Under Review"
        case "rejected": return "Not Approved"
        default: return "Get Verified"
        }
    }

    private func subtitle(for status: String) -> String {
        switch status {
        case "pending": return "We'll notify you once it's reviewed."
        case "rejected": return "Try a clearer selfie that matches your profile photos, then resubmit below."
        default: return "Verified profiles get a badge and are shown higher in discovery."
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            status = try await APIService.shared.getVerificationStatus()
        } catch {
            print("Failed to load verification status: \(error)")
        }
    }

    private func submit() async {
        guard let selectedImageData,
              let uiImage = UIImage(data: selectedImageData),
              let jpegData = uiImage.jpegData(compressionQuality: 0.85) else { return }

        isSubmitting = true
        defer { isSubmitting = false }

        do {
            try await APIService.shared.submitVerificationPhoto(imageData: jpegData)
            self.selectedImageData = nil
            await load()
        } catch {
            submitError = error.localizedDescription
        }
    }
}

#Preview {
    NavigationStack {
        VerificationView()
    }
}
