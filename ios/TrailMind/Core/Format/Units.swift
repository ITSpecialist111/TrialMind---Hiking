import Foundation

enum Units {
    static func distance(_ m: Double, imperial: Bool = false) -> String {
        if imperial {
            let miles = m / 1609.344
            return miles < 0.1 ? "\(kRound(m * 3.28084)) ft" : fmt("%.2f mi", miles)
        }
        if m < 1000 { return "\(kRound(m)) m" }
        if m < 10_000 { return fmt("%.2f km", m / 1000) }
        return fmt("%.1f km", m / 1000)
    }

    static func elevation(_ m: Double, imperial: Bool = false) -> String {
        imperial ? "\(kRound(m * 3.28084)) ft" : "\(kRound(m)) m"
    }

    static func duration(_ ms: Int64) -> String { minutes(Double(ms) / 60_000.0) }

    static func minutes(_ min: Double) -> String {
        let total = max(kRoundL(min), 0)
        let h = total / 60
        let m = total % 60
        return h > 0 ? "\(h)h \(String(m).padStart(2, "0"))m" : "\(m)m"
    }

    static func speedKmh(_ mps: Double, imperial: Bool = false) -> String {
        imperial ? fmt("%.1f mph", mps * 2.236936) : fmt("%.1f km/h", mps * 3.6)
    }

    static func latLon(_ lat: Double, _ lon: Double) -> String {
        let ns = lat >= 0 ? "N" : "S"
        let ew = lon >= 0 ? "E" : "W"
        return fmt("%.5f°", abs(lat)) + ns + " " + fmt("%.5f°", abs(lon)) + ew
    }

    static func bearing(_ deg: Double) -> String { "\(String(kMod(kRound(deg), 360)).padStart(3, "0"))°" }
}
