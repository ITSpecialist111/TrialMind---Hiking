import Foundation

// Foundation-only so it can be unit tested on Linux as well as on iOS.
enum LocationText {
    static func share(latitude: Double, longitude: Double, accuracy: Double, timestamp: Date) -> String? {
        guard latitude.isFinite, longitude.isFinite, accuracy.isFinite,
              (-90...90).contains(latitude), (-180...180).contains(longitude), accuracy >= 0 else { return nil }
        let coordinate = String(format: "%.6f, %.6f", locale: Locale(identifier: "en_US_POSIX"), latitude, longitude)
        let link = String(format: "https://maps.apple.com/?ll=%.6f,%.6f", locale: Locale(identifier: "en_US_POSIX"), latitude, longitude)
        return "TrailMind location: \(coordinate)\nAccuracy: +/-\(Int(accuracy.rounded())) m\nFix time: \(ISO8601DateFormatter().string(from: timestamp))\n\(link)"
    }
}
