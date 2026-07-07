import SwiftUI

/// Post-signup, pre-discovery flow (app_spec.md Section 3.2a). Location and one photo are
/// mandatory since Discovery can't function without them; the rest is skippable and editable
/// later from Settings.
struct OnboardingView: View {
    @EnvironmentObject var authManager: AuthenticationManager
    var onFinish: () -> Void = {}

    private enum Step: Int, CaseIterable {
        case location, photo, about, height, details, prompts, tags, notifications
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
                        TagsStepView(onFinish: { advance() }, onSkip: { advance() })
                    case .notifications:
                        NotificationsStepView(onFinish: { finish() }, onSkip: { finish() })
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

/// Last onboarding step — asks for push permission here instead of waiting for a user's first
/// match (the previous, more conventional "ask contextually" approach). Product decision: every
/// permission the app ever needs should surface during onboarding, not be scattered across later
/// moments. `PushNotificationManager.requestPermissionIfNeeded()` is safe to call again from
/// DiscoveryView's first-match moment too (its own doc comment: only ever prompts once, silently
/// returns the existing decision after) — that call is left in place as the path for accounts
/// that onboarded before this step existed.
private struct NotificationsStepView: View {
    let onFinish: () -> Void
    let onSkip: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "bell.badge.fill")
                .resizable()
                .frame(width: 80, height: 80)
                .foregroundStyle(Theme.primaryGradient)

            Text("Stay in the loop")
                .font(.title.bold())

            Text("Get notified about new matches, messages, and likes. You can turn any of these off later in Settings.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)

            Spacer()

            VStack(spacing: 12) {
                Button {
                    PushNotificationManager.shared.requestPermissionIfNeeded()
                    onFinish()
                } label: {
                    Text("Enable Notifications")
                }
                .buttonStyle(LumenPrimaryButtonStyle())

                Button("Skip", action: onSkip)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .buttonStyle(LumenPressableStyle())
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 32)
        }
    }
}

#Preview {
    OnboardingView()
        .environmentObject(AuthenticationManager.shared)
}
