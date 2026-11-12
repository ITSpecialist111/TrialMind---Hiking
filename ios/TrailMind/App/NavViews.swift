import SwiftUI

/// The phone's navigation (MainActivity.buildCapsule): a dark capsule floating over the map. Each destination is an
/// icon; the one you are on opens into a mint pill with its label. On iPhone Duo's outer display it stands on the
/// vertical-bar edge instead, icons only, like the system's own bars there.
struct NavCapsule: View {
    @Environment(\.palette) private var p
    @ObservedObject var nav: Navigator
    let tabs: [Tab]
    var vertical: Bool = false

    var body: some View {
        let selected = nav.selected(in: tabs)
        let layout = vertical ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
        layout {
            ForEach(tabs) { t in
                let isOn = t == selected
                Button { nav.show(t) } label: {
                    HStack(spacing: 8) {
                        TMIconView(icon: t.icon, size: 24, color: isOn ? p.onNavSelected : p.inverseMuted)
                        if isOn && !vertical {
                            Text(t.label).font(.system(.subheadline, weight: .medium)).foregroundStyle(p.onNavSelected).lineLimit(1)
                                .fixedSize()
                        }
                    }
                    .padding(.horizontal, vertical ? 0 : 14)
                    .frame(minWidth: 48, minHeight: 48)
                    .background(Capsule().fill(isOn ? p.navSelected : .clear))
                    .contentShape(Capsule())
                }
                .buttonStyle(PressScaleStyle())
                .accessibilityLabel(t.label)
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
        .padding(6)
        .background(
            Capsule().fill(p.inverse)
                .overlay(Capsule().strokeBorder(p.glassStroke, lineWidth: 1))
                .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
        )
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: selected)
    }
}

/// The wide layout's navigation rail (MainActivity.buildNavBar vertical): logo, then destinations with a pill behind
/// the selected icon and a label under each.
struct NavRail: View {
    @Environment(\.palette) private var p
    @ObservedObject var nav: Navigator
    let tabs: [Tab]
    var logo: Bool = true
    let opacity: Double

    var body: some View {
        let selected = nav.selected(in: tabs)
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 4) {
                if logo { TrailMindLogo(size: 44).padding(.top, 8).padding(.bottom, 12) }
                ForEach(tabs) { t in
                    let isOn = t == selected
                    Button { nav.show(t) } label: {
                        VStack(spacing: 4) {
                            TMIconView(icon: t.icon, size: 24, color: isOn ? p.onNavSelected : p.muted)
                                .frame(width: 56, height: 32)
                                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(isOn ? p.navSelected : .clear))
                            Text(t.label).font(.system(size: 11.5, weight: .medium)).foregroundStyle(isOn ? p.onSurface : p.muted)
                                .lineLimit(1).minimumScaleFactor(0.8)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressScaleStyle())
                    .accessibilityLabel(t.label)
                    .accessibilityAddTraits(isOn ? .isSelected : [])
                }
            }
            .padding(.top, 8)
        }
        .frame(width: ShellGeometry.railWidth)
        .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(p.bg.opacity(opacity)))
    }
}
