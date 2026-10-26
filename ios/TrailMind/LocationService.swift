import CoreLocation
import Combine
import Foundation

final class LocationService: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var fix: CLLocation?
    @Published private(set) var heading: CLHeading?
    @Published private(set) var message = "Location has not been requested."
    private let manager = CLLocationManager()
    private var foreground = false
    private var requested = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
        manager.headingFilter = 1
    }

    func requestLocation() {
        requested = true
        manager.requestWhenInUseAuthorization()
        updateSession()
    }

    func setForeground(_ value: Bool) {
        foreground = value
        updateSession()
    }

    private func updateSession() {
        guard foreground && requested else {
            manager.stopUpdatingLocation()
            manager.stopUpdatingHeading()
            return
        }
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            message = manager.accuracyAuthorization == .fullAccuracy
                ? "Waiting for a position fix." : "Approximate location enabled. Enable Precise Location for navigation."
            manager.startUpdatingLocation()
            if CLLocationManager.headingAvailable() { manager.startUpdatingHeading() }
        case .denied, .restricted:
            manager.stopUpdatingLocation()
            manager.stopUpdatingHeading()
            fix = nil
            heading = nil
            message = "Location access is disabled. Change it in iPhone Settings."
        case .notDetermined:
            message = "Allow location access to see your position."
        @unknown default:
            message = "Location authorisation is unavailable."
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) { updateSession() }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let newest = locations.last(where: { $0.horizontalAccuracy >= 0 }) else { return }
        if let previous = fix, newest.timestamp < previous.timestamp { return }
        fix = newest
        message = manager.accuracyAuthorization == .fullAccuracy ? "Location available." : "Approximate location."
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        heading = newHeading.headingAccuracy >= 0 ? newHeading : nil
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        message = "Location error: \(error.localizedDescription)"
    }

    var shareText: String? {
        guard let fix else { return nil }
        return LocationText.share(latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude,
                                  accuracy: fix.horizontalAccuracy, timestamp: fix.timestamp)
    }
}
