import SwiftUI

struct HeightStepView: View {
    let onContinue: () -> Void
    let onSkip: () -> Void

    @State private var feet = 5
    @State private var inches = 5
    @State private var isSaving = false
    @State private var errorMessage: String?

    private let feetRange = Array(4...7)
    private let inchesRange = Array(0...11)

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Text("How tall are you?")
                .font(.title.bold())

            HStack(spacing: 0) {
                Picker("Feet", selection: $feet) {
                    ForEach(feetRange, id: \.self) { ft in
                        Text("\(ft) ft").tag(ft)
                    }
                }
                .pickerStyle(.wheel)

                Picker("Inches", selection: $inches) {
                    ForEach(inchesRange, id: \.self) { inch in
                        Text("\(inch) in").tag(inch)
                    }
                }
                .pickerStyle(.wheel)
            }
            .tint(.pink)
            .frame(height: 160)
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
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        do {
            try await APIService.shared.updateProfile(update: ProfileUpdate(
                bio: nil,
                pronouns: nil,
                styleTags: nil,
                heightInches: feet * 12 + inches,
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
    HeightStepView(onContinue: {}, onSkip: {})
}
