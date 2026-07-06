import SwiftUI
import UIKit

/// Selfie verification. The selfie must come straight from the camera (no photo library access
/// here at all) and has to actually show a pose prompt fetched moments beforehand — see
/// APIService.getVerificationPose / verification.ts's GET /pose. Neither check is real liveness
/// detection, but together they rule out the trivially fakeable case this used to have: picking
/// any existing photo (of yourself, or of someone else entirely) straight from the camera roll.
/// A pose (not a code to hold up) deliberately mirrors the kind of liveness prompt other dating
/// apps' verification flows actually use. An admin still does the real comparison against your
/// profile photos (app_spec.md Section 3.6's "manual queue" option), reviewable from the admin
/// site's Verification tab.
struct VerificationView: View {
    @State private var status: VerificationStatusResponse?
    @State private var isLoading = true
    @State private var poseResponse: VerificationPoseResponse?
    @State private var isFetchingPose = false
    @State private var poseFetchError: String?
    @State private var showingCamera = false
    @State private var capturedImage: UIImage?
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
        .fullScreenCover(isPresented: $showingCamera) {
            CameraCaptureView(
                onCapture: { image in
                    capturedImage = image
                    showingCamera = false
                },
                onCancel: { showingCamera = false }
            )
            .ignoresSafeArea()
        }
        .customAlert(
            isPresented: Binding(get: { submitError != nil }, set: { if !$0 { submitError = nil } }),
            title: "Couldn't Submit",
            message: submitError ?? ""
        )
        .customAlert(
            isPresented: Binding(get: { poseFetchError != nil }, set: { if !$0 { poseFetchError = nil } }),
            title: "Couldn't Get Pose",
            message: poseFetchError ?? ""
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

                if let capturedImage {
                    // Overlay pattern (see ProfileCardView): a `.fill` image reports its
                    // overflowed size to layout — a wide selfie would inflate this view's width.
                    Color.clear
                        .frame(height: 260)
                        .overlay {
                            Image(uiImage: capturedImage)
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
                        Text("No selfie taken yet")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal)

            if let poseResponse {
                poseBanner(poseResponse)
            }

            Button {
                Task { await startCapture() }
            } label: {
                if isFetchingPose {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                } else {
                    Label(capturedImage == nil ? "Get My Pose & Take Selfie" : "Retake Selfie", systemImage: "camera.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                }
            }
            .background(Color.lumenCard)
            .foregroundColor(.pink)
            .cornerRadius(14)
            .buttonStyle(LumenPressableStyle())
            .disabled(isFetchingPose)
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
            .buttonStyle(LumenPrimaryButtonStyle(isEnabled: capturedImage != nil && poseResponse != nil))
            .disabled(capturedImage == nil || poseResponse == nil || isSubmitting)
            .padding(.horizontal)

            Text("Your selfie has to actually show the pose above, taken live rather than picked from your library, before a real person compares it to your profile photos. Usually reviewed within a day.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }

    private func poseBanner(_ poseResponse: VerificationPoseResponse) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            poseBannerContent(remaining: Int(poseResponse.expiresAt.timeIntervalSince(context.date)), label: poseResponse.poseLabel)
        }
    }

    @ViewBuilder
    private func poseBannerContent(remaining: Int, label: String) -> some View {
        VStack(spacing: 6) {
            Text("Strike this pose in your selfie")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(label)
                .font(.title3.weight(.bold))
                .multilineTextAlignment(.center)
            Text(remaining > 0 ? "Expires in \(remaining / 60):\(String(format: "%02d", remaining % 60))" : "Expired, get a new pose")
                .font(.caption2)
                .foregroundStyle(remaining > 0 ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.red))
        }
        .frame(maxWidth: .infinity)
        .padding(14)
        .background(Color.lumenCard)
        .cornerRadius(14)
        .padding(.horizontal)
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

    /// Fetches a fresh pose first, then opens the camera — in that order, so the pose is always
    /// generated moments before the photo it's meant to appear in, not reused from an earlier,
    /// possibly-stale attempt.
    private func startCapture() async {
        isFetchingPose = true
        defer { isFetchingPose = false }

        do {
            poseResponse = try await APIService.shared.getVerificationPose()
            capturedImage = nil

            guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
                poseFetchError = "Camera not available on this device."
                return
            }
            showingCamera = true
        } catch {
            poseFetchError = error.localizedDescription
        }
    }

    private func submit() async {
        guard let capturedImage,
              let poseResponse,
              let jpegData = capturedImage.jpegData(compressionQuality: 0.85) else { return }

        isSubmitting = true
        defer { isSubmitting = false }

        do {
            try await APIService.shared.submitVerificationPhoto(imageData: jpegData, poseId: poseResponse.poseId)
            self.capturedImage = nil
            self.poseResponse = nil
            await load()
        } catch {
            submitError = error.localizedDescription
        }
    }
}

/// Wraps UIImagePickerController rather than PhotosPicker specifically to force `.camera` as the
/// source type — PhotosPicker (and a `.camera`-less UIImagePickerController) can both return a
/// photo that already existed before this screen ever opened, which is exactly what verification
/// needs to rule out. No corresponding SwiftUI-native camera API exists as of this app's
/// deployment target, hence the UIKit bridge.
private struct CameraCaptureView: UIViewControllerRepresentable {
    var onCapture: (UIImage) -> Void
    var onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        // Front camera by default since this is a selfie — falls back to the rear camera's
        // default only on the (hypothetical) device with no front camera at all.
        if UIImagePickerController.isCameraDeviceAvailable(.front) {
            picker.cameraDevice = .front
        }
        picker.cameraCaptureMode = .photo
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraCaptureView

        init(_ parent: CameraCaptureView) {
            self.parent = parent
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage {
                parent.onCapture(image)
            } else {
                parent.onCancel()
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.onCancel()
        }
    }
}

#Preview {
    NavigationStack {
        VerificationView()
    }
}
