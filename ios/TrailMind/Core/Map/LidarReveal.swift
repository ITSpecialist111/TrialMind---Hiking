import Foundation

/// The opaque, grey LiDAR pictures that the Reveal slider pulls the Ordnance Survey map back to show: ground shaped
/// to bring out what is too low to see from the path (ditches, banks, hut platforms, lynchets, castle ramparts under
/// trees). Built from the same 1 m squares as `Lidar`, with a wider border because they look up to 10 m around each
/// cell (LidarReveal.kt).
enum LidarReveal {
    /// Pixels needed around a square: the furthest a cell looks for a horizon or a local average.
    static let border = 10

    /// The Reveal picture shows on the phone from `LidarSource.minZoom`, and squares missing from it are downloaded from here...
    static let fetchZoom = 16.5
    /// ...and turning Reveal on takes the map this close, where even a big screen needs few squares (the service is slow).
    static let startZoom = 17.0

    enum Style: String, CaseIterable {
        case svf, slrm, hillshade

        var id: String { rawValue }

        var label: String {
            switch self {
            case .svf: return "Sky-view"
            case .slrm: return "Local relief"
            case .hillshade: return "Hillshade"
            }
        }

        var note: String {
            switch self {
            case .svf:
                return "Shades ground by how much sky a person standing there would see. Ditches, hollows and platforms show dark, " +
                    "and banks and ramparts stay light. The best all-round view."
            case .slrm:
                return "Shows each spot's height against the ground around it: raised ground light, sunken ground dark, " +
                    "with the hillside itself removed. Faint banks and ditches stand out."
            case .hillshade:
                return "Light from four directions at once, so no bank hides in its own shadow."
            }
        }

        static func of(_ id: String?) -> Style { allCases.first { $0.id == id } ?? .svf }
    }

    /// Opaque grey ARGB pixels for a `padded` square (see `Lidar.padded`, with `border`); transparent where the heights
    /// around a cell are missing, so the map shows through at the edge of the survey.
    static func render(_ padded: [Float], _ style: Style) -> [UInt32] {
        let stride = Lidar.size + 2 * border
        precondition(padded.count == stride * stride)
        var out = [UInt32](repeating: 0, count: Lidar.size * Lidar.size)
        let local: [Float]? = style == .slrm ? localRelief(padded) : nil
        for row in 0..<Lidar.size {
            for col in 0..<Lidar.size {
                let i = (row + border) * stride + col + border
                if padded[i].isNaN { continue }
                let tone: Float
                switch style {
                case .hillshade:
                    tone = hillshade(padded, i, stride)
                case .svf:
                    let svf = skyView(padded, i, stride)
                    // Light from the north-west on top keeps the shape of the ground readable.
                    tone = svfTone(svf) * (0.7 + 0.3 * hillshade(padded, i, stride) / flat).clamped(0.5, 1.15)
                case .slrm:
                    let relief = local![row * Lidar.size + col]
                    // Eased towards the ends, so faint banks show and a rampart several metres high doesn't flatten to black and white.
                    tone = 0.5 + 0.5 * relief / (abs(relief) + slrmRangeM)
                }
                if tone.isNaN { continue }
                let grey = UInt32(Int((tone.clamped(0, 1) * 255 + 0.5).rounded(.towardZero)))
                out[row * Lidar.size + col] = 0xFF << 24 | grey << 16 | grey << 8 | grey
            }
        }
        return out
    }

    /// Sky-view factor, 1 on open level ground and lower in hollows and under slopes; NaN where there is no height.
    static func skyView(_ p: [Float], _ i: Int, _ stride: Int) -> Float {
        let z0 = p[i]
        if z0.isNaN { return .nan }
        var total: Float = 0
        for d in 0..<8 {
            let dx = dirX[d]
            let dy = dirY[d]
            let metresPerStep: Float = dx != 0 && dy != 0 ? sqrt2 : 1
            var rise: Float = 0
            for step in steps {
                let v = p[i + dy * step * stride + dx * step]
                if v.isNaN { continue }
                let t = (v - z0) / (Float(step) * metresPerStep)
                if t > rise { rise = t }
            }
            total += rise / (1 + rise * rise).squareRoot()
        }
        return 1 - total / 8
    }

    private static func svfTone(_ svf: Float) -> Float {
        let t = ((svf - svfDarkest) / (1 - svfDarkest)).clamped(0, 1)
        return 0.15 + 0.8 * t
    }

    /// Hillshade from 0 (dark) to 1 averaged over four light directions at 45°, with the relief stretched `zFactor` times.
    static func hillshade(_ p: [Float], _ i: Int, _ s: Int) -> Float {
        let east = p[i - s + 1] + 2 * p[i + 1] + p[i + s + 1]
        let west = p[i - s - 1] + 2 * p[i - 1] + p[i + s - 1]
        let dzdx = (east - west) / 8 * zFactor
        // Rows run south, so the rise towards the north is the opposite of the rise down the rows.
        let south = p[i + s - 1] + 2 * p[i + s] + p[i + s + 1]
        let north = p[i - s - 1] + 2 * p[i - s] + p[i - s + 1]
        let dzdy = (south - north) / 8 * zFactor
        if dzdx.isNaN || dzdy.isNaN { return .nan }
        let norm = (1 + dzdx * dzdx + dzdy * dzdy).squareRoot()
        var total: Float = 0
        for a in 0..<lightSin.count {
            let lit = (cosAlt * (-dzdx * lightSin[a] + dzdy * lightCos[a]) + flat) / norm
            total += lit.clamped(0, 1)
        }
        return total / Float(lightSin.count)
    }

    /// Each cell's height minus the average over the 21 × 21 m around it, NaN where it or more than half its neighbours are missing.
    private static func localRelief(_ p: [Float]) -> [Float] {
        let stride = Lidar.size + 2 * border
        var out = [Float](repeating: .nan, count: Lidar.size * Lidar.size)
        for row in 0..<Lidar.size {
            for col in 0..<Lidar.size {
                let i = (row + border) * stride + col + border
                let z = p[i]
                if z.isNaN { continue }
                var sum = 0.0
                var count = 0
                for dy in -border...border {
                    let base = i + dy * stride
                    for dx in -border...border {
                        let v = p[base + dx]
                        if !v.isNaN {
                            sum += Double(v)
                            count += 1
                        }
                    }
                }
                if count < window * window / 2 { continue }
                out[row * Lidar.size + col] = Float(Double(z) - sum / Double(count))
            }
        }
        return out
    }

    private static let window = 2 * border + 1
    private static let flat: Float = 0.70710677
    private static let cosAlt: Float = 0.70710677
    private static let zFactor: Float = 2.5
    /// Sky-view below this is as dark as the picture gets.
    private static let svfDarkest: Float = 0.78
    /// Local relief this far above or below its surroundings is half way to as light or dark as the picture gets.
    private static let slrmRangeM: Float = 0.25
    private static let sqrt2: Float = 1.4142135
    private static let steps = [1, 2, 3, 4, 6, 8, 10]
    private static let dirX = [1, 1, 0, -1, -1, -1, 0, 1]
    private static let dirY = [0, 1, 1, 1, 0, -1, -1, -1]
    // Light from the south-west, west, north-west and north.
    private static let lightAzimuths = [225.0, 270.0, 315.0, 360.0]
    private static let lightSin: [Float] = lightAzimuths.map { Float(sin(toRadians($0))) }
    private static let lightCos: [Float] = lightAzimuths.map { Float(cos(toRadians($0))) }
}
