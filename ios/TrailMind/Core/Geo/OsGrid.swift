import Foundation

struct OsGridRef: Hashable {
    var easting: Double
    var northing: Double

    init(_ easting: Double, _ northing: Double) { self.easting = easting; self.northing = northing }
    init(easting: Double, northing: Double) { self.init(easting, northing) }

    /// e.g. "NN 16667 71283" (10-figure, 1 m) or fewer digits for `digits` = 6 or 8.
    func format(_ digits: Int = 10) -> String? {
        guard let letters = OsGrid.letters(easting, northing) else { return nil }
        let per = (digits / 2).clamped(1, 5)
        let div = pow(10.0, Double(5 - per))
        let e = kTruncate(floor(easting.truncatingRemainder(dividingBy: 100_000) / div))
        let n = kTruncate(floor(northing.truncatingRemainder(dividingBy: 100_000) / div))
        return "\(letters) \(String(e).padStart(per, "0")) \(String(n).padStart(per, "0"))"
    }
}

struct ParsedGridRef: Hashable {
    var easting: Double
    var northing: Double
    var precisionM: Int

    var position: LatLon { OsGrid.toWgs84(easting, northing) }
}

/// WGS84 <-> OSGB36 British National Grid. Uses the OS 7-parameter Helmert transform, which is accurate to roughly
/// +/-5 m: good enough to read a grid reference to Mountain Rescue, not survey.
enum OsGrid {
    private static let wgs84A = 6_378_137.0
    private static let wgs84B = 6_356_752.314245
    private static let airyA = 6_377_563.396
    private static let airyB = 6_356_256.909
    private static let f0 = 0.9996012717
    private static let lat0 = toRadians(49.0)
    private static let lon0 = toRadians(-2.0)
    private static let n0 = -100_000.0
    private static let e0 = 400_000.0

    static func fromWgs84(_ p: LatLon) -> OsGridRef? {
        if p.lat < 49.0 || p.lat > 61.5 || p.lon < -9.5 || p.lon > 2.5 { return nil }
        let osgb = wgs84ToOsgb36(p)
        let ref = projectOsgb36(osgb)
        return (0.0...700_000.0).contains(ref.easting) && (0.0...1_300_000.0).contains(ref.northing) ? ref : nil
    }

    /// Like `fromWgs84` but without the Great Britain range check, for map geometry near the edges.
    static func project(_ p: LatLon) -> OsGridRef { projectOsgb36(wgs84ToOsgb36(p)) }

    /// A grid position back to WGS84: the inverse of `project`, with the same Helmert accuracy.
    static func toWgs84(_ easting: Double, _ northing: Double) -> LatLon { osgb36ToWgs84(unprojectOsgb36(easting, northing)) }

    static func wgs84ToOsgb36(_ p: LatLon) -> LatLon {
        let (x1, y1, z1) = toCartesian(p, wgs84A, wgs84B)
        let tx = -446.448, ty = 125.157, tz = -542.060
        let s = 20.4894e-6
        let rx = toRadians(-0.1502 / 3600.0)
        let ry = toRadians(-0.2470 / 3600.0)
        let rz = toRadians(-0.8421 / 3600.0)
        let s1 = s + 1.0
        let x2 = tx + x1 * s1 - y1 * rz + z1 * ry
        let y2 = ty + x1 * rz + y1 * s1 - z1 * rx
        let z2 = tz - x1 * ry + y1 * rx + z1 * s1
        return fromCartesian(x2, y2, z2, airyA, airyB)
    }

    static func osgb36ToWgs84(_ p: LatLon) -> LatLon {
        let (x1, y1, z1) = toCartesian(p, airyA, airyB)
        // The forward parameters negated: the inverse to far better than the transform's own accuracy.
        let tx = 446.448, ty = -125.157, tz = 542.060
        let s = -20.4894e-6
        let rx = toRadians(0.1502 / 3600.0)
        let ry = toRadians(0.2470 / 3600.0)
        let rz = toRadians(0.8421 / 3600.0)
        let s1 = s + 1.0
        let x2 = tx + x1 * s1 - y1 * rz + z1 * ry
        let y2 = ty + x1 * rz + y1 * s1 - z1 * rx
        let z2 = tz - x1 * ry + y1 * rx + z1 * s1
        return fromCartesian(x2, y2, z2, wgs84A, wgs84B)
    }

