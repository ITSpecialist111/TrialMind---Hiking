import Foundation

/// The Earth's main magnetic field from the World Magnetic Model WMM2025 (NOAA NCEI and the British Geological Survey,
/// public domain; valid 2025.0–2030.0). Android's compass gets the same from `GeomagneticField`: the declination that
/// turns a magnetic heading into a true one, and the strength and dip that `MagneticCheck` compares the magnetometer with.
enum WorldMagneticModel {
    struct Field: Hashable {
        /// North, east and down components, nanotesla.
        var northNt: Double
        var eastNt: Double
        var downNt: Double

        var horizontalNt: Double { (northNt * northNt + eastNt * eastNt).squareRoot() }
        /// Total intensity, nanotesla.
        var totalNt: Double { (northNt * northNt + eastNt * eastNt + downNt * downNt).squareRoot() }
        /// Degrees east of true north.
        var declinationDeg: Double { toDegrees(atan2(eastNt, northNt)) }
        /// Inclination (dip), degrees below the horizontal.
        var inclinationDeg: Double { toDegrees(atan2(downNt, horizontalNt)) }
    }

    static let epoch = 2025.0
    private static let maxDegree = 12
    /// The model's reference radius, km.
    private static let referenceRadiusKm = 6371.2
    /// WGS 84.
    private static let semiMajorKm = 6378.137
    private static let flattening = 1 / 298.257223563

    /// The field at a place `heightKm` above the WGS 84 ellipsoid, at a decimal year such as 2026.5.
    static func field(latDeg: Double, lonDeg: Double, heightKm: Double, decimalYear: Double) -> Field {
        let dt = decimalYear - epoch
        // Geodetic to geocentric spherical. Right at a geographic pole the east component is undefined, so stay a hair off.
        let lat = toRadians(latDeg.clamped(-89.999_99, 89.999_99))
        let lon = toRadians(lonDeg)
        let e2 = flattening * (2 - flattening)
        let sinLat = sin(lat)
        let rc = semiMajorKm / (1 - e2 * sinLat * sinLat).squareRoot()
        let p = (rc + heightKm) * cos(lat)
        let z = (rc * (1 - e2) + heightKm) * sinLat
        let r = (p * p + z * z).squareRoot()
        let latC = asin(z / r)

        let (pnm, dpnm) = legendre(sin(latC), cos(latC))
        var cosM = [Double](repeating: 0, count: maxDegree + 1)
        var sinM = [Double](repeating: 0, count: maxDegree + 1)
        for m in 0...maxDegree {
            cosM[m] = cos(Double(m) * lon)
            sinM[m] = sin(Double(m) * lon)
        }
        let ratio = referenceRadiusKm / r
        var power = ratio * ratio
        var north = 0.0, east = 0.0, down = 0.0
        for n in 1...maxDegree {
            power *= ratio
            for m in 0...n {
                let i = n * (n + 1) / 2 + m
                let g = gnm[i] + dt * gDot[i]
                let h = hnm[i] + dt * hDot[i]
                let gh = g * cosM[m] + h * sinM[m]
                down -= power * gh * Double(n + 1) * pnm[i]
                east += power * (g * sinM[m] - h * cosM[m]) * Double(m) * pnm[i]
                north -= power * gh * dpnm[i]
            }
        }
        east /= cos(latC)
        // Back from the geocentric to the geodetic frame.
        let psi = latC - lat
        return Field(northNt: north * cos(psi) - down * sin(psi), eastNt: east, downNt: north * sin(psi) + down * cos(psi))
    }

    /// The field at a position `altitudeM` metres up at a time; sea-level altitude is close enough to the ellipsoid here.
    static func field(_ at: LatLon, altitudeM: Double, timeMs: Int64) -> Field {
        field(latDeg: at.lat, lonDeg: at.lon, heightKm: altitudeM / 1000, decimalYear: decimalYear(timeMs))
    }

    /// The year and how far through it a UTC time is, as the model counts time (2025.0 is 1 January 2025).
    static func decimalYear(_ timeMs: Int64) -> Double {
        let day = CivilDate.floorDiv(timeMs, CivilDate.msPerDay)
        let year = CivilDate.fromEpochDay(day).year
        let start = CivilDate.epochDay(year, 1, 1) * CivilDate.msPerDay
        let end = CivilDate.epochDay(year + 1, 1, 1) * CivilDate.msPerDay
        return Double(year) + Double(timeMs - start) / Double(end - start)
    }

