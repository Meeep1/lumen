import SwiftUI

/// Post-signup, pre-discovery flow (app_spec.md Section 3.2a). Location and one photo are
/// mandatory since Discovery can't function without them; the rest is skippable and editable
/// later from Settings.
struct OnboardingView: View {
    @EnvironmentObject var authManager: AuthenticationManager
    var onFinish: () -> Void = {}

    private enum Step: Int, CaseIterable {
        case location, photo, about, height, details, prompts, tags
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

#Preview {
    OnboardingView()
        .environmentObject(AuthenticationManager.shared)
}