    /// Meridional arc from the true origin to `phi` (radians), scaled by F0.
    private static func meridionalArc(_ phi: Double) -> Double {
        let n = (airyA - airyB) / (airyA + airyB)
        let n2 = n * n, n3 = n2 * n
        let dPhi = phi - lat0, sPhi = phi + lat0
        let ma = (1 + n + 1.25 * n2 + 1.25 * n3) * dPhi
        let mb = (3 * n + 3 * n2 + 21.0 / 8 * n3) * sin(dPhi) * cos(sPhi)
        let mc = (15.0 / 8 * n2 + 15.0 / 8 * n3) * sin(2 * dPhi) * cos(2 * sPhi)
        let md = 35.0 / 24 * n3 * sin(3 * dPhi) * cos(3 * sPhi)
        return airyB * f0 * (ma - mb + mc - md)
    }

    /// Transverse Mercator projection of an OSGB36 (Airy 1830) latitude/longitude.
    static func projectOsgb36(_ p: LatLon) -> OsGridRef {
        let a = airyA, b = airyB
        let phi = toRadians(p.lat), lambda = toRadians(p.lon)
        let e2 = 1 - (b * b) / (a * a)
        let sinPhi = sin(phi), cosPhi = cos(phi)
        let nu = a * f0 / sqrt(1 - e2 * sinPhi * sinPhi)
        let rho = a * f0 * (1 - e2) / pow(1 - e2 * sinPhi * sinPhi, 1.5)
        let eta2 = nu / rho - 1
        let m = meridionalArc(phi)
        let cos3 = cosPhi * cosPhi * cosPhi
        let cos5 = cos3 * cosPhi * cosPhi
        let tan2 = tan(phi) * tan(phi)
        let tan4 = tan2 * tan2
        let i = m + n0
        let ii = nu / 2 * sinPhi * cosPhi
        let iii = nu / 24 * sinPhi * cos3 * (5 - tan2 + 9 * eta2)
        let iiia = nu / 720 * sinPhi * cos5 * (61 - 58 * tan2 + tan4)
        let iv = nu * cosPhi
        let v = nu / 6 * cos3 * (nu / rho - tan2)
        let vi = nu / 120 * cos5 * (5 - 18 * tan2 + tan4 + 14 * eta2 - 58 * tan2 * eta2)
        let dl = lambda - lon0
        let dl2 = dl * dl
        let northing = i + ii * dl2 + iii * dl2 * dl2 + iiia * dl2 * dl2 * dl2
        let easting = e0 + iv * dl + v * dl2 * dl + vi * dl2 * dl2 * dl
        return OsGridRef(easting, northing)
    }

    /// Inverse Transverse Mercator: the OSGB36 (Airy 1830) latitude/longitude of a grid position.
    static func unprojectOsgb36(_ easting: Double, _ northing: Double) -> LatLon {
        let a = airyA, b = airyB
        let e2 = 1 - (b * b) / (a * a)
        var phi = lat0
        var m = 0.0
        repeat {
            phi += (northing - n0 - m) / (a * f0)
            m = meridionalArc(phi)
        } while abs(northing - n0 - m) >= 0.00001
        let sinPhi = sin(phi)
        let nu = a * f0 / sqrt(1 - e2 * sinPhi * sinPhi)
        let rho = a * f0 * (1 - e2) / pow(1 - e2 * sinPhi * sinPhi, 1.5)
        let eta2 = nu / rho - 1
        let tanPhi = tan(phi)
        let tan2 = tanPhi * tanPhi, tan4 = tan2 * tan2, tan6 = tan4 * tan2
        let sec = 1 / cos(phi)
        let nu3 = nu * nu * nu, nu5 = nu3 * nu * nu, nu7 = nu5 * nu * nu
        let vii = tanPhi / (2 * rho * nu)
        let viii = tanPhi / (24 * rho * nu3) * (5 + 3 * tan2 + eta2 - 9 * tan2 * eta2)
        let ix = tanPhi / (720 * rho * nu5) * (61 + 90 * tan2 + 45 * tan4)
        let x = sec / nu
        let xi = sec / (6 * nu3) * (nu / rho + 2 * tan2)
        let xii = sec / (120 * nu5) * (5 + 28 * tan2 + 24 * tan4)
        let xiia = sec / (5040 * nu7) * (61 + 662 * tan2 + 1320 * tan4 + 720 * tan6)
        let de = easting - e0
        let de2 = de * de
        let lat = phi - vii * de2 + viii * de2 * de2 - ix * de2 * de2 * de2
        let lon = lon0 + x * de - xi * de2 * de + xii * de2 * de2 * de - xiia * de2 * de2 * de2 * de
        return LatLon(toDegrees(lat), toDegrees(lon))
    }