    /// Schmidt semi-normalised associated Legendre functions of sin(latitude) and their derivatives by latitude, indexed
    /// n(n+1)/2 + m (the recurrences of the WMM technical report).
    private static func legendre(_ x: Double, _ z: Double) -> ([Double], [Double]) {
        let count = (maxDegree + 1) * (maxDegree + 2) / 2
        var p = [Double](repeating: 0, count: count)
        var dp = [Double](repeating: 0, count: count)
        p[0] = 1
        for n in 1...maxDegree {
            for m in 0...n {
                let i = n * (n + 1) / 2 + m
                if n == m {
                    let i1 = (n - 1) * n / 2 + m - 1
                    p[i] = z * p[i1]
                    dp[i] = z * dp[i1] + x * p[i1]
                } else if n == 1 {
                    p[i] = x * p[0]
                    dp[i] = x * dp[0] - z * p[0]
                } else {
                    let i1 = (n - 2) * (n - 1) / 2 + m
                    let i2 = (n - 1) * n / 2 + m
                    if m > n - 2 {
                        p[i] = x * p[i2]
                        dp[i] = x * dp[i2] - z * p[i2]
                    } else {
                        let k = Double((n - 1) * (n - 1) - m * m) / Double((2 * n - 1) * (2 * n - 3))
                        p[i] = x * p[i2] - k * p[i1]
                        dp[i] = x * dp[i2] - z * p[i2] - k * dp[i1]
                    }
                }
            }
        }
        var norm = [Double](repeating: 0, count: count)
        norm[0] = 1
        for n in 1...maxDegree {
            norm[n * (n + 1) / 2] = norm[(n - 1) * n / 2] * Double(2 * n - 1) / Double(n)
            for m in 1...n {
                let i = n * (n + 1) / 2 + m
                norm[i] = norm[i - 1] * (Double((n - m + 1) * (m == 1 ? 2 : 1)) / Double(n + m)).squareRoot()
            }
        }
        for i in 1..<count {
            p[i] *= norm[i]
            // The recurrences give d/d(colatitude); the field sums need d/d(latitude).
            dp[i] = -dp[i] * norm[i]
        }
        return (p, dp)
    }

    private static let gnm = table(2)
    private static let hnm = table(3)
    private static let gDot = table(4)
    private static let hDot = table(5)

    private static func table(_ column: Int) -> [Double] {
        var values = [Double](repeating: 0, count: (maxDegree + 1) * (maxDegree + 2) / 2)
        for row in coefficients {
            let i = Int(row[0]) * (Int(row[0]) + 1) / 2 + Int(row[1])
            values[i] = row[column]
        }
        return values
    }

