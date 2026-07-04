import SwiftUI

// MARK: - Custom confirmation sheet (replaces .confirmationDialog)

struct CustomSheetAction: Identifiable {
    let id = UUID()
    let title: String
    var systemImage: String? = nil
    var isDestructive: Bool = false
    let action: () -> Void
}

private struct CustomConfirmationOverlay: View {
    let title: String
    var message: String? = nil
    let actions: [CustomSheetAction]
    var cancelTitle: String = "Cancel"
    @Binding var isPresented: Bool

    var body: some View {
        ZStack {
            if isPresented {
                Color.black.opacity(0.4)
                    .ignoresSafeArea()
                    .onTapGesture { isPresented = false }
                    .transition(.opacity)

                VStack(spacing: 8) {
                    Spacer()

                    VStack(spacing: 0) {
                        VStack(spacing: 4) {
                            Text(title)
                                .font(.footnote.weight(.semibold))
                            if let message {
                                Text(message)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                            }
                        }
                        .padding(.vertical, 14)
                        .padding(.horizontal, 20)
                        .frame(maxWidth: .infinity)

                        ForEach(actions) { action in
                            Divider()
                            Button {
                                isPresented = false
                                action.action()
                            } label: {
                                HStack(spacing: 6) {
                                    if let icon = action.systemImage {
                                        Image(systemName: icon)
                                    }
                                    Text(action.title)
                                }
                                .font(.body.weight(.medium))
                                .foregroundColor(action.isDestructive ? .red : .pink)
                                .frame(maxWidth: .infinity)
                                .frame(height: 52)
                            }
                        }
                    }
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 18))

                    Button {
                        isPresented = false
                    } label: {
                        Text(cancelTitle)
                            .font(.body.weight(.semibold))
                            .foregroundColor(.pink)
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .background(.regularMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 18))
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.86), value: isPresented)
    }
}

extension View {
    /// On-brand replacement for `.confirmationDialog` — same "bottom action sheet + separate
    /// cancel button" shape people already expect, just styled with our own rounding/colors
    /// instead of stock iOS chrome.
    func customConfirmation(
        isPresented: Binding<Bool>,
        title: String,
        message: String? = nil,
        cancelTitle: String = "Cancel",
        actions: [CustomSheetAction]
    ) -> some View {
        self.overlay {
            CustomConfirmationOverlay(
                title: title,
                message: message,
                actions: actions,
                cancelTitle: cancelTitle,
                isPresented: isPresented
            )
        }
    }
}

// MARK: - Custom alert (replaces single-message .alert)

private struct CustomAlertOverlay: View {
    let title: String
    let message: String
    var buttonTitle: String
    @Binding var isPresented: Bool
    var onDismiss: (() -> Void)?

    var body: some View {
        ZStack {
            if isPresented {
                Color.black.opacity(0.4)
                    .ignoresSafeArea()
                    .transition(.opacity)

                VStack(spacing: 0) {
                    VStack(spacing: 8) {
                        Text(title)
                            .font(.headline)
                        Text(message)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 22)
                    .padding(.horizontal, 22)
                    .padding(.bottom, 18)

                    Divider()

                    Button {
                        isPresented = false
                        onDismiss?()
                    } label: {
                        Text(buttonTitle)
                            .font(.body.weight(.semibold))
                            .foregroundColor(.pink)
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                    }
                }
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .frame(maxWidth: 300)
                .transition(.scale(scale: 0.92).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.82), value: isPresented)
    }
}

extension View {
    /// On-brand replacement for a single-message `.alert(...)`.
    func customAlert(
        isPresented: Binding<Bool>,
        title: String,
        message: String,
        buttonTitle: String = "OK",
        onDismiss: (() -> Void)? = nil
    ) -> some View {
        self.overlay {
            CustomAlertOverlay(
                title: title,
                message: message,
                buttonTitle: buttonTitle,
                isPresented: isPresented,
                onDismiss: onDismiss
            )
        }
    }
}
