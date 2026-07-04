import SwiftUI

/// Detail sheet for a single incoming like — shows what they liked (with their comment, if any)
/// and lets you like or pass back. Liking back always creates a match (they already liked you).
struct LikeResponseView: View {
    let like: LikeReceived
    let onResponded: () -> Void

    @Environment(\.dismiss) var dismiss
    @State private var isResponding = false
    @State private var errorMessage: String?
    @State private var matched = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    AsyncImage(url: APIService.shared.imageURL(for: like.primaryPhoto)) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Rectangle()
                            .fill(LinearGradient(
                                colors: [.pink.opacity(0.3), .purple.opacity(0.3)],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            ))
                    }
                    .frame(height: 360)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                    .padding(.horizontal)

                    if like.likedPhotoUrl != nil || like.likedPromptQuestion != nil || like.message != nil {
                        likeContextCard
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("\(like.age)")
                                .font(.title.bold())
                            if like.isVerified {
                                Image(systemName: "checkmark.seal.fill")
                                    .foregroundColor(.blue)
                            }
                        }
                        if let bio = like.bio, !bio.isEmpty {
                            Text(bio)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)

                    if let errorMessage {
                        Text(errorMessage).foregroundStyle(.red).font(.caption)
                    }
                }
                .padding(.bottom, 100)
            }
            .background(Color.lumenBackground)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                responseButtons
            }
            .overlay {
                if matched {
                    matchOverlay
                }
            }
        }
    }

    private var likeContextCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let question = like.likedPromptQuestion, let answer = like.likedPromptAnswer {
                Text(question)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(answer)
                    .font(.title3.weight(.medium))
            } else if like.likedPhotoUrl != nil {
                Label("Liked this photo", systemImage: "photo.fill")
                    .font(.subheadline.weight(.semibold))
            }

            if let message = like.message, !message.isEmpty {
                Text("\u{201C}\(message)\u{201D}")
                    .font(.body.italic())
                    .padding(.top, like.likedPromptQuestion != nil || like.likedPhotoUrl != nil ? 4 : 0)
            }
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
        .padding(.horizontal)
    }

    private var responseButtons: some View {
        HStack(spacing: 24) {
            Button {
                Task { await respond(.pass) }
            } label: {
                Image(systemName: "xmark")
                    .font(.title2.weight(.bold))
                    .foregroundColor(.red)
                    .frame(width: 56, height: 56)
                    .background(.ultraThinMaterial, in: Circle())
            }

            Button {
                Task { await respond(.like) }
            } label: {
                Image(systemName: "heart.fill")
                    .font(.title2.weight(.bold))
                    .foregroundColor(.white)
                    .frame(width: 64, height: 64)
                    .background(Color.pink.gradient, in: Circle())
            }
        }
        .disabled(isResponding)
        .padding()
        .background(.ultraThinMaterial)
    }

    private var matchOverlay: some View {
        ZStack {
            Color.black.opacity(0.8).ignoresSafeArea()
            VStack(spacing: 16) {
                Text("It's a Match!")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                Text("Say hi from the Matches tab.")
                    .foregroundColor(.white.opacity(0.85))
                Button("Done") {
                    onResponded()
                    dismiss()
                }
                .font(.headline)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .background(Color.pink.gradient)
                .cornerRadius(16)
                .padding(.horizontal, 40)
                .padding(.top, 8)
            }
        }
    }

    private func respond(_ direction: SwipeDirection) async {
        isResponding = true
        errorMessage = nil
        defer { isResponding = false }

        do {
            let result = try await APIService.shared.swipe(action: SwipeAction(
                swipedId: like.id,
                direction: direction,
                likedPhotoId: nil,
                likedPromptNumber: nil,
                message: nil
            ))
            if result.matched {
                matched = true
            } else {
                onResponded()
                dismiss()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

#Preview {
    LikeResponseView(like: LikeReceived(
        id: "preview", age: 25, genderIdentity: .woman, genderIdentityOther: nil,
        bio: "Preview bio", pronouns: "she/her", styleTags: [], heightInches: nil,
        jobTitle: nil, school: nil, prompt1Question: nil, prompt1Answer: nil,
        prompt2Question: nil, prompt2Answer: nil, cityDisplay: nil, isVerified: false,
        distance: 3, primaryPhoto: nil, likedPhotoUrl: nil, likedPromptQuestion: nil,
        likedPromptAnswer: nil, message: nil, likedAt: Date()
    ), onResponded: {})
}
