import SwiftUI

struct PromptsStepView: View {
    let onContinue: () -> Void
    let onSkip: () -> Void

    @State private var prompt1Question: PromptQuestion = .randomFact
    @State private var prompt1Answer = ""
    @State private var prompt2Question: PromptQuestion = .idealSunday
    @State private var prompt2Answer = ""
    @State private var prompt3Question: PromptQuestion = .winMeOver
    @State private var prompt3Answer = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Text("Add a couple prompts")
                    .font(.title.bold())
                    .padding(.top, 32)

                Text("Give people something to reply to.")
                    .foregroundStyle(.secondary)

                promptEditor(title: "Prompt 1", question: $prompt1Question, answer: $prompt1Answer)
                promptEditor(title: "Prompt 2", question: $prompt2Question, answer: $prompt2Answer)
                promptEditor(title: "Prompt 3", question: $prompt3Question, answer: $prompt3Answer)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

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
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
            .padding(.horizontal, 32)
        }
    }

    private func promptEditor(title: String, question: Binding<PromptQuestion>, answer: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.medium))

            LumenSelectField(
                title: "Prompt",
                options: PromptQuestion.allCases,
                label: { $0.rawValue },
                selection: question
            )

            TextField("Your answer", text: answer, axis: .vertical)
                .lineLimit(2...4)
                .textFieldStyle(LumenTextFieldStyle())
        }
        .padding()
        .background(Color.lumenCard)
        .cornerRadius(Theme.Radius.small)
    }

    private func save() async {
        guard !prompt1Answer.isEmpty || !prompt2Answer.isEmpty || !prompt3Answer.isEmpty else {
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
                jobTitle: nil,
                school: nil,
                prompt1Question: prompt1Answer.isEmpty ? nil : prompt1Question.rawValue,
                prompt1Answer: prompt1Answer.isEmpty ? nil : prompt1Answer,
                prompt2Question: prompt2Answer.isEmpty ? nil : prompt2Question.rawValue,
                prompt2Answer: prompt2Answer.isEmpty ? nil : prompt2Answer,
                prompt3Question: prompt3Answer.isEmpty ? nil : prompt3Question.rawValue,
                prompt3Answer: prompt3Answer.isEmpty ? nil : prompt3Answer,
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
    PromptsStepView(onContinue: {}, onSkip: {})
}
