import SwiftUI

/// Post-signup, pre-discovery flow (app_spec.md Section 3.2a). Location and one photo are
/// mandatory since Discovery can't function without them; the rest is skippable and editable
/// later from Settings.
struct OnboardingView: View {
    @EnvironmentObject var authManager: AuthenticationManager

    private enum Step: Int, CaseIterable {
        case location, photo, about, height, details, prompts, tags
    }

    @State private var step: Step = .location

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ProgressView(value: Double(step.rawValue + 1), total: Double(Step.allCases.count))
                    .tint(.pink)
                    .padding(.horizontal)
                    .padding(.top)

                Group {
                    switch step {
                    case .location:
                        LocationStepView(onContinue: { advance() })
                    case .photo:
                        PhotoStepView(onContinue: { advance() })
                    case .about:
                        AboutStepView(onContinue: { advance() }, onSkip: { advance() })
                    case .height:
                        HeightStepView(onContinue: { advance() }, onSkip: { advance() })
                    case .details:
                        DetailsStepView(onContinue: { advance() }, onSkip: { advance() })
                    case .prompts:
                        PromptsStepView(onContinue: { advance() }, onSkip: { advance() })
                    case .tags:
                        TagsStepView(onFinish: { finish() }, onSkip: { finish() })
                    }
                }
                .frame(maxHeight: .infinity)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Location has no back button — behind it is just the auth flow, not a
                // meaningful "previous step."
                if step != .location {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            goBack()
                        } label: {
                            Image(systemName: "chevron.left")
                        }
                    }
                }
            }
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
        Task { await authManager.loadCurrentUser() }
    }
}

#Preview {
    OnboardingView()
        .environmentObject(AuthenticationManager.shared)
}
