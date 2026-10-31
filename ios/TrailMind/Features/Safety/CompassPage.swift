import CoreLocation
import CoreMotion
import SwiftUI

/// The compass (ui/Pages2.kt CompassPage): a rose that turns so north points north, the heading true and magnetic, the
/// bearing to the map target or the followed route's next waypoint, your position, daylight and the barometer.
struct CompassPage: View {
    @Environment(\.palette) private var p
    @StateObject private var position = SafetyFixWatcher()
    @ObservedObject private var prefs = Prefs.shared
    @ObservedObject private var map = MapController.shared
    @ObservedObject private var guidance = Guidance.shared
    @ObservedObject private var pressure = PressureWatch.shared

    init() {}

    var body: some View {
        let target = bearingTo()
        PageScaffold("Compass") {
            ListItemRow(title: "Satellites & telemetry", subtitle: "GPS quality and sensors", icon: .myLocation) {
                Navigator.shared.push(SafetyFeature.telemetryRoute)
            }
            if !CLLocationManager.headingAvailable() {
                TMBanner(message: "This device has no magnetometer, so the compass is unavailable. Use GPS bearing while moving.", danger: true)
            }
            CompassReadout(targetBearingDeg: target.bearingDeg)
            TMCard(spacing: 4) {
                TMText("Bearing to", .label)
                TMText(target.text)
            }
            positionCard
            TMCard(spacing: 4) {
                TMText("Daylight", .label)
                TMText(daylight)
            }
            pressureCard
            TMText("Hold the phone flat, or upright with its back facing the way you look. Headings are true north (magnetic declination from your GPS position is applied). Grid references are OSGB36 (±5 m conversion) and only valid in Great Britain.", .caption)
        }
        .onAppear {
            SafetyFeature.start()
            CompassMonitor.shared.acquire()
            LocationHub.shared.requestBarometer()
        }
        .onDisappear { CompassMonitor.shared.release() }
    }

    /// The map target, else the followed route's next waypoint, else the way the route heads (CompassPage.update).
    private func bearingTo() -> (text: String, bearingDeg: Double?) {
        let core = guidance.core
        return SafetyText.compassTarget(here: position.fix?.latLon, target: map.target?.position,
                                        guide: core.active != nil ? core.fix : nil, offRoute: core.offRoute,
                                        imperial: prefs.imperial)
    }

    private var positionCard: some View {
        TMCard(spacing: 4) {
            TMText("Your position", .label)
            if let f = position.fix {
                Text(OsGrid.fromWgs84(f.latLon)?.format(10) ?? Units.latLon(f.lat, f.lon))
                    .tm(.headline, p)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .textSelection(.enabled)
                TMText(SafetyText.compassPosition(lat: f.lat, lon: f.lon, accuracyM: Double(f.accuracyM), altitudeM: f.altitudeM,
                                                  barometric: f.baroAltitudeM != nil, fixTime: SafetyFormat.clock(f.timeMs),
                                                  imperial: prefs.imperial), .caption)
            } else {
                TMText("No GPS fix", .headline)
                TMText(position.hasPermission ? "Go outside with a clear view of the sky." : "Location permission is off.", .caption)
            }
        }
    }

    private var daylight: String {
        guard let f = position.fix else { return "Needs a GPS fix." }
        return SafetyText.daylight(Sun.today(f.latLon), nowMs: nowMs()) { ms in ms.map(SafetyFormat.clock) ?? "—" }
    }

    // MARK: Barometer

    private var pressureCard: some View {
        let available = CMAltimeter.isRelativeAltitudeAvailable()
        let status = CMAltimeter.authorizationStatus()
        let refused = status == .denied || status == .restricted
        return TMCard(spacing: 4) {
            TMText("Air pressure", .label)
            if !available {
                TMText("This iPhone has no barometer.")
            } else if refused {
                TMText("Allow Motion & Fitness for TrailMind in Settings to read the barometer.")
                TMButton("Open Settings", style: .text) { AppModel.shared.openSettings() }
            } else {
                TMText(pressure.summary ?? "Waiting for the barometer…")
            }
        }
    }
}

/// The compass card and its warnings, which redraw with every heading (CompassPage.updateHeading).
private struct CompassReadout: View {
    @Environment(\.palette) private var p
    @ObservedObject private var hub = LocationHub.shared
    @ObservedObject private var monitor = CompassMonitor.shared
    let targetBearingDeg: Double?

