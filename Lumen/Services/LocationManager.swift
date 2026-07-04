import Foundation
import CoreLocation
import Combine

@MainActor
class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = LocationManager()

    @Published var authorizationStatus: CLAuthorizationStatus
    @Published var isResolving = false
    @Published var errorMessage: String?

    /// Set once a location + reverse-geocoded city name are both ready.
    @Published var resolvedLocation: (latitude: Double, longitude: Double, cityDisplay: String)?

    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation, Error>?

    private override init() {
        authorizationStatus = CLLocationManager().authorizationStatus
        super.init()
        manager.delegate = self
    }

    func requestLocation() {
        errorMessage = nil

        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .restricted, .denied:
            errorMessage = "Location access is off. Enable it in Settings to continue."
        case .authorizedWhenInUse, .authorizedAlways:
            resolveCurrentLocation()
        @unknown default:
            break
        }
    }

    private func resolveCurrentLocation() {
        isResolving = true
        Task {
            do {
                let location = try await requestSingleLocation()
                let placemark = try await reverseGeocode(location)
                let city = [placemark.locality, placemark.administrativeArea]
                    .compactMap { $0 }
                    .joined(separator: ", ")
                resolvedLocation = (
                    latitude: location.coordinate.latitude,
                    longitude: location.coordinate.longitude,
                    cityDisplay: city.isEmpty ? "Unknown location" : city
                )
            } catch {
                errorMessage = "Couldn't determine your location. Try again."
            }
            isResolving = false
        }
    }

    private func requestSingleLocation() async throws -> CLLocation {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            manager.requestLocation()
        }
    }

    private func reverseGeocode(_ location: CLLocation) async throws -> CLPlacemark {
        let placemarks = try await CLGeocoder().reverseGeocodeLocation(location)
        guard let placemark = placemarks.first else {
            throw APIError.serverError("No placemark found")
        }
        return placemark
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            authorizationStatus = manager.authorizationStatus
            if manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways {
                resolveCurrentLocation()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in
            continuation?.resume(returning: location)
            continuation = nil
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }
}
