import SwiftUI
import PhotosUI

/// Post-signup, pre-discovery flow (app_spec.md Section 3.2a). Location and one photo are
/// mandatory since Discovery can't function without them; the rest is skippable and editable
/// later from Settings.
struct OnboardingView: View {
    @EnvironmentObject var authManager: AuthenticationManager
    var onFinish: () -> Void = {}

    private enum Step: Int, CaseIterable {
        case location, photo, morePhotos, about, height, details, prompts, tags, notifications
    }

    @State private var step: Step = .location

    var body: some View {
        ZStack {
            Color.lumenBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                // Location has no back button — behind it is just the auth flow, not a
                // meaningful "previous step."
                if step != .location {
                    LumenHeader(title: "", leading: {
                        LumenBackButton(action: goBack)
                    })
                } else {
                    Color.clear.frame(height: 44)
                }

                ProgressView(value: Double(step.rawValue + 1), total: Double(Step.allCases.count))
                    .tint(.pink)
                    .padding(.horizontal)
                    .padding(.top, 8)

                Group {
                    switch step {
                    case .location:
                        LocationStepView(onContinue: { advance() })
                    case .photo:
                        PhotoStepView(onContinue: { advance() })
                    case .morePhotos:
                        MorePhotosStepView(onContinue: { advance() }, onSkip: { advance() })
                    case .about:
                        AboutStepView(onContinue: { advance() }, onSkip: { advance() })
                    case .height:
                        HeightStepView(onContinue: { advance() }, onSkip: { advance() })
                    case .details:
                        DetailsStepView(onContinue: { advance() }, onSkip: { advance() })
                    case .prompts:
                        PromptsStepView(onContinue: { advance() }, onSkip: { advance() })
                    case .tags:
                        TagsStepView(onFinish: { advance() }, onSkip: { advance() })
                    case .notifications:
                        NotificationsStepView(onFinish: { finish() }, onSkip: { finish() })
                    }
                }
                .frame(maxHeight: .infinity)
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)
                ))
                .id(step)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: step)
        .task {
            // .onChange below only fires on a *change*, so the very first step needs its own
            // log call here — see OnboardingEvent's own comment in schema.prisma for why this
            // exists (self-hosted funnel tracking, not a third-party analytics SDK).
            await APIService.shared.logOnboardingStep(String(describing: step))
        }
        .onChange(of: step) { _, newStep in
            Task { await APIService.shared.logOnboardingStep(String(describing: newStep)) }
        }
    }

    private func advance() {
        guard let next = Step(rawValue: step.rawValue + 1) else {
            finish()
            return
        }
        step = next
    }

    private func goBack() {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        step = previous
    }

    private func finish() {
        Task {
            await APIService.shared.logOnboardingStep("completed")
            await authManager.loadCurrentUser()
            onFinish()
        }
    }
}

/// Optional — the previous step only requires one photo, so this offers a chance to round out
/// the profile with more (up to the same 6-photo cap as Manage Photos) before ever reaching
/// Discovery, rather than only being discoverable from Settings afterward.
///
/// Deliberately shows every uploaded photo with no moderation-status badge (unlike Manage
/// Photos' "Under review"/"Not approved" treatment) — moderation still runs the same as any
/// other upload (see queue.ts), this just doesn't surface that mid-onboarding, where it would
/// read as an interruption rather than useful status.
private struct MorePhotosStepView: View {
    @EnvironmentObject var authManager: AuthenticationManager
    let onContinue: () -> Void
    let onSkip: () -> Void

    @State private var photos: [Photo] = []
    @State private var pickerItem: PhotosPickerItem?
    @State private var imageToCrop: UIImage?
    @State private var isUploading = false
    @State private var errorMessage: String?

    private let maxPhotos = 6
    private let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Text("Add more photos?")
                .font(.title.bold())

