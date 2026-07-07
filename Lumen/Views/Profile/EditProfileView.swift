import SwiftUI

struct EditProfileView: View {
    @EnvironmentObject var authManager: AuthenticationManager
    @Environment(\.dismiss) var dismiss

    @State private var genderIdentity: GenderIdentity = .woman
    @State private var genderIdentityOther = ""
    @State private var bio = ""
    @State private var pronouns = ""
    @State private var styleTags: [String] = []
    @State private var newTag = ""
    @State private var feet = 5
    @State private var inches = 5
    @State private var jobTitle = ""
    @State private var school = ""
    @State private var prompt1Question: PromptQuestion = .randomFact
    @State private var prompt1Answer = ""
    @State private var prompt2Question: PromptQuestion = .idealSunday
    @State private var prompt2Answer = ""
    @State private var prompt3Question: PromptQuestion = .winMeOver
    @State private var prompt3Answer = ""
    @State private var isSaving = false
    @State private var showingError = false
    @State private var errorMessage = ""

    var body: some View {
        NavigationStack {
        ZStack {
            Color.lumenBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                LumenHeader(title: "Edit Profile", leading: {
                    LumenHeaderTextButton(title: "Cancel") { dismiss() }
                }, trailing: {
                    LumenHeaderTextButton(title: "Save", isDisabled: isSaving) {
                        Task { await saveProfile() }
                    }
                })

                ScrollView {
                    VStack(spacing: 20) {
                        SettingsSection(title: "Gender Identity") {
                            SettingsCard {
                                VStack(alignment: .leading, spacing: 8) {
                                    LumenSelectField(
                                        title: "Gender Identity",
                                        options: GenderIdentity.allCases,
                                        label: { $0.displayName },
                                        selection: $genderIdentity
                                    )

                                    if genderIdentity == .other {
                                        TextField("Please specify", text: $genderIdentityOther)
                                            .textFieldStyle(LumenTextFieldStyle())
                                    }
                                }
                                .padding(16)
                            }
                        }

                        SettingsSection(title: "About") {
                            SettingsCard {
                                VStack(alignment: .leading, spacing: 12) {
                                    TextField("Bio", text: $bio, axis: .vertical)
                                        .lineLimit(5...10)
                                    Divider()
                                    TextField("Pronouns (e.g., she/her)", text: $pronouns)
                                }
                                .padding(16)
                            }
                        }

                        SettingsSection(title: "Details") {
                            SettingsCard {
                                VStack(alignment: .leading, spacing: 12) {
                                    TextField("Job title", text: $jobTitle)
                                    Divider()
                                    TextField("School", text: $school)
                                }
                                .padding(16)
                            }
                        }

                        SettingsSection(title: "Height") {
                            SettingsCard {
                                HStack {
                                    Picker("Feet", selection: $feet) {
                                        ForEach(4...7, id: \.self) { ft in
                                            Text("\(ft) ft").tag(ft)
                                        }
                                    }
                                    .pickerStyle(.wheel)

                                    Picker("Inches", selection: $inches) {
                                        ForEach(0...11, id: \.self) { inch in
                                            Text("\(inch) in").tag(inch)
                                        }
                                    }
                                    .pickerStyle(.wheel)
                                }
                                .tint(.pink)
                                .frame(height: 120)
                            }
                        }

                        SettingsSection(title: "Prompts") {
                            VStack(spacing: 12) {
                                promptEditor(question: $prompt1Question, answer: $prompt1Answer)
                                promptEditor(question: $prompt2Question, answer: $prompt2Answer)
                                promptEditor(question: $prompt3Question, answer: $prompt3Answer)
                            }
                        }

                        SettingsSection(title: "Style Tags") {
                            SettingsCard {
                                VStack(alignment: .leading, spacing: 12) {
                                    ForEach(styleTags, id: \.self) { tag in
                                        HStack {
                                            Text(tag)
                                            Spacer()
                                            Button {
                                                styleTags.removeAll { $0 == tag }
                                            } label: {
                                                Image(systemName: "minus.circle.fill")
                                                    .foregroundColor(.red)
                                            }
                                            .buttonStyle(LumenPressableStyle())
                                        }
                                    }

                                    HStack {
                                        TextField("Add a tag", text: $newTag)
                                            .textFieldStyle(LumenTextFieldStyle())
                                            .onSubmit {
                                                addTag()
                                            }

                                        Button {
                                            addTag()
                                        } label: {
                                            Image(systemName: "plus.circle.fill")
                                                .foregroundColor(.pink)
                                        }
                                        .buttonStyle(LumenPressableStyle())
                                        .disabled(newTag.isEmpty || styleTags.count >= 10)
                                    }

                                    Text("Add up to 10 tags that describe your style or vibe")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(16)
                            }
                        }
                    }
                    .padding()
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            loadCurrentProfile()
        }
        .customAlert(isPresented: $showingError, title: "Error", message: errorMessage)
        }
    }

    private func promptEditor(question: Binding<PromptQuestion>, answer: Binding<String>) -> some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 8) {
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
            .padding(16)
        }
    }

    private func loadCurrentProfile() {
        guard let user = authManager.currentUser else { return }

        genderIdentity = user.genderIdentity
        genderIdentityOther = user.genderIdentityOther ?? ""
        bio = user.bio ?? ""
        pronouns = user.pronouns ?? ""
        styleTags = user.styleTags
        jobTitle = user.jobTitle ?? ""
        school = user.school ?? ""
        if let heightInches = user.heightInches {
            feet = heightInches / 12
            inches = heightInches % 12
        }
        if let q = user.prompt1Question, let pq = PromptQuestion(rawValue: q) {
            prompt1Question = pq
            prompt1Answer = user.prompt1Answer ?? ""
        }
        if let q = user.prompt2Question, let pq = PromptQuestion(rawValue: q) {
            prompt2Question = pq
            prompt2Answer = user.prompt2Answer ?? ""
        }
        if let q = user.prompt3Question, let pq = PromptQuestion(rawValue: q) {
            prompt3Question = pq
            prompt3Answer = user.prompt3Answer ?? ""
        }
    }

    private func addTag() {
        let trimmed = newTag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, styleTags.count < 10, !styleTags.contains(trimmed) else { return }

        styleTags.append(trimmed)
        newTag = ""
    }

    private func saveProfile() async {
        isSaving = true
        defer { isSaving = false }

        let update = ProfileUpdate(
            genderIdentity: genderIdentity,
            genderIdentityOther: genderIdentity == .other ? (genderIdentityOther.isEmpty ? nil : genderIdentityOther) : nil,
            bio: bio.isEmpty ? nil : bio,
            pronouns: pronouns.isEmpty ? nil : pronouns,
            styleTags: styleTags,
            heightInches: feet * 12 + inches,
            jobTitle: jobTitle.isEmpty ? nil : jobTitle,
            school: school.isEmpty ? nil : school,
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
        )

        let result = await authManager.updateProfile(update)

        switch result {
        case .success:
            dismiss()
        case .failure(let error):
            errorMessage = error.localizedDescription
            showingError = true
        }
    }
}

#Preview {
    EditProfileView()
        .environmentObject(AuthenticationManager.shared)
}
