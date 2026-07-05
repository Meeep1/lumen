import SwiftUI

struct DetailsStepView: View {
    let onContinue: () -> Void
    let onSkip: () -> Void

    @State private var jobTitle = ""
    @State private var school = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Text("What do you do?")
                .font(.title.bold())

            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Job Title").font(.subheadline.weight(.medium))
                    TextField("e.g. Photographer", text: $jobTitle)
                        .textFieldStyle(LumenTextFieldStyle())
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("School").font(.subheadline.weight(.medium))
                    TextField("e.g. NYU", text: $school)
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
        guard !jobTitle.isEmpty || !school.isEmpty else {
            onContinue()
            return
        }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        do {
            try await APIService.shared.updateProfile(update: ProfileUpdate(
                bio: nil,
                pronouns: nil,
                styleTags: nil,
                heightInches: nil,
                jobTitle: jobTitle.isEmpty ? nil : jobTitle,
                school: school.isEmpty ? nil : school,
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
    DetailsStepView(onContinue: {}, onSkip: {})
}