            Text("Profiles with more photos get more matches. Optional — you can always add more later.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)

            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(photos) { photo in
                    Color.clear
                        .aspectRatio(1, contentMode: .fit)
                        .overlay {
                            AsyncImage(url: APIService.shared.imageURL(for: photo.thumbnailUrl ?? photo.url)) { image in
                                image.resizable().scaledToFill()
                            } placeholder: {
                                Rectangle().fill(Color.lumenSurfaceStrong)
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                if photos.count < maxPhotos {
                    PhotosPicker(selection: $pickerItem, matching: .images) {
                        Color.clear
                            .aspectRatio(1, contentMode: .fit)
                            .overlay {
                                if isUploading {
                                    ProgressView()
                                } else {
                                    Image(systemName: "plus.circle.fill")
                                        .font(.title2)
                                        .foregroundColor(.pink)
                                }
                            }
                            .background(Color.lumenSurface)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(LumenPressableStyle())
                    .disabled(isUploading)
                }
            }
            .padding(.horizontal, 32)

            Text("\(photos.count) of \(maxPhotos) photos")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            Spacer()

            VStack(spacing: 12) {
                Button("Continue", action: onContinue)
                    .buttonStyle(LumenPrimaryButtonStyle())

                Button("Skip", action: onSkip)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .buttonStyle(LumenPressableStyle())
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 32)
        }
        .task {
            // The photo from the previous (required) step was uploaded directly via APIService,
            // not through authManager, so currentUser's photos are stale until refreshed here.
            await authManager.loadCurrentUser()
            photos = authManager.currentUser?.photos ?? []
        }
        .onChange(of: pickerItem) { _, newItem in
            Task { await load(newItem) }
        }
        .sheet(item: Binding(
            get: { imageToCrop.map { IdentifiableCropImage(image: $0) } },
            set: { imageToCrop = $0?.image }
        )) { wrapped in
            PhotoCropView(image: wrapped.image) { cropped in
                Task { await upload(cropped) }
            }
        }
    }

    private func load(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        errorMessage = nil

        guard let data = try? await item.loadTransferable(type: Data.self),
              let uiImage = UIImage(data: data) else {
            errorMessage = "Couldn't load that photo. Try another one."
            return
        }

        imageToCrop = uiImage
    }

    private func upload(_ image: UIImage) async {
        guard let jpegData = image.jpegData(compressionQuality: 0.85) else {
            errorMessage = "Couldn't process that photo. Try another one."
            return
        }

        errorMessage = nil
        isUploading = true
        defer { isUploading = false }

        do {
            let uploaded = try await APIService.shared.uploadPhoto(imageData: jpegData)
            photos.append(uploaded)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct IdentifiableCropImage: Identifiable {
    let id = UUID()
    let image: UIImage
}

/// Last onboarding step — asks for push permission here instead of waiting for a user's first
/// match (the previous, more conventional "ask contextually" approach). Product decision: every
/// permission the app ever needs should surface during onboarding, not be scattered across later
/// moments. `PushNotificationManager.requestPermissionIfNeeded()` is safe to call again from
/// DiscoveryView's first-match moment too (its own doc comment: only ever prompts once, silently
/// returns the existing decision after) — that call is left in place as the path for accounts
/// that onboarded before this step existed.
private struct NotificationsStepView: View {
    let onFinish: () -> Void
    let onSkip: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "bell.badge.fill")
                .resizable()
                .frame(width: 80, height: 80)
                .foregroundStyle(Theme.primaryGradient)

            Text("Stay in the loop")
                .font(.title.bold())

            Text("Get notified about new matches, messages, and likes. You can turn any of these off later in Settings.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)

            Spacer()

            VStack(spacing: 12) {
                Button {
                    PushNotificationManager.shared.requestPermissionIfNeeded()
                    onFinish()
                } label: {
                    Text("Enable Notifications")
                }
                .buttonStyle(LumenPrimaryButtonStyle())

                Button("Skip", action: onSkip)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .buttonStyle(LumenPressableStyle())
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 32)
        }
    }
}

#Preview {
    OnboardingView()
        .environmentObject(AuthenticationManager.shared)
}
