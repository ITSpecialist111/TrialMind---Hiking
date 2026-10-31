import SwiftUI
import UIKit

/// What the display looks like right now on iPhone Duo (and nothing special elsewhere): the fold, the cameras, the hinge
/// and where the system puts vertical bars. Fed by `DuoProbe`, a UIKit view at the root of the window.
final class DuoState: ObservableObject {
    static let shared = DuoState()

    enum Hinge: String { case unavailable = "Not available", unknown = "Unknown", closed = "Closed", partiallyOpen = "Partially open", fullyOpen = "Fully open" }

    /// The active fold (a `.division` reserved region) in window coordinates, or nil when flat or closed.
    @Published var fold: CGRect? = nil
    /// Every division region, active or not, for diagnostics.
    @Published var allDivisions: [CGRect] = []
    /// Camera areas that cover content (`.occlusion` reserved regions), in window coordinates.
    @Published var occlusions: [CGRect] = []
    /// Where the system places vertical bars (status bar, toolbars, tab bars), or nil where it never does.
    @Published var verticalBarEdge: HorizontalEdge? = nil
    @Published var hinge: Hinge = .unavailable
    /// Hinge angle in degrees, when the system reports one.
    @Published var hingeAngle: Double? = nil
    @Published var windowSize: CGSize = .zero
    @Published var safeArea: UIEdgeInsets = .zero
    @Published var sizeClass: String = ""

    /// The iOS 27.1 foldable APIs exist on this system.
    var supportsDuoAPIs: Bool {
        if #available(iOS 27.1, *) { return true }
        return false
    }

    /// The fold splits the window left and right (book pose) rather than top and bottom (tabletop).
    var foldIsVertical: Bool { fold.map { $0.height >= $0.width } ?? false }

    func update(fold: CGRect?, allDivisions: [CGRect], occlusions: [CGRect]) {
        if self.fold != fold { self.fold = fold }
        if self.allDivisions != allDivisions { self.allDivisions = allDivisions }
        if self.occlusions != occlusions { self.occlusions = occlusions }
    }
}

/// Hosts the UIKit-only Duo APIs: `UIHingeInteraction`, `UIView.reservedRegions` and the `verticalBarEdge` trait.
struct DuoProbe: UIViewRepresentable {
    func makeUIView(context: Context) -> DuoProbeView { DuoProbeView() }
    func updateUIView(_ uiView: DuoProbeView, context: Context) { uiView.scheduleRefresh() }
}

final class DuoProbeView: UIView {
    private var registered = false
    private var refreshQueued = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        if #available(iOS 27.1, *) {
            let interaction = UIHingeInteraction { [weak self] _, update in
                guard let self else { return }
                let state = DuoState.shared
                if let hinge = update.hinge {
                    let status: DuoState.Hinge
                    switch hinge.status {
                    case .closed: status = .closed
                    case .partiallyOpen: status = .partiallyOpen
                    case .fullyOpen: status = .fullyOpen
                    default: status = .unknown
                    }
                    state.hinge = status
                    state.hingeAngle = Double(hinge.angle) * 180 / .pi
                } else {
                    state.hinge = .unavailable
                    state.hingeAngle = nil
                }
                // Folding changes the division region without changing this view's bounds.
                self.scheduleRefresh()
            }
            addInteraction(interaction)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if #available(iOS 27.1, *), !registered, window != nil {
            registered = true
            registerForTraitChanges(UITraitCollection.systemTraitsAffectingVerticalBarEdge) { (view: DuoProbeView, _: UITraitCollection) in
                view.scheduleRefresh()
            }
        }
        scheduleRefresh()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scheduleRefresh()
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        scheduleRefresh()
    }

    /// Publishes on the next turn of the main loop: these callbacks run inside SwiftUI and UIKit layout passes, where
    /// changing observed state would re-enter the update.
    func scheduleRefresh() {
        guard !refreshQueued else { return }
        refreshQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshQueued = false
            self.refresh()
        }
    }

    func refresh() {
        let state = DuoState.shared
        guard let window else { return }
        if state.windowSize != window.bounds.size { state.windowSize = window.bounds.size }
        if state.safeArea != window.safeAreaInsets { state.safeArea = window.safeAreaInsets }
        let classes = "w:\(traitCollection.horizontalSizeClass == .regular ? "regular" : "compact") h:\(traitCollection.verticalSizeClass == .regular ? "regular" : "compact")"
        if state.sizeClass != classes { state.sizeClass = classes }
        if let scene = window.windowScene { LocationHub.shared.setInterfaceOrientation(scene.effectiveGeometry.interfaceOrientation) }
        guard #available(iOS 27.1, *) else { return }
        let edge: HorizontalEdge?
        switch traitCollection.verticalBarEdge {
        case .leading: edge = .leading
        case .trailing: edge = .trailing
        default: edge = nil
        }
        if state.verticalBarEdge != edge { state.verticalBarEdge = edge }
        let divisions = reservedRegions(kind: .division, options: .includeInactive)
        let occlusions = reservedRegions(kind: .occlusion)
        func toWindow(_ r: CGRect) -> CGRect { convert(r, to: window) }
        state.update(fold: divisions.first(where: { $0.isActive }).map { toWindow($0.frame) },
                     allDivisions: divisions.map { toWindow($0.frame) },
                     occlusions: occlusions.filter { $0.isActive }.map { toWindow($0.frame) })
    }
}

extension DuoState {
    /// A plain-text summary for the Display diagnostics page and bug reports.
    var diagnostics: [(String, String)] {
        func r(_ rect: CGRect) -> String { "x \(Int(rect.minX)) y \(Int(rect.minY)) \(Int(rect.width))×\(Int(rect.height))" }
        return [
            ("iOS 27.1 fold APIs", supportsDuoAPIs ? "Available" : "Not on this iOS"),
            ("Window", "\(Int(windowSize.width))×\(Int(windowSize.height)) pt"),
            ("Size classes", sizeClass),
            ("Safe area", "top \(Int(safeArea.top)) left \(Int(safeArea.left)) bottom \(Int(safeArea.bottom)) right \(Int(safeArea.right))"),
            ("Vertical bars", verticalBarEdge.map { $0 == .leading ? "Leading edge" : "Trailing edge" } ?? "Not used here"),
            ("Hinge", hinge.rawValue + (hingeAngle.map { String(format: " · %.0f°", $0) } ?? "")),
            ("Fold", fold.map { r($0) + (foldIsVertical ? " (book)" : " (tabletop)") } ?? "None active"),
            ("Fold regions", allDivisions.isEmpty ? "None" : allDivisions.map(r).joined(separator: "; ")),
            ("Camera regions", occlusions.isEmpty ? "None" : occlusions.map(r).joined(separator: "; ")),
        ]
    }
}
