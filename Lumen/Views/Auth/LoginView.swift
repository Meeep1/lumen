import SwiftUI

struct LoginView: View {
    @EnvironmentObject var authManager: AuthenticationManager
    @Environment(\.dismiss) var dismiss
    
    @State private var email = ""
    @State private var password = ""
    @State private var showingError = false
    @State private var errorMessage = ""
    
    var body: some View {
        ZStack {
            Color.lumenBackground.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 24) {
                    LumenBackButton()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 8)

                    VStack(spacing: 16) {
                        Image(systemName: "heart.circle.fill")
                            .resizable()
                            .frame(width: 80, height: 80)
                            .foregroundStyle(Theme.primaryGradient)

                        Text("Welcome Back")
                            .font(.largeTitle.bold())
                    }

                    VStack(spacing: 20) {
                        // Email
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Email")
                                .font(.subheadline.weight(.medium))
                            TextField("email@example.com", text: $email)
                                .textContentType(.emailAddress)
                                .keyboardType(.emailAddress)
                                .autocapitalization(.none)
                                .textFieldStyle(LumenTextFieldStyle())
                        }

                        // Password
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Password")
                                .font(.subheadline.weight(.medium))
                            SecureField("Enter your password", text: $password)
                                .textContentType(.password)
                                .textFieldStyle(LumenTextFieldStyle())
                        }

                        // Login Button
                        Button {
                            Task {
                                await login()
                            }
                        } label: {
                            if authManager.isLoading {
                                ProgressView().tint(.white)
                            } else {
                                Text("Log In")
                            }
                        }
                        .buttonStyle(LumenPrimaryButtonStyle(isEnabled: isFormValid))
                        .disabled(!isFormValid || authManager.isLoading)
                    }
                    .padding(.horizontal, 32)
                    .padding(.top, 16)

                    Spacer()
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .customAlert(isPresented: $showingError, title: "Error", message: errorMessage)
    }
    
    private var isFormValid: Bool {
        !email.isEmpty && email.contains("@") && !password.isEmpty
    }
    
    private func login() async {
        let result = await authManager.login(email: email, password: password)
        
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
    NavigationStack {
        LoginView()
            .environmentObject(AuthenticationManager.shared)
    }
}
