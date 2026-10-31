import Combine
import Foundation

/// The barometer for the Safety and compass pages (sensor/Barometer.kt): LocationHub's pressure readings, smoothed, a
/// barometric altitude anchored to each GPS fix, and the sea-level pressure trend over three hours ("Pressure 1003 hPa ·
/// steady"). It listens whenever LocationHub runs: while TrailMind is open or a hike records.
final class PressureWatch: ObservableObject {
    static let shared = PressureWatch()

    private let readings = BarometerReadings()
    @Published private(set) var summary: String? = nil
    /// The smoothed pressure to 0.1 hPa, published only when that changes; `currentHpa` is the reading itself.
    @Published private(set) var pressureHpa: Double? = nil
    private var bag = Set<AnyCancellable>()
    private var started = false

    var currentHpa: Double? { readings.pressureHpa }

    func start() {
        guard !started else { return }
        started = true
        LocationHub.shared.$pressureKPa
            .compactMap { $0 }
            .sink { [weak self] kPa in
                guard let self else { return }
                self.readings.onPressure(kPa * 10)
                self.publish()
            }
            .store(in: &bag)
        LocationHub.shared.addListener { [weak self] fix in self?.onFix(fix) }
    }

    private func onFix(_ fix: Fix) {
        let location = fix.location
        _ = readings.altitudeFor(fixTimeMs: fix.timeMs, gpsAltitudeM: fix.gpsAltitudeM,
                                 verticalAccuracyM: location.verticalAccuracy >= 0 ? location.verticalAccuracy : nil,
                                 horizontalAccuracyM: location.horizontalAccuracy >= 0 ? location.horizontalAccuracy : nil,
                                 nowMs: nowMs())
        publish()
    }

    private func publish() {
        let text = readings.summary()
        if text != summary { summary = text }
        // Rounded so the pages redraw for a visible change, not every reading.
        let hpa = readings.pressureHpa.map { ($0 * 10).rounded() / 10 }
        if hpa != pressureHpa { pressureHpa = hpa }
    }
}
