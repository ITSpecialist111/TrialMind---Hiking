import SwiftUI

/// Parses SVG/Android `pathData` (M L H V C S Q T A Z, absolute and relative) into a `Path` in viewport units.
enum SVGPathParser {
    static func parse(_ d: String) -> Path {
        var path = Path()
        let s = Array(d.unicodeScalars)
        let n = s.count
        var i = 0
        var current = CGPoint.zero
        var start = CGPoint.zero
        var lastControl: CGPoint? = nil
        var lastCommand: Character = " "
        var command: Character = " "

        func isSeparator(_ c: Unicode.Scalar) -> Bool { c == " " || c == "," || c == "\n" || c == "\t" || c == "\r" }
        func skipSeparators() { while i < n, isSeparator(s[i]) { i += 1 } }
        func isDigit(_ c: Unicode.Scalar) -> Bool { c.value >= 48 && c.value <= 57 }
        func peekIsNumber() -> Bool {
            skipSeparators()
            guard i < n else { return false }
            let c = s[i]
            return isDigit(c) || c == "-" || c == "+" || c == "."
        }
        func number() -> CGFloat {
            skipSeparators()
            let begin = i
            if i < n, s[i] == "-" || s[i] == "+" { i += 1 }
            var sawDot = false, sawDigit = false
            while i < n {
                let c = s[i]
                if isDigit(c) { sawDigit = true; i += 1 }
                else if c == ".", !sawDot { sawDot = true; i += 1 }
                else if (c == "e" || c == "E"), sawDigit {
                    i += 1
                    if i < n, s[i] == "-" || s[i] == "+" { i += 1 }
                    while i < n, isDigit(s[i]) { i += 1 }
                    break
                } else { break }
            }
            var text = ""
            text.unicodeScalars.append(contentsOf: s[begin..<i])
            return CGFloat(Double(text) ?? 0)
        }
        func flag() -> Bool {
            skipSeparators()
            guard i < n else { return false }
            let c = s[i]
            i += 1
            return c == "1"
        }

        while true {
            skipSeparators()
            if i >= n { break }
            let c = s[i]
            if c.properties.isAlphabetic && c != "e" && c != "E" {
                command = Character(c)
                i += 1
            } else if command == "M" {
                command = "L"
            } else if command == "m" {
                command = "l"
            } else if command == " " {
                break
            }
            let relative = command.isLowercase
            let base = relative ? current : .zero
            switch command.uppercased() {
            case "M":
                let p = CGPoint(x: base.x + number(), y: base.y + number())
                path.move(to: p)
                current = p; start = p; lastControl = nil
            case "L":
                let p = CGPoint(x: base.x + number(), y: base.y + number())
                path.addLine(to: p)
                current = p; lastControl = nil
            case "H":
                let x = (relative ? current.x : 0) + number()
                current = CGPoint(x: x, y: current.y)
                path.addLine(to: current); lastControl = nil
            case "V":
                let y = (relative ? current.y : 0) + number()
                current = CGPoint(x: current.x, y: y)
                path.addLine(to: current); lastControl = nil
            case "C":
                let c1 = CGPoint(x: base.x + number(), y: base.y + number())
                let c2 = CGPoint(x: base.x + number(), y: base.y + number())
                let p = CGPoint(x: base.x + number(), y: base.y + number())
                path.addCurve(to: p, control1: c1, control2: c2)
                current = p; lastControl = c2
            case "S":
                let c1: CGPoint
                if let lc = lastControl, "CcSs".contains(lastCommand) { c1 = CGPoint(x: 2 * current.x - lc.x, y: 2 * current.y - lc.y) } else { c1 = current }
                let c2 = CGPoint(x: base.x + number(), y: base.y + number())
                let p = CGPoint(x: base.x + number(), y: base.y + number())
                path.addCurve(to: p, control1: c1, control2: c2)
                current = p; lastControl = c2
            case "Q":
                let c1 = CGPoint(x: base.x + number(), y: base.y + number())
                let p = CGPoint(x: base.x + number(), y: base.y + number())
                path.addQuadCurve(to: p, control: c1)
                current = p; lastControl = c1
            case "T":
                let c1: CGPoint
                if let lc = lastControl, "QqTt".contains(lastCommand) { c1 = CGPoint(x: 2 * current.x - lc.x, y: 2 * current.y - lc.y) } else { c1 = current }
                let p = CGPoint(x: base.x + number(), y: base.y + number())
                path.addQuadCurve(to: p, control: c1)
                current = p; lastControl = c1
            case "A":
                let rx = abs(number()), ry = abs(number())
                let rotation = number()
                let largeArc = flag(), sweep = flag()
                let p = CGPoint(x: base.x + number(), y: base.y + number())
                addArc(&path, from: current, to: p, rx: rx, ry: ry, rotationDeg: rotation, largeArc: largeArc, sweep: sweep)
                current = p; lastControl = nil
            case "Z":
                path.closeSubpath()
                current = start; lastControl = nil
            default:
                i += 1
            }
            lastCommand = command
            if command.uppercased() == "Z" { continue }
            if !peekIsNumber() { continue }
        }
        return path
    }

