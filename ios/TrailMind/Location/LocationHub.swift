import CoreLocation
import CoreMotion
import Foundation
import UIKit

/// A GPS fix with the best available altitude above mean sea level (iOS already reports altitude above sea level).
struct Fix: Equatable {
    let location: CLLocation
    /// Barometric altitude anchored to GPS, when the phone has a barometer and it has settled.
    var baroAltitudeM: Double? = nil

    var lat: Double { location.coordinate.latitude }
    var lon: Double { location.coordinate.longitude }
    var latLon: LatLon { LatLon(lat, lon) }
    var accuracyM: Float { location.horizontalAccuracy >= 0 ? Float(location.horizontalAccuracy) : 50 }
    var timeMs: Int64 { Int64((location.timestamp.timeIntervalSince1970 * 1000).rounded()) }
    var gpsAltitudeM: Double? { location.verticalAccuracy >= 0 ? location.altitude : nil }
    /// Barometric altitude (anchored to GPS) when available, otherwise GPS altitude.
    var altitudeM: Double? { baroAltitudeM ?? gpsAltitudeM }
    var speedMps: Double? { location.speed >= 0 ? location.speed : nil }
    var speedAccuracyMps: Double? { location.speedAccuracy >= 0 ? location.speedAccuracy : nil }
    var courseDeg: Double? { location.course >= 0 ? location.course : nil }
    var courseAccuracyDeg: Double? { location.courseAccuracy >= 0 ? location.courseAccuracy : nil }
    var ageS: TimeInterval { -location.timestamp.timeIntervalSinceNow }

    func trackPoint() -> TrackPoint {
        TrackPoint(lat: lat, lon: lon, ele: altitudeM, timeMs: timeMs, accuracyM: accuracyM)
    }

    static func == (a: Fix, b: Fix) -> Bool { a.location.timestamp == b.location.timestamp && a.lat == b.lat && a.lon == b.lon }
}