    /// WMM.COF for WMM2025 (11/13/2024): n, m, g, h (nT) and their yearly changes (nT/year).
    private static let coefficients: [[Double]] = [
        [1, 0, -29351.8, 0.0, 12.0, 0.0],
        [1, 1, -1410.8, 4545.4, 9.7, -21.5],
        [2, 0, -2556.6, 0.0, -11.6, 0.0],
        [2, 1, 2951.1, -3133.6, -5.2, -27.7],
        [2, 2, 1649.3, -815.1, -8.0, -12.1],
        [3, 0, 1361.0, 0.0, -1.3, 0.0],
        [3, 1, -2404.1, -56.6, -4.2, 4.0],
        [3, 2, 1243.8, 237.5, 0.4, -0.3],
        [3, 3, 453.6, -549.5, -15.6, -4.1],
        [4, 0, 895.0, 0.0, -1.6, 0.0],
        [4, 1, 799.5, 278.6, -2.4, -1.1],
        [4, 2, 55.7, -133.9, -6.0, 4.1],
        [4, 3, -281.1, 212.0, 5.6, 1.6],
        [4, 4, 12.1, -375.6, -7.0, -4.4],
        [5, 0, -233.2, 0.0, 0.6, 0.0],
        [5, 1, 368.9, 45.4, 1.4, -0.5],
        [5, 2, 187.2, 220.2, 0.0, 2.2],
        [5, 3, -138.7, -122.9, 0.6, 0.4],
        [5, 4, -142.0, 43.0, 2.2, 1.7],
        [5, 5, 20.9, 106.1, 0.9, 1.9],
        [6, 0, 64.4, 0.0, -0.2, 0.0],
        [6, 1, 63.8, -18.4, -0.4, 0.3],
        [6, 2, 76.9, 16.8, 0.9, -1.6],
        [6, 3, -115.7, 48.8, 1.2, -0.4],
        [6, 4, -40.9, -59.8, -0.9, 0.9],
        [6, 5, 14.9, 10.9, 0.3, 0.7],
        [6, 6, -60.7, 72.7, 0.9, 0.9],
        [7, 0, 79.5, 0.0, -0.0, 0.0],
        [7, 1, -77.0, -48.9, -0.1, 0.6],
        [7, 2, -8.8, -14.4, -0.1, 0.5],
        [7, 3, 59.3, -1.0, 0.5, -0.8],
        [7, 4, 15.8, 23.4, -0.1, 0.0],
        [7, 5, 2.5, -7.4, -0.8, -1.0],
        [7, 6, -11.1, -25.1, -0.8, 0.6],
        [7, 7, 14.2, -2.3, 0.8, -0.2],
        [8, 0, 23.2, 0.0, -0.1, 0.0],
        [8, 1, 10.8, 7.1, 0.2, -0.2],
        [8, 2, -17.5, -12.6, 0.0, 0.5],
        [8, 3, 2.0, 11.4, 0.5, -0.4],
        [8, 4, -21.7, -9.7, -0.1, 0.4],
        [8, 5, 16.9, 12.7, 0.3, -0.5],
        [8, 6, 15.0, 0.7, 0.2, -0.6],
        [8, 7, -16.8, -5.2, -0.0, 0.3],
        [8, 8, 0.9, 3.9, 0.2, 0.2],
        [9, 0, 4.6, 0.0, -0.0, 0.0],
        [9, 1, 7.8, -24.8, -0.1, -0.3],
        [9, 2, 3.0, 12.2, 0.1, 0.3],
        [9, 3, -0.2, 8.3, 0.3, -0.3],
        [9, 4, -2.5, -3.3, -0.3, 0.3],
        [9, 5, -13.1, -5.2, 0.0, 0.2],
        [9, 6, 2.4, 7.2, 0.3, -0.1],
        [9, 7, 8.6, -0.6, -0.1, -0.2],
        [9, 8, -8.7, 0.8, 0.1, 0.4],
        [9, 9, -12.9, 10.0, -0.1, 0.1],
        [10, 0, -1.3, 0.0, 0.1, 0.0],
        [10, 1, -6.4, 3.3, 0.0, 0.0],
        [10, 2, 0.2, 0.0, 0.1, -0.0],
        [10, 3, 2.0, 2.4, 0.1, -0.2],
        [10, 4, -1.0, 5.3, -0.0, 0.1],
        [10, 5, -0.6, -9.1, -0.3, -0.1],
        [10, 6, -0.9, 0.4, 0.0, 0.1],
        [10, 7, 1.5, -4.2, -0.1, 0.0],
        [10, 8, 0.9, -3.8, -0.1, -0.1],
        [10, 9, -2.7, 0.9, -0.0, 0.2],
        [10, 10, -3.9, -9.1, -0.0, -0.0],
        [11, 0, 2.9, 0.0, 0.0, 0.0],
        [11, 1, -1.5, 0.0, -0.0, -0.0],
        [11, 2, -2.5, 2.9, 0.0, 0.1],
        [11, 3, 2.4, -0.6, 0.0, -0.0],
        [11, 4, -0.6, 0.2, 0.0, 0.1],
        [11, 5, -0.1, 0.5, -0.1, -0.0],
        [11, 6, -0.6, -0.3, 0.0, -0.0],
        [11, 7, -0.1, -1.2, -0.0, 0.1],
        [11, 8, 1.1, -1.7, -0.1, -0.0],
        [11, 9, -1.0, -2.9, -0.1, 0.0],
        [11, 10, -0.2, -1.8, -0.1, 0.0],
        [11, 11, 2.6, -2.3, -0.1, 0.0],
        [12, 0, -2.0, 0.0, 0.0, 0.0],
        [12, 1, -0.2, -1.3, 0.0, -0.0],
        [12, 2, 0.3, 0.7, -0.0, 0.0],
        [12, 3, 1.2, 1.0, -0.0, -0.1],
        [12, 4, -1.3, -1.4, -0.0, 0.1],
        [12, 5, 0.6, -0.0, -0.0, -0.0],
        [12, 6, 0.6, 0.6, 0.1, -0.0],
        [12, 7, 0.5, -0.1, -0.0, -0.0],
        [12, 8, -0.1, 0.8, 0.0, 0.0],
        [12, 9, -0.4, 0.1, 0.0, -0.0],
        [12, 10, -0.2, -1.0, -0.1, -0.0],
        [12, 11, -1.3, 0.1, -0.0, 0.0],
        [12, 12, -0.7, 0.2, -0.1, -0.1],
    ]
}
