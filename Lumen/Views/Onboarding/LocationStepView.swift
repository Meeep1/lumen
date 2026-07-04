import SwiftUI
import CoreLocation

struct LocationStepView: View {
    let onContinue: () -> Void

    @StateObject private var locationManager = LocationManager.shared
    @State private var isSaving = false
    @State private var saveError: String?

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "location.circle.fill")
                .resizable()
                .frame(width: 80, height: 80)
                .foregroundStyle(.pink.gradient)

            Text("Where are you?")
                .font(.title.bold())

            Text("Lumen uses your location to show you people nearby. We only ever show your city and distance to others — never your exact location.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)

            if let city = locationManager.resolvedLocation?.cityDisplay {
                Label(city, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }

            if let error = locationManager.errorMessage ?? saveError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                if locationManager.authorizationStatus == .denied {
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                    .font(.subheadline)
                }
            }

            Spacer()

            Button {
                if locationManager.resolvedLocation != nil {
                    Task { await save() }
                } else {
                    locationManager.requestLocation()
                }
            } label: {
                if locationManager.isResolving || isSaving {
                    ProgressView().tint(.white).frame(maxWidth: .infinity).frame(height: 56)
                } else {
                    Text(locationManager.resolvedLocation != nil ? "Continue" : "Enable Location")
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                }
            }
            .background(Color.pink.gradient)
            .cornerRadius(16)
            .padding(.horizontal, 32)
            .disabled(locationManager.isResolving || isSaving)
            .padding(.bottom, 32)
        }
        .onChange(of: locationManager.resolvedLocation?.cityDisplay) { _, newValue in
            guard newValue != nil else { return }
            Task { await save() }
        }
    }

    private func save() async {
        guard let resolved = locationManager.resolvedLocation else { return }
        isSaving = true
        saveError = nil
        defer { isSaving = false }

        do {
            try await APIService.shared.updateProfile(update: ProfileUpdate(
                bio: nil,
                pronouns: nil,
                styleTags: nil,
                heightInches: nil,
                jobTitle: nil,
                school: nil,
                prompt1Question: nil,
                prompt1Answer: nil,
                prompt2Question: nil,
                prompt2Answer: nil,
                latitude: resolved.latitude,
                longitude: resolved.longitude,
                cityDisplay: resolved.cityDisplay,
                discoverable: nil
            ))
            onContinue()
        } catch {
            saveError = error.localizedDescription
        }
    }
}

#Preview {
    LocationStepView(onContinue: {})
}