    /// Two-letter 100 km square for an easting/northing, or nil outside the grid.
    static func letters(_ easting: Double, _ northing: Double) -> String? {
        let e100k = kTruncate(floor(easting / 100_000))
        let n100k = kTruncate(floor(northing / 100_000))
        if e100k < 0 || e100k > 6 || n100k < 0 || n100k > 12 { return nil }
        var l1 = (19 - n100k) - (19 - n100k) % 5 + (e100k + 10) / 5
        var l2 = (19 - n100k) * 5 % 25 + e100k % 5
        if l1 > 7 { l1 += 1 }
        if l2 > 7 { l2 += 1 }
        return String(UnicodeScalar(UInt8(65 + l1))) + String(UnicodeScalar(UInt8(65 + l2)))
    }

    static func parse(_ text: String) -> ParsedGridRef? {
        let compact = String(text.uppercased().filter { !$0.isWhitespace })
        guard compact.range(of: "^[A-HJ-Z]{2}(?:[0-9]{2}){0,5}$", options: .regularExpression) != nil else { return nil }
        let chars = Array(compact)
        func index(_ letter: Character) -> Int {
            let v = Int(letter.asciiValue!) - 65
            return v - (letter > "I" ? 1 : 0)
        }
        let first = index(chars[0])
        let second = index(chars[1])
        let e100k = kMod(first - 2, 5) * 5 + second % 5
        let n100k = 19 - first / 5 * 5 - second / 5
        if !(0...6).contains(e100k) || !(0...12).contains(n100k) { return nil }
        let half = (chars.count - 2) / 2
        let precision = Int(pow(10.0, Double(5 - half)))
        let east = half == 0 ? 0 : Int(String(chars[2..<(2 + half)]))! * precision
        let north = half == 0 ? 0 : Int(String(chars[(2 + half)...]))! * precision
        // Search goes to the centre of the referenced square, including 100 km squares.
        return ParsedGridRef(
            easting: Double(e100k) * 100_000.0 + Double(east) + Double(precision) / 2.0,
            northing: Double(n100k) * 100_000.0 + Double(north) + Double(precision) / 2.0,
            precisionM: precision
        )
    }

    private static func toCartesian(_ p: LatLon, _ a: Double, _ b: Double) -> (Double, Double, Double) {
        let phi = toRadians(p.lat), lambda = toRadians(p.lon)
        let e2 = 1 - (b * b) / (a * a)
        let nu = a / sqrt(1 - e2 * sin(phi) * sin(phi))
        return (nu * cos(phi) * cos(lambda), nu * cos(phi) * sin(lambda), (1 - e2) * nu * sin(phi))
    }

    private static func fromCartesian(_ x: Double, _ y: Double, _ z: Double, _ a: Double, _ b: Double) -> LatLon {
        let e2 = 1 - (b * b) / (a * a)
        let pp = sqrt(x * x + y * y)
        var phi = atan2(z, pp * (1 - e2))
        for _ in 0..<10 {
            let nu = a / sqrt(1 - e2 * sin(phi) * sin(phi))
            let next = atan2(z + e2 * nu * sin(phi), pp)
            if abs(next - phi) < 1e-12 {
                return LatLon(toDegrees(next), toDegrees(atan2(y, x)))
            }
            phi = next
        }
        return LatLon(toDegrees(phi), toDegrees(atan2(y, x)))
    }
}