    /// SVG elliptical arc (implementation notes F.6.5) as cubic Béziers of at most 90 degrees each.
    private static func addArc(_ path: inout Path, from p0: CGPoint, to p1: CGPoint, rx rxIn: CGFloat, ry ryIn: CGFloat,
                               rotationDeg: CGFloat, largeArc: Bool, sweep: Bool) {
        if p0 == p1 { return }
        var rx = Double(rxIn), ry = Double(ryIn)
        if rx == 0 || ry == 0 { path.addLine(to: p1); return }
        let phi = Double(rotationDeg) * .pi / 180
        let cosPhi = cos(phi), sinPhi = sin(phi)
        let dx = Double(p0.x - p1.x) / 2, dy = Double(p0.y - p1.y) / 2
        let x1p = cosPhi * dx + sinPhi * dy
        let y1p = -sinPhi * dx + cosPhi * dy
        let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 { rx *= sqrt(lambda); ry *= sqrt(lambda) }
        let num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
        let den = rx * rx * y1p * y1p + ry * ry * x1p * x1p
        var coef = den == 0 ? 0 : sqrt(max(0, num / den))
        if largeArc == sweep { coef = -coef }
        let cxp = coef * rx * y1p / ry
        let cyp = -coef * ry * x1p / rx
        let cx = cosPhi * cxp - sinPhi * cyp + Double(p0.x + p1.x) / 2
        let cy = sinPhi * cxp + cosPhi * cyp + Double(p0.y + p1.y) / 2
        func angle(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double {
            let a = atan2(ux * vy - uy * vx, ux * vx + uy * vy)
            return a
        }
        let theta1 = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
        var delta = angle((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
        if !sweep && delta > 0 { delta -= 2 * .pi }
        if sweep && delta < 0 { delta += 2 * .pi }
        let segments = max(1, Int(ceil(abs(delta) / (.pi / 2))))
        let step = delta / Double(segments)
        let t = 4.0 / 3.0 * tan(step / 4)
        var a = theta1
        func point(_ angle: Double) -> (Double, Double) {
            let ex = rx * cos(angle), ey = ry * sin(angle)
            return (cosPhi * ex - sinPhi * ey + cx, sinPhi * ex + cosPhi * ey + cy)
        }
        func derivative(_ angle: Double) -> (Double, Double) {
            let ex = -rx * sin(angle), ey = ry * cos(angle)
            return (cosPhi * ex - sinPhi * ey, sinPhi * ex + cosPhi * ey)
        }
        for _ in 0..<segments {
            let b = a + step
            let (x0, y0) = point(a), (x3, y3) = point(b)
            let (dx0, dy0) = derivative(a), (dx3, dy3) = derivative(b)
            path.addCurve(to: CGPoint(x: x3, y: y3),
                          control1: CGPoint(x: x0 + t * dx0, y: y0 + t * dy0),
                          control2: CGPoint(x: x3 - t * dx3, y: y3 - t * dy3))
            a = b
        }
    }
}

/// One layer of an icon: a filled path, or a stroked one with round caps.
struct IconLayer {
    let d: String
    let strokeWidth: CGFloat?
}

/// The Android app's own vector icons (res/drawable/ic_*.xml), drawn from the same path data.
enum TMIcon: String, CaseIterable {
    case add, arrowBack, close, compass, delete, download, folder, fullscreen, fullscreenExit, info, layers, map, menu
    case myLocation, navigation, north, pause, play, remove, route, search, share, sos, sparkle, stop, tune, upload
    case walk, warning, statHike, reveal

    var layers: [IconLayer] {
        switch self {
        case .add: return [IconLayer(d: "M19,13h-6v6h-2v-6H5v-2h6V5h2v6h6v2z", strokeWidth: nil)]
        case .arrowBack: return [IconLayer(d: "M20,11H7.83l5.59,-5.59L12,4l-8,8 8,8 1.41,-1.41L7.83,13H20v-2z", strokeWidth: nil)]
        case .close: return [IconLayer(d: "M19,6.41L17.59,5 12,10.59 6.41,5 5,6.41 10.59,12 5,17.59 6.41,19 12,13.41 17.59,19 19,17.59 13.41,12z", strokeWidth: nil)]
        case .compass: return [IconLayer(d: "M12,10.9c-0.61,0 -1.1,0.49 -1.1,1.1s0.49,1.1 1.1,1.1c0.61,0 1.1,-0.49 1.1,-1.1s-0.49,-1.1 -1.1,-1.1zM12,2C6.48,2 2,6.48 2,12s4.48,10 10,10 10,-4.48 10,-10S17.52,2 12,2zM14.19,14.19L6,18l3.81,-8.19L18,6l-3.81,8.19z", strokeWidth: nil)]
        case .delete: return [IconLayer(d: "M6,19c0,1.1 0.9,2 2,2h8c1.1,0 2,-0.9 2,-2V7H6v12zM19,4h-3.5l-1,-1h-5l-1,1H5v2h14V4z", strokeWidth: nil)]
        case .download: return [IconLayer(d: "M19,9h-4V3H9v6H5l7,7 7,-7zM5,18v2h14v-2H5z", strokeWidth: nil)]
        case .folder: return [IconLayer(d: "M20,6h-8l-2,-2H4c-1.1,0 -1.99,0.9 -1.99,2L2,18c0,1.1 0.9,2 2,2h16c1.1,0 2,-0.9 2,-2V8c0,-1.1 -0.9,-2 -2,-2zM20,18H4V8h16v10z", strokeWidth: nil)]
        case .fullscreen: return [IconLayer(d: "M7,14L5,14v5h5v-2L7,17v-3zM5,10h2L7,7h3L10,5L5,5v5zM17,17h-3v2h5v-5h-2v3zM14,5v2h3v3h2L19,5h-5z", strokeWidth: nil)]
        case .fullscreenExit: return [IconLayer(d: "M5,16h3v3h2v-5L5,14v2zM8,8L5,8v2h5L10,5L8,5v3zM14,19h2v-3h3v-2h-5v5zM16,8L16,5h-2v5h5L19,8h-3z", strokeWidth: nil)]
        case .info: return [IconLayer(d: "M12,3a9,9 0,1 0,0 18a9,9 0,1 0,0 -18M12,11L12,17M12,7L12,7.1", strokeWidth: 1.8)]
        case .layers: return [IconLayer(d: "M11.99,18.54l-7.37,-5.73L3,14.07l9,7 9,-7 -1.63,-1.27 -7.38,5.74zM12,16l7.36,-5.73L21,9l-9,-7 -9,7 1.63,1.27L12,16z", strokeWidth: nil)]
        case .map: return [IconLayer(d: "M20.5,3l-0.16,0.03L15,5.1 9,3 3.36,4.9c-0.21,0.07 -0.36,0.25 -0.36,0.48V20.5c0,0.28 0.22,0.5 0.5,0.5l0.16,-0.03L9,18.9l6,2.1 5.64,-1.9c0.21,-0.07 0.36,-0.25 0.36,-0.48V3.5c0,-0.28 -0.22,-0.5 -0.5,-0.5zM15,19l-6,-2.11V5l6,2.11V19z", strokeWidth: nil)]
        case .menu: return [IconLayer(d: "M3,18h18v-2H3v2zM3,13h18v-2H3v2zM3,6v2h18V6H3z", strokeWidth: nil)]
        case .myLocation: return [IconLayer(d: "M12,8c-2.21,0 -4,1.79 -4,4s1.79,4 4,4 4,-1.79 4,-4 -1.79,-4 -4,-4zM20.94,11c-0.46,-4.17 -3.77,-7.48 -7.94,-7.94L13,1h-2v2.06C6.83,3.52 3.52,6.83 3.06,11L1,11v2h2.06c0.46,4.17 3.77,7.48 7.94,7.94L11,23h2v-2.06c4.17,-0.46 7.48,-3.77 7.94,-7.94L23,13v-2h-2.06zM12,19c-3.87,0 -7,-3.13 -7,-7s3.13,-7 7,-7 7,3.13 7,7 -3.13,7 -7,7z", strokeWidth: nil)]
        case .navigation: return [IconLayer(d: "M12,2L4.5,20.29l0.71,0.71L12,18l6.79,3 0.71,-0.71z", strokeWidth: nil)]
        case .north: return [IconLayer(d: "M9.5,8V2.5L14.5,8V2.5", strokeWidth: 1.6), IconLayer(d: "M12,10L16.5,21.5L12,19L7.5,21.5Z", strokeWidth: nil)]
        case .pause: return [IconLayer(d: "M6,19h4V5H6v14zM14,5v14h4V5h-4z", strokeWidth: nil)]
        case .play: return [IconLayer(d: "M8,5v14l11,-7z", strokeWidth: nil)]
        case .remove: return [IconLayer(d: "M19,13H5v-2h14v2z", strokeWidth: nil)]
        case .route: return [IconLayer(d: "M19,15.18V7c0,-2.21 -1.79,-4 -4,-4s-4,1.79 -4,4v10c0,1.1 -0.9,2 -2,2s-2,-0.9 -2,-2V8.82C8.16,8.4 9,7.3 9,6c0,-1.66 -1.34,-3 -3,-3S3,4.34 3,6c0,1.3 0.84,2.4 2,2.82V17c0,2.21 1.79,4 4,4s4,-1.79 4,-4V7c0,-1.1 0.9,-2 2,-2s2,0.9 2,2v8.18c-1.16,0.41 -2,1.51 -2,2.82c0,1.66 1.34,3 3,3s3,-1.34 3,-3C21,16.7 20.16,15.6 19,15.18z", strokeWidth: nil)]
        case .search: return [IconLayer(d: "M10.5,4a6.5,6.5 0,1 0,0 13a6.5,6.5 0,1 0,0 -13M15.2,15.2L21,21", strokeWidth: 2)]
        case .share: return [IconLayer(d: "M18,16.08c-0.76,0 -1.44,0.3 -1.96,0.77L8.91,12.7c0.05,-0.23 0.09,-0.46 0.09,-0.7s-0.04,-0.47 -0.09,-0.7l7.05,-4.11c0.54,0.5 1.25,0.81 2.04,0.81 1.66,0 3,-1.34 3,-3s-1.34,-3 -3,-3 -3,1.34 -3,3c0,0.24 0.04,0.47 0.09,0.7L8.04,9.81C7.5,9.31 6.79,9 6,9c-1.66,0 -3,1.34 -3,3s1.34,3 3,3c0.79,0 1.5,-0.31 2.04,-0.81l7.12,4.16c-0.05,0.21 -0.08,0.43 -0.08,0.65 0,1.61 1.31,2.92 2.92,2.92 1.61,0 2.92,-1.31 2.92,-2.92s-1.31,-2.92 -2.92,-2.92z", strokeWidth: nil)]
        case .sos: return [IconLayer(d: "M12,2C6.48,2 2,6.48 2,12s4.48,10 10,10 10,-4.48 10,-10S17.52,2 12,2zM13,17h-2v-2h2v2zM13,13h-2V7h2v6z", strokeWidth: nil)]
        case .sparkle: return [IconLayer(d: "M19,9l1.25,-2.75L23,5l-2.75,-1.25L19,1l-1.25,2.75L15,5l2.75,1.25L19,9zM11.5,9.5L9,4 6.5,9.5 1,12l5.5,2.5L9,20l2.5,-5.5L17,12l-5.5,-2.5zM19,15l-1.25,2.75L15,19l2.75,1.25L19,23l1.25,-2.75L23,19l-2.75,-1.25L19,15z", strokeWidth: nil)]
        case .stop: return [IconLayer(d: "M6,6h12v12H6z", strokeWidth: nil)]
        case .tune: return [IconLayer(d: "M3,17v2h6v-2H3zM3,5v2h10V5H3zM13,21v-2h8v-2h-8v-2h-2v6h2zM7,9v2H3v2h4v2h2V9H7zM21,13v-2H11v2h10zM15,9h2V7h4V5h-4V3h-2v6z", strokeWidth: nil)]
        case .upload: return [IconLayer(d: "M9,16h6v-6h4l-7,-7 -7,7h4zM5,18h14v2H5z", strokeWidth: nil)]
        case .walk: return [IconLayer(d: "M13.5,5.5c1.1,0 2,-0.9 2,-2s-0.9,-2 -2,-2 -2,0.9 -2,2 0.9,2 2,2zM9.8,8.9L7,23h2.1l1.8,-8 2.1,2v6h2v-7.5l-2.1,-2 0.6,-3C14.8,12 16.8,13 19,13v-2c-1.9,0 -3.5,-1 -4.3,-2.4l-1,-1.6c-0.4,-0.6 -1,-1 -1.7,-1 -0.3,0 -0.5,0.1 -0.8,0.1L6,8.3V13h2V9.6l1.8,-0.7", strokeWidth: nil)]
        case .warning: return [IconLayer(d: "M1,21h22L12,2 1,21zM13,18h-2v-2h2v2zM13,14h-2v-4h2v4z", strokeWidth: nil)]
        case .statHike: return [IconLayer(d: "M2,20L9,8L13,14.5L16,10.5L22,20Z", strokeWidth: nil)]
        case .reveal: return [IconLayer(d: "M10,3H5c-1.1,0 -2,0.9 -2,2v14c0,1.1 0.9,2 2,2h5v2h2V1h-2v2zM10,18H5l5,-6v6zM19,3h-5v2h5v13l-5,-6v9h5c1.1,0 2,-0.9 2,-2V5c0,-1.1 -0.9,-2 -2,-2z", strokeWidth: nil)]
        }
    }
}

/// A viewport-unit path scaled into whatever frame it is given.
private struct ScaledPath: Shape {
    let path: Path
    let viewport: CGFloat

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / viewport
        let dx = rect.minX + (rect.width - viewport * scale) / 2
        let dy = rect.minY + (rect.height - viewport * scale) / 2
        return path.applying(CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: dx, ty: dy))
    }
}

private enum IconCache {
    static var paths: [String: Path] = [:]
    static func path(_ d: String) -> Path {
        if let p = paths[d] { return p }
        let p = SVGPathParser.parse(d)
        paths[d] = p
        return p
    }
}

/// Draws one of the Android icons at `size` points in `color`.
struct TMIconView: View {
    let icon: TMIcon
    var size: CGFloat = 24
    var color: Color = .primary

