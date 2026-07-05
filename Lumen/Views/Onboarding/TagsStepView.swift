import SwiftUI

struct TagsStepView: View {
    let onFinish: () -> Void
    let onSkip: () -> Void

    @State private var styleTags: [String] = []
    @State private var newTag = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Text("What's your style?")
                .font(.title.bold())

            Text("Add a few tags — soft goth, gamer girl, cottagecore, whatever fits.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)

            VStack(alignment: .leading, spacing: 12) {
                if !styleTags.isEmpty {
                    FlowLayout(spacing: 8) {
                        ForEach(styleTags, id: \.self) { tag in
                            HStack(spacing: 4) {
                                Text(tag)
                                Button {
                                    styleTags.removeAll { $0 == tag }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }
                            }
                            .font(.caption)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.pink.opacity(0.2))
                            .foregroundColor(.pink)
                            .cornerRadius(16)
                        }
                    }
                }

                HStack {
                    TextField("Add a tag", text: $newTag)
                        .textFieldStyle(LumenTextFieldStyle())
                        .onSubmit { addTag() }

                    Button {
                        addTag()
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .foregroundColor(.pink)
                    }
                    .buttonStyle(LumenPressableStyle())
                    .disabled(newTag.isEmpty || styleTags.count >= 10)
                }
            }
            .padding(.horizontal, 32)

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Spacer()

            VStack(spacing: 12) {
                Button {
                    Task { await save() }
                } label: {
                    if isSaving {
                        ProgressView().tint(.white)
                    } else {
                        Text("Finish")
                    }
                }
                .buttonStyle(LumenPrimaryButtonStyle())
                .disabled(isSaving)

                Button("Skip", action: onSkip)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .buttonStyle(LumenPressableStyle())
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 32)
        }
    }

    private func addTag() {
        let trimmed = newTag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, styleTags.count < 10, !styleTags.contains(trimmed) else { return }
        styleTags.append(trimmed)
        newTag = ""
    }

    private func save() async {
        guard !styleTags.isEmpty else {
            onFinish()
            return
        }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        do {
            try await APIService.shared.updateProfile(update: ProfileUpdate(
                bio: nil,
                pronouns: nil,
                styleTags: styleTags,
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
                discoverable: nil
            ))
            onFinish()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

#Preview {
    TagsStepView(onFinish: {}, onSkip: {})
}