    var body: some View {
        let heading = hub.headingDeg
        let unreliable = hub.compassUnreliable
        let disturbed = monitor.disturbed
        if unreliable && heading != nil {
            TMBanner(message: "Compass accuracy is low. Move the phone in a figure-of-eight away from metal, magnets and the phone case clasp.")
        }
        if disturbed && !unreliable && heading != nil {
            TMBanner(message: "Magnetic interference: the compass may be wrong here. Move away from metal, magnets and electronics, then move the phone in a figure-of-eight.")
        }
        TMCard(padding: 12) {
            CompassDial(headingDeg: heading, targetBearingDeg: targetBearingDeg, unreliable: unreliable || disturbed)
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: 360)
                .frame(maxWidth: .infinity)
            Text(SafetyText.heading(trueDeg: heading, declinationDeg: monitor.declinationDeg))
                .tm(.caption, p)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
        }
    }
}

/// The compass rose (ui/Views.kt CompassView): it turns so north points north, with a lubber mark for the way the phone
/// points, ticks every 5°, the cardinal letters, the north needle and an orange mark on the bearing to the target.
struct CompassDial: View {
    @Environment(\.palette) private var p
    let headingDeg: Double?
    let targetBearingDeg: Double?
    let unreliable: Bool

    var body: some View {
        let centre = SafetyText.dialCentre(headingDeg, unreliable: unreliable)
        Canvas { context, size in
            draw(&context, size, centre)
        }
        .accessibilityElement()
        .accessibilityLabel("Compass")
        .accessibilityValue(centre.bearing + " " + centre.sub)
    }

    private func draw(_ context: inout GraphicsContext, _ size: CGSize, _ centre: (bearing: String, sub: String)) {
        let cx = size.width / 2
        let cy = size.height / 2
        let r = min(size.width, size.height) / 2 - 16
        guard r > 24 else { return }
        let face = Path(ellipseIn: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r))
        context.fill(face, with: .color(p.surface))
        context.stroke(face, with: .color(p.outline), lineWidth: 2)
        // Lubber line: the direction the phone points.
        context.fill(triangle(CGPoint(x: cx, y: cy - r - 12), CGPoint(x: cx - 9, y: cy - r + 4), CGPoint(x: cx + 9, y: cy - r + 4)),
                     with: .color(p.primary))

        var dial = context
        dial.translateBy(x: cx, y: cy)
        dial.rotate(by: .degrees(-(headingDeg ?? 0)))
        for deg in stride(from: 0, to: 360, by: 5) {
            let major = deg % 30 == 0
            let length: CGFloat = major ? 14 : 7
            let a = toRadians(Double(deg))
            var tick = Path()
            tick.move(to: CGPoint(x: (r - 4) * sin(a), y: -(r - 4) * cos(a)))
            tick.addLine(to: CGPoint(x: (r - 4 - length) * sin(a), y: -(r - 4 - length) * cos(a)))
            dial.stroke(tick, with: .color(major ? p.onSurface : p.muted), style: StrokeStyle(lineWidth: major ? 3 : 1.5, lineCap: .round))
        }
        let letterSize = r * 0.16
        for (i, letter) in ["N", "E", "S", "W"].enumerated() {
            var c = dial
            c.rotate(by: .degrees(Double(i) * 90))
            c.draw(Text(letter).font(.system(size: letterSize, weight: .bold)).foregroundStyle(i == 0 ? p.danger : p.onSurface),
                   at: CGPoint(x: 0, y: -r + 30 + letterSize * 0.15))
        }
        let numberSize = r * 0.08
        for deg in [30, 60, 120, 150, 210, 240, 300, 330] {
            var c = dial
            c.rotate(by: .degrees(Double(deg)))
            c.draw(Text(verbatim: String(deg)).font(.system(size: numberSize, weight: .bold)).foregroundStyle(p.muted),
                   at: CGPoint(x: 0, y: -r + 30 + numberSize * 0.05))
        }
        dial.fill(triangle(CGPoint(x: 0, y: -r * 0.55), CGPoint(x: -10, y: 0), CGPoint(x: 10, y: 0)), with: .color(p.danger))
        if let bearing = targetBearingDeg {
            var c = dial
            c.rotate(by: .degrees(bearing))
            c.fill(triangle(CGPoint(x: 0, y: -r + 2), CGPoint(x: -11, y: -r + 22), CGPoint(x: 11, y: -r + 22)), with: .color(p.accent))
        }

        context.fill(Path(ellipseIn: CGRect(x: cx - r * 0.3, y: cy - r * 0.3, width: r * 0.6, height: r * 0.6)), with: .color(p.surface))
        let bearingSize = r * 0.2
        context.draw(Text(centre.bearing).font(.system(size: bearingSize, weight: .medium)).foregroundStyle(p.onSurface),
                     at: CGPoint(x: cx, y: cy - bearingSize * 0.15))
        let subSize = r * 0.09
        context.draw(Text(centre.sub).font(.system(size: subSize)).foregroundStyle(p.muted),
                     at: CGPoint(x: cx, y: cy + r * 0.17 - subSize * 0.35))
    }

    private func triangle(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> Path {
        var path = Path()
        path.move(to: a)
        path.addLine(to: b)
        path.addLine(to: c)
        path.closeSubpath()
        return path
    }
}
