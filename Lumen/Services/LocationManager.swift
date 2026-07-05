import Foundation
import CoreLocation
import MapKit
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
                let city = try await reverseGeocodeCityDisplay(location)
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

    private func reverseGeocodeCityDisplay(_ location: CLLocation) async throws -> String {
        // CLGeocoder (and CLPlacemark's locality/administrativeArea fields) are deprecated as of
        // iOS 26 in favor of MapKit's own request type — MKAddress only exposes a formatted
        // string (no separate city/state components anymore), hence returning a display string
        // directly here rather than a placemark-like structured value. Keeping the CLGeocoder
        // path for older OS versions this app might still run on rather than dropping support.
        if #available(iOS 26.0, *) {
            guard let request = MKReverseGeocodingRequest(location: location) else {
                throw APIError.serverError("Reverse geocoding request already in progress")
            }
            guard let mapItem = try await request.mapItems.first else {
                throw APIError.serverError("No address found")
            }
            // Deliberately not `address.shortAddress`/`.fullAddress` — both are full street-level
            // strings (e.g. "1 Apple Park Way, Cupertino, CA"), which is exactly the exact-address
            // leak this app promises never to show (see the location step's own on-screen copy:
            // "we only ever show your city and distance"). `addressRepresentations.cityName` is
            // the actual city-only field; `cityWithContext` (city + state, still no street) is the
            // fallback for the rarer case a location doesn't resolve to a named city.
            let representations = mapItem.addressRepresentations
            return representations?.cityName ?? representations?.cityWithContext ?? ""
        } else {
            let placemarks = try await CLGeocoder().reverseGeocodeLocation(location)
            guard let placemark = placemarks.first else {
                throw APIError.serverError("No placemark found")
            }
            return [placemark.locality, placemark.administrativeArea]
                .compactMap { $0 }
                .joined(separator: ", ")
        }
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
