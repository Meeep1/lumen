import SwiftUI

struct EditProfileView: View {
    @EnvironmentObject var authManager: AuthenticationManager
    @Environment(\.dismiss) var dismiss

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
    @State private var isSaving = false
    @State private var showingError = false
    @State private var errorMessage = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        ManagePhotosView()
                    } label: {
                        Label("Manage Photos", systemImage: "photo.on.rectangle.angled")
                    }
                }

                Section("About") {
                    TextField("Bio", text: $bio, axis: .vertical)
                        .lineLimit(5...10)

                    TextField("Pronouns (e.g., she/her)", text: $pronouns)
                }

                Section("Details") {
                    TextField("Job title", text: $jobTitle)
                    TextField("School", text: $school)
                }

                Section("Height") {
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
                    .frame(height: 120)
                }

                Section("Prompts") {
                    promptEditor(question: $prompt1Question, answer: $prompt1Answer)
                    promptEditor(question: $prompt2Question, answer: $prompt2Answer)
                }

                Section("Style Tags") {
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
                        }
                    }

                    HStack {
                        TextField("Add a tag", text: $newTag)
                            .onSubmit {
                                addTag()
                            }

                        Button {
                            addTag()
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .foregroundColor(.pink)
                        }
                        .disabled(newTag.isEmpty || styleTags.count >= 10)
                    }

                    Text("Add up to 10 tags that describe your style or vibe")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Edit Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            await saveProfile()
                        }
                    }
                    .fontWeight(.semibold)
                    .disabled(isSaving)
                }
            }
            .onAppear {
                loadCurrentProfile()
            }
            .alert("Error", isPresented: $showingError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage)
            }
        }
    }

    private func promptEditor(question: Binding<PromptQuestion>, answer: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Prompt", selection: question) {
                ForEach(PromptQuestion.allCases, id: \.self) { q in
                    Text(q.rawValue).tag(q)
                }
            }
            .pickerStyle(.menu)
            .tint(.pink)

            TextField("Your answer", text: answer, axis: .vertical)
                .lineLimit(2...4)
        }
        .padding(.vertical, 4)
    }

    private func loadCurrentProfile() {
        guard let user = authManager.currentUser else { return }

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
