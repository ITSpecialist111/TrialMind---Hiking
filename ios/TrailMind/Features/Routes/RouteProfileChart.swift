import Charts
import SwiftUI

/// Distance against height (ElevationProfileView), with an optional "you are here" cursor, drawn with Swift Charts.
struct RouteProfileChart: View {
    @Environment(\.palette) private var p
    let samples: [RouteProfileSample]
    let imperial: Bool
    var cursorM: Double? = nil

    var body: some View {
        if samples.count < 2 {
            Text("No elevation data in this GPX").tm(.caption, p)
                .frame(maxWidth: .infinity, minHeight: 140)
        } else {
            chart
        }
    }

    private var chart: some View {
        var low = samples.map(\.eleM).min()!
        var high = samples.map(\.eleM).max()!
        if high - low < 50 {
            let mid = (high + low) / 2
            low = mid - 25
            high = mid + 25
        }
        let lo = low
        let hi = high
        let total = max(samples[samples.count - 1].distanceM, 1.0)
        let fill = LinearGradient(colors: [p.primary.opacity(0.4), p.primary.opacity(0.03)], startPoint: .top, endPoint: .bottom)
        return Chart {
            ForEach(samples) { s in
                AreaMark(x: .value("Distance", s.distanceM), yStart: .value("Floor", lo), yEnd: .value("Height", s.eleM))
                    .foregroundStyle(fill)
                LineMark(x: .value("Distance", s.distanceM), y: .value("Height", s.eleM))
                    .foregroundStyle(p.primary)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineJoin: .round))
            }
            if let cursorM {
                let at = cursorM.clamped(0, total)
                RuleMark(x: .value("You", at))
                    .foregroundStyle(p.accent)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                if let near = samples.first(where: { $0.distanceM >= cursorM }) ?? samples.last {
                    PointMark(x: .value("You", at), y: .value("Height", near.eleM))
                        .foregroundStyle(p.accent)
                        .symbolSize(80)
                }
            }
        }
        .chartXScale(domain: 0...total)
        .chartYScale(domain: lo...hi)
        .chartYAxis {
            AxisMarks(position: .leading, values: [lo, (lo + hi) / 2, hi]) { value in
                AxisGridLine().foregroundStyle(p.outline)
                AxisValueLabel {
                    if let e = value.as(Double.self) {
                        Text(Units.elevation(e, imperial: imperial)).font(.caption2).foregroundStyle(p.muted)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: [0.0, total]) { value in
                AxisValueLabel(anchor: (value.as(Double.self) ?? 0) > 0 ? .topTrailing : .topLeading) {
                    Text((value.as(Double.self) ?? 0) > 0 ? Units.distance(total, imperial: imperial) : "0")
                        .font(.caption2).foregroundStyle(p.muted)
                }
            }
        }
        .frame(height: 140)
        .accessibilityElement()
        .accessibilityLabel("Elevation profile")
        .accessibilityValue("\(Units.distance(total, imperial: imperial)), from \(Units.elevation(samples.map(\.eleM).min()!, imperial: imperial)) " +
                            "to \(Units.elevation(samples.map(\.eleM).max()!, imperial: imperial))")
    }
}

/// A point of the profile: its distance along the whole line and its height.
struct RouteProfileSample: Identifiable, Hashable {
    let id: Int
    let distanceM: Double
    let eleM: Double

    /// At most about 600 samples, from the points that have a height (ElevationProfileView.setPoints).
    static func of(_ points: [TrackPoint]) -> [RouteProfileSample] {
        let withEle = points.indices.filter { points[$0].ele != nil }
        if withEle.count < 2 { return [] }
        let step = max(1, withEle.count / 600)
        let cumulative = Geo.cumulativeDistances(points)
        return withEle.enumerated().filter { $0.offset % step == 0 }.map { n, i in
            RouteProfileSample(id: n, distanceM: cumulative[i], eleM: points[i].ele!)
        }
    }
}
