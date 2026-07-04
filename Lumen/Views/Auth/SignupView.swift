import SwiftUI

struct SignupView: View {
    @EnvironmentObject var authManager: AuthenticationManager
    @Environment(\.dismiss) var dismiss

    /// Non-nil only when arriving from Sign in with Apple for a brand-new identity — the
    /// password step is skipped entirely (Apple's token is re-verified server-side and *is*
    /// the authentication for this account), everything else still applies the same.
    var appleIdentityToken: String? = nil

    @State private var email = ""
    @State private var phone = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    // Defaults to 25 years ago, safely inside minDate...maxDate below — defaulting to Date()
    // (today) silently produced an under-18 submission whenever someone didn't touch the
    // picker, which the server correctly rejected but with no client-side hint why.
    @State private var dateOfBirth = Calendar.current.date(byAdding: .year, value: -25, to: Date())!
    @State private var selectedGenderIdentity: GenderIdentity = .woman
    @State private var genderIdentityOther = ""
    @State private var femAttestationAccepted = false
    @State private var showingOTPVerification = false
    @State private var showingError = false
    @State private var errorMessage = ""
    
    private let maxDate = Calendar.current.date(byAdding: .year, value: -18, to: Date())!
    private let minDate = Calendar.current.date(byAdding: .year, value: -100, to: Date())!

    init(appleIdentityToken: String? = nil, prefillEmail: String? = nil) {
        self.appleIdentityToken = appleIdentityToken
        _email = State(initialValue: prefillEmail ?? "")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Create Account")
                    .font(.largeTitle.bold())
                    .padding(.bottom, 8)
                
                // Email
                VStack(alignment: .leading, spacing: 8) {
                    Text("Email")
                        .font(.subheadline.weight(.medium))
                    TextField("email@example.com", text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .autocapitalization(.none)
                        .textFieldStyle(.roundedBorder)
                }
                
                // Phone
                VStack(alignment: .leading, spacing: 8) {
                    Text("Phone Number")
                        .font(.subheadline.weight(.medium))
                    TextField("+1 (555) 555-5555", text: $phone)
                        .textContentType(.telephoneNumber)
                        .keyboardType(.phonePad)
                        .textFieldStyle(.roundedBorder)
                }
                
                // Password — skipped entirely when signing up via Apple, which has no
                // password at all (its identity token is re-verified server-side instead).
                if appleIdentityToken == nil {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Password")
                            .font(.subheadline.weight(.medium))
                        SecureField("At least 8 characters", text: $password)
                            .textContentType(.newPassword)
                            .textFieldStyle(.roundedBorder)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Confirm Password")
                            .font(.subheadline.weight(.medium))
                        SecureField("Confirm password", text: $confirmPassword)
                            .textContentType(.newPassword)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                
                // Date of Birth
                VStack(alignment: .leading, spacing: 8) {
                    Text("Date of Birth (Must be 18+)")
                        .font(.subheadline.weight(.medium))
                    DatePicker(
                        "Date of Birth",
                        selection: $dateOfBirth,
                        in: minDate...maxDate,
                        displayedComponents: .date
                    )
                    .labelsHidden()
                    .datePickerStyle(.compact)
                }
                
                // Gender Identity
                VStack(alignment: .leading, spacing: 8) {
                    Text("Gender Identity")
                        .font(.subheadline.weight(.medium))
                    
                    Picker("Gender Identity", selection: $selectedGenderIdentity) {
                        ForEach(GenderIdentity.allCases, id: \.self) { identity in
                            Text(identity.displayName).tag(identity)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(.pink)
                    
                    if selectedGenderIdentity == .other {
                        TextField("Please specify", text: $genderIdentityOther)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                
                // Fem Attestation
                VStack(alignment: .leading, spacing: 12) {
                    Toggle(isOn: $femAttestationAccepted) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("I confirm that I identify as feminine or present as feminine")
                                .font(.subheadline)
                            Text("This app is exclusively for feminine-presenting people")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tint(.pink)
                }
                .padding()
                .background(Color(uiColor: .systemGray6))
                .cornerRadius(12)
                
                // Create Account Button
                Button {
                    Task {
                        await createAccount()
                    }
                } label: {
                    if authManager.isLoading {
                        ProgressView()
                            .tint(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 56)
                    } else {
                        Text("Create Account")
                            .font(.headline)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 56)
                    }
                }
                .background(isFormValid ? Color.pink.gradient : Color.gray.gradient)
                .cornerRadius(16)
                .disabled(!isFormValid || authManager.isLoading)
                
                // Terms text
                Text("By creating an account, you agree to our Terms of Service and Privacy Policy")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
            .padding()
        }
        .navigationDestination(isPresented: $showingOTPVerification) {
            OTPVerificationView(phone: phone)
        }
        .alert("Error", isPresented: $showingError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
    }
    
    private var isFormValid: Bool {
        !email.isEmpty &&
        email.contains("@") &&
        !phone.isEmpty &&
        (appleIdentityToken != nil || (password.count >= 8 && password == confirmPassword)) &&
        dateOfBirth <= maxDate &&
        (selectedGenderIdentity != .other || !genderIdentityOther.isEmpty) &&
        femAttestationAccepted
    }

    private func createAccount() async {
        let result = await authManager.signup(
            email: email,
            phone: phone,
            password: appleIdentityToken == nil ? password : nil,
            appleIdentityToken: appleIdentityToken,
            dateOfBirth: dateOfBirth,
            genderIdentity: selectedGenderIdentity,
            genderIdentityOther: selectedGenderIdentity == .other ? genderIdentityOther : nil,
            femAttestationAccepted: femAttestationAccepted
        )
        
        switch result {
        case .success:
            showingOTPVerification = true
        case .failure(let error):
            errorMessage = error.localizedDescription
            showingError = true
        }
    }
}

#Preview {
    NavigationStack {
        SignupView()
            .environmentObject(AuthenticationManager.shared)
    }
}