    var body: some View {
        VectorIcon(layers: icon.layers, viewport: 24, size: size, color: color)
    }
}

struct VectorIcon: View {
    let layers: [IconLayer]
    let viewport: CGFloat
    var size: CGFloat
    var color: Color

    var body: some View {
        ZStack {
            ForEach(layers.indices, id: \.self) { index in
                let layer = layers[index]
                let shape = ScaledPath(path: IconCache.path(layer.d), viewport: viewport)
                if let width = layer.strokeWidth {
                    shape.stroke(color, style: StrokeStyle(lineWidth: width * size / viewport, lineCap: .round, lineJoin: .round))
                } else {
                    shape.fill(color)
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The outline-mountain launcher mark (ic_launcher_foreground) on the brand green.
struct TrailMindLogo: View {
    var size: CGFloat = 44
    private static let layers = [
        IconLayer(d: "M24,68L37,51L43,57L55,35L69,57L74,50L84,68M43,57L48,54L55,35L57,54L64,60M37,51L39,63M74,50L73,62L79,68", strokeWidth: 2.2),
        IconLayer(d: "M37,74L50,66L59,70L70,74", strokeWidth: 1.6),
    ]

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).fill(Color(argb: 0xFF1F5B45))
            VectorIcon(layers: Self.layers, viewport: 108, size: size * 1.5, color: .white)
        }
        .frame(width: size, height: size)
        .clipped()
        .accessibilityLabel("TrailMind")
    }
}
