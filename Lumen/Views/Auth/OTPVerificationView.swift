import SwiftUI

struct OTPVerificationView: View {
    @EnvironmentObject var authManager: AuthenticationManager
    let email: String
    
    @State private var otpCode = ""
    @State private var showingError = false
    @State private var errorMessage = ""
    @State private var canResend = false
    @State private var resendTimer: Timer?
    @State private var resendCountdown = 60
    
    var body: some View {
        ZStack {
            Color.lumenBackground.ignoresSafeArea()

            VStack(spacing: 32) {
                LumenBackButton()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)

                VStack(spacing: 16) {
                    Image(systemName: "envelope.circle.fill")
                        .resizable()
                        .frame(width: 80, height: 80)
                        .foregroundStyle(Theme.primaryGradient)

                    Text("Verify Your Email")
                        .font(.title.bold())

                    Text("We sent a 6-digit code to\n\(email)")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }

                // OTP Input
                VStack(spacing: 16) {
                    TextField("Enter code", text: $otpCode)
                        .font(.system(size: 32, weight: .medium, design: .rounded))
                        .multilineTextAlignment(.center)
                        .keyboardType(.numberPad)
                        .textFieldStyle(.plain)
                        .padding()
                        .background(Color.lumenSurface)
                        .cornerRadius(Theme.Radius.small)
                        .onChange(of: otpCode) { _, newValue in
                            // Limit to 6 digits
                            if newValue.count > 6 {
                                otpCode = String(newValue.prefix(6))
                            }
                            // Auto-verify when 6 digits entered
                            if newValue.count == 6 {
                                Task {
                                    await verifyOTP()
                                }
                            }
                        }

                    // Resend button
                    if canResend {
                        Button("Resend Code") {
                            Task {
                                await resendCode()
                            }
                        }
                        .font(.subheadline)
                        .buttonStyle(LumenPressableStyle())
                    } else {
                        Text("Resend code in \(resendCountdown)s")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 32)

                // Verify Button
                Button {
                    Task {
                        await verifyOTP()
                    }
                } label: {
                    if authManager.isLoading {
                        ProgressView().tint(.white)
                    } else {
                        Text("Verify")
                    }
                }
                .buttonStyle(LumenPrimaryButtonStyle(isEnabled: otpCode.count == 6))
                .padding(.horizontal, 32)
                .disabled(otpCode.count != 6 || authManager.isLoading)

                Spacer()
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            startResendTimer()
        }
        .onDisappear {
            resendTimer?.invalidate()
        }
        .customAlert(isPresented: $showingError, title: "Error", message: errorMessage)
    }
    
    private func verifyOTP() async {
        let result = await authManager.verifyOTP(email: email, code: otpCode)
        
        switch result {
        case .success:
            // Auth manager will update isAuthenticated, causing view transition
            break
        case .failure(let error):
            errorMessage = error.localizedDescription
            showingError = true
            otpCode = ""
        }
    }
    
    private func resendCode() async {
        let result = await authManager.resendOTP(email: email)
        
        switch result {
        case .success:
            canResend = false
            resendCountdown = 60
            startResendTimer()
        case .failure(let error):
            errorMessage = error.localizedDescription
            showingError = true
        }
    }
    
    private func startResendTimer() {
        resendTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
            if resendCountdown > 0 {
                resendCountdown -= 1
            } else {
                canResend = true
                timer.invalidate()
            }
        }
    }
}

#Preview {
    NavigationStack {
        OTPVerificationView(email: "test@example.com")
            .environmentObject(AuthenticationManager.shared)
    }
}
