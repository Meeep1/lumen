import SwiftUI

struct AboutStepView: View {
    let onContinue: () -> Void
    let onSkip: () -> Void

    @State private var bio = ""
    @State private var pronouns = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Text("Tell people about you")
                .font(.title.bold())
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Bio").font(.subheadline.weight(.medium))
                    TextField("A little about you", text: $bio, axis: .vertical)
                        .lineLimit(4...8)
                        .textFieldStyle(LumenTextFieldStyle())
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Pronouns").font(.subheadline.weight(.medium))
                    TextField("e.g. she/her, they/them", text: $pronouns)
                        .textFieldStyle(LumenTextFieldStyle())
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
                        Text("Continue")
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

    private func save() async {
        guard !bio.isEmpty || !pronouns.isEmpty else {
            onContinue()
            return
        }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        do {
            try await APIService.shared.updateProfile(update: ProfileUpdate(
                bio: bio.isEmpty ? nil : bio,
                pronouns: pronouns.isEmpty ? nil : pronouns,
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
                discoverable: nil
            ))
            onContinue()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

#Preview {
    AboutStepView(onContinue: {}, onSkip: {})
}