/// Fan-out of location fixes and compass headings (location/LocationHub.kt + sensor/Compass.kt) on Core Location.
/// While the app is in front it runs at best accuracy for the map; while a hike records it keeps running in the
/// background with the blue location pill showing, as Android's foreground service does.
final class LocationHub: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = LocationHub()

    @Published private(set) var latest: Fix? = nil
    @Published private(set) var authorization: CLAuthorizationStatus
    @Published private(set) var fullAccuracy = true
    /// Compass heading, degrees true; nil without a usable reading.
    @Published private(set) var headingDeg: Double? = nil
    @Published private(set) var headingAccuracyDeg: Double? = nil
    @Published private(set) var headingAtMs: Int64 = 0
    /// The magnetometer reports poor accuracy (iOS shows its calibration prompt when this matters).
    @Published private(set) var compassUnreliable = false
    /// Raw magnetometer field strength in microtesla, for interference checks against the Earth's field.
    @Published private(set) var fieldMicroTesla: Double? = nil
    @Published private(set) var pressureKPa: Double? = nil

    private let manager = CLLocationManager()
    private let altimeter = CMAltimeter()
    private var listeners: [UUID: (Fix) -> Void] = [:]
    private var headingListeners: [UUID: () -> Void] = [:]
    private var foreground = false
    private(set) var recording = false
    private var backgroundSession: AnyObject?
    private var baroAnchor: (pressureAlt: Double, gpsAlt: Double)?
    private var lastPressureAltitude: Double?

    override init() {
        authorization = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
        manager.activityType = .fitness
        manager.headingFilter = 1
        manager.pausesLocationUpdatesAutomatically = false
    }

    var hasPermission: Bool { authorization == .authorizedWhenInUse || authorization == .authorizedAlways }
    var servicesEnabled: Bool { CLLocationManager.locationServicesEnabled() }

    @discardableResult
    func addListener(_ l: @escaping (Fix) -> Void) -> UUID { let id = UUID(); listeners[id] = l; return id }
    func removeListener(_ id: UUID) { listeners[id] = nil }
    @discardableResult
    func addHeadingListener(_ l: @escaping () -> Void) -> UUID { let id = UUID(); headingListeners[id] = l; return id }
    func removeHeadingListener(_ id: UUID) { headingListeners[id] = nil }

    func requestPermission() {
        if authorization == .notDetermined { manager.requestWhenInUseAuthorization() }
    }

    /// Recording in the background works with "While Using"; "Always" only matters for check-in reminders.
    func requestAlways() { manager.requestAlwaysAuthorization() }

    /// The compass is measured against the top of the display in use, so it follows the interface orientation (iPhone
    /// Duo's inner display is often held in landscape).
    func setInterfaceOrientation(_ o: UIInterfaceOrientation) {
        let device: CLDeviceOrientation
        switch o {
        case .portraitUpsideDown: device = .portraitUpsideDown
        case .landscapeLeft: device = .landscapeRight
        case .landscapeRight: device = .landscapeLeft
        default: device = .portrait
        }
        if manager.headingOrientation != device { manager.headingOrientation = device }
    }

    /// The app is visible: run the GPS and compass for the map.
    func setForeground(_ on: Bool) {
        foreground = on
        updateSession()
    }

    /// A hike is recording: keep GPS running in the background, with the blue indicator.
    func setRecording(_ on: Bool) {
        recording = on
        updateSession()
    }

    private func updateSession() {
        let wanted = (foreground || recording) && hasPermission
        if wanted {
            manager.allowsBackgroundLocationUpdates = recording
            manager.showsBackgroundLocationIndicator = recording
            manager.startUpdatingLocation()
            if foreground && CLLocationManager.headingAvailable() { manager.startUpdatingHeading() } else { manager.stopUpdatingHeading() }
            if recording, backgroundSession == nil, #available(iOS 17.0, *) { backgroundSession = CLBackgroundActivitySession() }
            startAltimeter()
        } else {
            manager.stopUpdatingLocation()
            manager.stopUpdatingHeading()
            altimeter.stopRelativeAltitudeUpdates()
        }
        if !recording, let session = backgroundSession {
            if #available(iOS 17.0, *) { (session as? CLBackgroundActivitySession)?.invalidate() }
            backgroundSession = nil
        }
    }

    private func startAltimeter() {
        guard CMAltimeter.isRelativeAltitudeAvailable() else { return }
        altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, _ in
            guard let self, let data else { return }
            let kPa = data.pressure.doubleValue
            self.pressureKPa = kPa
            // Pressure altitude from the standard atmosphere; only differences matter once anchored to GPS.
            self.lastPressureAltitude = 44_330.0 * (1.0 - pow(kPa / 101.325, 0.1903))
        }
    }

    /// Barometric altitude anchored to a good GPS altitude, re-anchored slowly so weather drift does not build up.
    private func baroAltitude(for loc: CLLocation) -> Double? {
        guard let pAlt = lastPressureAltitude else { return nil }
        if loc.verticalAccuracy >= 0 && loc.verticalAccuracy <= 12 {
            if let a = baroAnchor {
                let predicted = a.gpsAlt + (pAlt - a.pressureAlt)
                let blended = predicted + (loc.altitude - predicted) * 0.02
                baroAnchor = (pAlt, blended)
            } else {
                baroAnchor = (pAlt, loc.altitude)
            }
        }
        guard let a = baroAnchor else { return nil }
        return a.gpsAlt + (pAlt - a.pressureAlt)
    }

    // MARK: CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorization = manager.authorizationStatus
        fullAccuracy = manager.accuracyAuthorization == .fullAccuracy
        updateSession()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        for loc in locations where loc.horizontalAccuracy >= 0 {
            if let prev = latest, loc.timestamp <= prev.location.timestamp { continue }
            let fix = Fix(location: loc, baroAltitudeM: baroAltitude(for: loc))
            latest = fix
            listeners.values.forEach { $0(fix) }
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        guard newHeading.headingAccuracy >= 0 else {
            headingDeg = nil
            compassUnreliable = true
            return
        }
        headingDeg = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        headingAccuracyDeg = newHeading.headingAccuracy
        headingAtMs = nowMs()
        compassUnreliable = newHeading.headingAccuracy > 25
        fieldMicroTesla = sqrt(newHeading.x * newHeading.x + newHeading.y * newHeading.y + newHeading.z * newHeading.z)
        headingListeners.values.forEach { $0() }
    }

    func locationManagerShouldDisplayHeadingCalibration(_ manager: CLLocationManager) -> Bool { compassUnreliable }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
