import SwiftUI

struct FilterSheet: View {
    @Binding var filters: DiscoveryFilters
    let onApply: () -> Void
    @Environment(\.dismiss) var dismiss
    
    @State private var minAge: Double = 18
    @State private var maxAge: Double = 100
    @State private var maxDistance: Double = 50
    @State private var minHeight: Double = 48
    @State private var maxHeight: Double = 96
    @State private var verifiedOnly = false
    @State private var selectedGenderIdentities: Set<String> = []

    var body: some View {
        ZStack {
            Color.lumenBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                LumenHeader(title: "Filters", leading: {
                    LumenHeaderTextButton(title: "Cancel") { dismiss() }
                }, trailing: {
                    LumenHeaderTextButton(title: "Apply") {
                        applyFilters()
                        onApply()
                        dismiss()
                    }
                })

                ScrollView {
                    VStack(spacing: 20) {
                        SettingsSection(title: "Age Range") {
                            SettingsCard {
                                VStack(spacing: 16) {
                                    HStack {
                                        Text("Min: \(Int(minAge))")
                                        Spacer()
                                        Text("Max: \(Int(maxAge))")
                                    }
                                    .font(.subheadline)

                                    RangeSlider(minValue: $minAge, maxValue: $maxAge, bounds: 18...100)
                                }
                                .padding(16)
                            }
                        }

                        SettingsSection(title: "Distance") {
                            SettingsCard {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Max: \(Int(maxDistance)) miles")
                                        .font(.subheadline)
                                    Slider(value: $maxDistance, in: 1...500, step: 1)
                                        .tint(.pink)
                                }
                                .padding(16)
                            }
                        }

                        SettingsSection(title: "Height Range") {
                            SettingsCard {
                                VStack(spacing: 16) {
                                    HStack {
                                        Text("Min: \(heightLabel(minHeight))")
                                        Spacer()
                                        Text("Max: \(heightLabel(maxHeight))")
                                    }
                                    .font(.subheadline)

                                    RangeSlider(minValue: $minHeight, maxValue: $maxHeight, bounds: 48...96)
                                }
                                .padding(16)
                            }
                        }

                        SettingsSection(title: "Gender Identity") {
                            SettingsCard {
                                ForEach(Array(GenderIdentity.allCases.enumerated()), id: \.element) { index, identity in
                                    if index > 0 {
                                        Divider().padding(.leading, 16)
                                    }
                                    Toggle(identity.displayName, isOn: Binding(
                                        get: { selectedGenderIdentities.contains(identity.rawValue) },
                                        set: { isOn in
                                            if isOn {
                                                selectedGenderIdentities.insert(identity.rawValue)
                                            } else {
                                                selectedGenderIdentities.remove(identity.rawValue)
                                            }
                                        }
                                    ))
                                    .tint(.pink)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 12)
                                }
                            }
                        }

                        SettingsCard {
                            Toggle("Verified profiles only", isOn: $verifiedOnly)
                                .tint(.pink)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
                        }

                        Button("Reset to Defaults") {
                            resetFilters()
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.red)
                        .buttonStyle(LumenPressableStyle())
                    }
                    .padding()
                }
            }
        }
        .onAppear {
            loadCurrentFilters()
        }
    }
    
    private func loadCurrentFilters() {
        minAge = Double(filters.minAge ?? 18)
        maxAge = Double(filters.maxAge ?? 100)
        maxDistance = Double(filters.maxDistance ?? 50)
        minHeight = Double(filters.minHeightInches ?? 48)
        maxHeight = Double(filters.maxHeightInches ?? 96)
        verifiedOnly = filters.verifiedOnly ?? false
        selectedGenderIdentities = Set(filters.genderIdentities ?? [])
    }

    private func applyFilters() {
        filters.minAge = Int(minAge)
        filters.maxAge = Int(maxAge)
        filters.maxDistance = Int(maxDistance)
        filters.minHeightInches = Int(minHeight) == 48 ? nil : Int(minHeight)
        filters.maxHeightInches = Int(maxHeight) == 96 ? nil : Int(maxHeight)
        filters.verifiedOnly = verifiedOnly ? true : nil
        filters.genderIdentities = selectedGenderIdentities.isEmpty ? nil : Array(selectedGenderIdentities)
    }

    private func resetFilters() {
        minAge = 18
        maxAge = 100
        maxDistance = 50
        minHeight = 48
        maxHeight = 96
        verifiedOnly = false
        selectedGenderIdentities = []
    }

    private func heightLabel(_ inches: Double) -> String {
        let total = Int(inches)
        return "\(total / 12)'\(total % 12)\""
    }
}

// Simple range slider implementation
struct RangeSlider: View {
    @Binding var minValue: Double
    @Binding var maxValue: Double
    let bounds: ClosedRange<Double>
    
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                // Track
                Rectangle()
                    .fill(Color.gray.opacity(0.3))
                    .frame(height: 4)
                
                // Active range
                Rectangle()
                    .fill(Color.pink)
                    .frame(
                        width: (maxValue - minValue) / (bounds.upperBound - bounds.lowerBound) * geometry.size.width,
                        height: 4
                    )
                    .offset(x: (minValue - bounds.lowerBound) / (bounds.upperBound - bounds.lowerBound) * geometry.size.width)
                
                // Min thumb
                Circle()
                    .fill(Color.white)
                    .frame(width: 28, height: 28)
                    .shadow(radius: 2)
                    .offset(x: (minValue - bounds.lowerBound) / (bounds.upperBound - bounds.lowerBound) * geometry.size.width - 14)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                let newValue = bounds.lowerBound + (value.location.x / geometry.size.width) * (bounds.upperBound - bounds.lowerBound)
                                minValue = min(max(newValue, bounds.lowerBound), maxValue - 1)
                            }
                    )
                
                // Max thumb
                Circle()
                    .fill(Color.white)
                    .frame(width: 28, height: 28)
                    .shadow(radius: 2)
                    .offset(x: (maxValue - bounds.lowerBound) / (bounds.upperBound - bounds.lowerBound) * geometry.size.width - 14)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                let newValue = bounds.lowerBound + (value.location.x / geometry.size.width) * (bounds.upperBound - bounds.lowerBound)
                                maxValue = max(min(newValue, bounds.upperBound), minValue + 1)
                            }
                    )
            }
        }
        .frame(height: 28)
    }
}
