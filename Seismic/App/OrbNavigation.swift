import SwiftUI

/// The navigation dock and the bloom it opens.
///
/// A seismic app has fourteen screens and a phone has room for about five. The
/// usual answer is an overflow menu, which this app had, and an overflow menu is
/// where features go to be forgotten — a flat grey list, alphabetical by
/// accident, indistinguishable from every other flat grey list.
///
/// So: four tabs, and a raised orb between them that fans every remaining
/// section out across an arc. It is faster than a menu (one press, then a
/// direction rather than a target), it shows all nine at once instead of
/// scrolling, and the muscle memory it builds is angular — after a day you
/// reach for *up-and-left* rather than reading anything at all.
///
/// The dock and the bloom share `OrbDock`'s metrics so the fan's origin lands
/// exactly on the orb. Getting that wrong by even a few points is instantly
/// visible: the items stop looking like they came out of the button.

// MARK: - Shared metrics

enum OrbDock {
    /// The dock's own height, excluding the gap beneath it.
    static let height: CGFloat = 66
    /// The orb's diameter. Sized to nearly fill the dock's height so it reads as
    /// the hub without overhanging the bar and looking misaligned.
    static let orbDiameter: CGFloat = 52
    /// The gap between the dock and the bottom of the safe area.
    static let bottomInset: CGFloat = 10

    /// A tile in the fan the orb opens, and the width its label is allowed.
    /// Both feed the arc's geometry, so they live here rather than as literals
    /// at the point of use.
    static let bloomTile: CGFloat = 44
    static let bloomLabelWidth: CGFloat = 64

    /// The vertical space a screen must leave clear so the floating dock never
    /// covers the last row of its content.
    static var clearance: CGFloat { height + bottomInset + 8 }

    /// The centre of the orb, measured up from the bottom of the safe area.
    /// The bloom fans out from exactly here.
    static var orbCentreFromBottom: CGFloat { bottomInset + height / 2 }
}

// MARK: - Labels

extension AppSection {
    /// The dock is 44pt of width per tab; "Preparedness" does not fit in it and
    /// a truncated word is worse than a shorter one chosen on purpose.
    var shortTitle: String {
        switch self {
        case .simulator: "Simulate"
        case .prepare: "Prepare"
        case .shakeTable: "Shake"
        case .analysis: "Analyse"
        default: title
        }
    }
}

// MARK: - The dock

struct OrbNavigationDock: View {
    let tabs: [AppSection]
    let selection: AppSection
    let isBloomOpen: Bool
    let onSelect: (AppSection) -> Void
    let onOrbTap: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var pill
    @State private var pulsing = false

    var body: some View {
        HStack(spacing: 2) {
            ForEach(tabs.prefix(2)) { tabButton($0) }
            orbButton
                .padding(.horizontal, 4)
            ForEach(tabs.dropFirst(2)) { tabButton($0) }
        }
        .padding(.horizontal, 10)
        .frame(height: OrbDock.height)
        .liquidGlass(in: Capsule(style: .continuous))
        .padding(.horizontal, 14)
        .padding(.bottom, OrbDock.bottomInset)
        .animation(Theme.Motion.standard, value: selection)
        .animation(Theme.Motion.standard, value: isBloomOpen)
    }

    // MARK: Tabs

    private func tabButton(_ section: AppSection) -> some View {
        // A tab stops looking selected while the bloom is open, because at that
        // moment the orb is what you are interacting with and two lit things
        // would be two claims about where you are.
        let isActive = section == selection && !isBloomOpen
        return Button {
            Haptics.shared.play(.selection)
            onSelect(section)
        } label: {
            VStack(spacing: 3) {
                Image(systemName: section.systemImage)
                    .font(.system(size: 18, weight: .medium))
                    .symbolVariant(isActive ? .fill : .none)
                    .frame(height: 22)
                Text(section.shortTitle)
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .foregroundStyle(isActive ? Theme.Palette.textPrimary : Theme.Palette.textGhost)
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background {
                if isActive {
                    RoundedRectangle(cornerRadius: 17, style: .continuous)
                        .fill(LinearGradient(
                            colors: [Theme.Palette.accent.opacity(0.42),
                                     Theme.Palette.accentSecondary.opacity(0.30)],
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                        .overlay(
                            RoundedRectangle(cornerRadius: 17, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.20), lineWidth: 1))
                        // The pill slides between tabs rather than cross-fading.
                        // The travel is the only thing that tells you *which
                        // way* you just moved through the app.
                        .matchedGeometryEffect(id: "activeTab", in: pill)
                        .shadow(color: Theme.Palette.accentSecondary.opacity(0.45),
                                radius: 10, y: 4)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(LiquidPressStyle())
        .accessibilityLabel(section.title)
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
    }

    // MARK: The orb

    private var orbButton: some View {
        Button {
            Haptics.shared.play(.selection)
            onOrbTap()
        } label: {
            ZStack {
                Circle()
                    .fill(Theme.Palette.accentGradient)
                Circle()
                    .strokeBorder(Color.white.opacity(0.42), lineWidth: 1)
                Circle()
                    .fill(LinearGradient(
                        colors: [Color.white.opacity(0.34), .clear],
                        startPoint: .top, endPoint: .center))
                Image(systemName: isBloomOpen ? "xmark" : "square.grid.2x2.fill")
                    .font(.system(size: isBloomOpen ? 17 : 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .contentTransition(.symbolEffect(.replace))
            }
            .frame(width: OrbDock.orbDiameter, height: OrbDock.orbDiameter)
            .rotationEffect(.degrees(isBloomOpen ? 90 : 0))
            .shadow(color: Theme.Palette.accentSecondary.opacity(0.75), radius: 16, y: 8)
            .background(alignment: .center) { pulseRing }
        }
        .buttonStyle(LiquidPressStyle(pressedScale: 0.92))
        .accessibilityLabel(isBloomOpen ? "Close sections" : "All sections")
    }

    /// A ring that breathes outwards from the orb, so a first-time user's eye
    /// is drawn to the one control on screen that is not self-explanatory. It
    /// stops the moment the bloom is open — the invitation has been accepted,
    /// and a control that keeps advertising itself after you have used it is
    /// just noise.
    @ViewBuilder
    private var pulseRing: some View {
        if !isBloomOpen && !reduceMotion {
            Circle()
                .strokeBorder(Theme.Palette.accent.opacity(0.5), lineWidth: 1.5)
                .frame(width: OrbDock.orbDiameter + 8, height: OrbDock.orbDiameter + 8)
                .scaleEffect(pulsing ? 1.36 : 1)
                .opacity(pulsing ? 0 : 0.5)
                .onAppear {
                    withAnimation(.easeOut(duration: 2.8).repeatForever(autoreverses: false)) {
                        pulsing = true
                    }
                }
                .allowsHitTesting(false)
        }
    }
}

// MARK: - The bloom

/// Every section that has no tab, fanned across an arc above the orb.
///
/// The arc is computed rather than hard-coded, because the radius that keeps
/// the outermost item on screen depends on how many items there are and how
/// wide the phone is. Hard-coding it produced exactly one good-looking device.
struct NavigationBloom: View {
    let items: [AppSection]
    /// The section currently on screen, pre-highlighted so the fan tells you
    /// where you are as well as where you can go.
    let current: AppSection
    let onPick: (AppSection) -> Void
    let onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isOpen = false
    /// The item a finger is currently over, or nil for none. Deliberately not
    /// defaulted to the first item: one tile lit for no reason reads as a bug.
    @State private var focus: Int?

    /// Stretches the arc vertically only, so it is not cramped top-to-bottom.
    /// The horizontal budget ignores it, which is the whole point — width is
    /// what runs out first on a phone, and stretching that would push the
    /// outermost tiles off the screen.
    private let verticalStretch: CGFloat = 1.5

    /// How far above the orb the arc is centred.
    ///
    /// Centring it exactly on the orb puts the two end tiles level with the
    /// dock, which then sits on top of their labels. Lifting the whole fan by
    /// rather less than a tile clears that without the arc looking detached
    /// from the button it came out of.
    private let liftAboveOrb: CGFloat = 20

    var body: some View {
        ZStack {
            scrim
            GeometryReader { proxy in
                let origin = CGPoint(
                    x: proxy.size.width / 2,
                    y: proxy.size.height - OrbDock.orbCentreFromBottom - liftAboveOrb)
                let radius = ringRadius(in: proxy.size)
                ZStack {
                    // Only just enough spacing for two tiles that end up nearly
                    // touching to fuse at the edges. More than this and the
                    // whole fan runs together into one blob.
                    LiquidGlassGroup(spacing: 8) {
                        ForEach(Array(items.enumerated()), id: \.element) { index, section in
                            tile(section, index: index)
                                .position(origin)
                                .offset(isOpen ? placement(index: index, radius: radius) : .zero)
                                .animation(entrance(index: index), value: isOpen)
                        }
                    }
                }
                .contentShape(Rectangle())
                // Press the orb, keep your thumb down, sweep to the section you
                // want and let go. Direct taps still work — the 14pt minimum
                // means a tap is never stolen from the tile underneath.
                .gesture(
                    DragGesture(minimumDistance: 14)
                        .onChanged { value in
                            updateFocus(towards: value.location, from: origin, radius: radius)
                        }
                        .onEnded { _ in
                            if let focus, items.indices.contains(focus) {
                                pick(items[focus])
                            }
                        }
                )
            }
            hint
        }
        .onAppear {
            withAnimation(Theme.Motion.gentle) { isOpen = true }
            focus = items.firstIndex(of: current)
            Haptics.shared.play(.selection)
        }
    }

    // MARK: Pieces

    /// Dark enough that the fan is unmistakably the foreground, light enough
    /// that the screen underneath is still recognisably there — this is a menu
    /// over the app, not a different place.
    private var scrim: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .environment(\.colorScheme, .dark)
            .overlay(Color.black.opacity(0.22))
            .opacity(isOpen ? 1 : 0)
            .ignoresSafeArea()
            .onTapGesture { dismiss() }
            .animation(Theme.Motion.quick, value: isOpen)
    }

    private func tile(_ section: AppSection, index: Int) -> some View {
        let isFocused = focus == index
        return Button {
            pick(section)
        } label: {
            VStack(spacing: 5) {
                Image(systemName: section.systemImage)
                    .font(.system(size: 19, weight: .medium))
                    .symbolVariant(isFocused ? .fill : .none)
                    .foregroundStyle(isFocused ? AnyShapeStyle(Color.white)
                                               : AnyShapeStyle(Theme.Palette.accent))
                    .frame(width: OrbDock.bloomTile, height: OrbDock.bloomTile)
                    .liquidGlass(in: RoundedRectangle(cornerRadius: 15, style: .continuous),
                                 tint: isFocused ? Theme.Palette.accent : nil,
                                 interactive: true)
                    .shadow(color: Theme.Palette.accentSecondary.opacity(isFocused ? 0.7 : 0),
                            radius: 14, y: 6)

                Text(section.shortTitle)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: OrbDock.bloomLabelWidth)
                    // The fan sits over live app content, which is sometimes a
                    // chart and sometimes a map. Nothing behind it is reliably
                    // dark, so each label carries its own contrast with it.
                    .shadow(color: .black.opacity(0.8), radius: 5)
            }
            .scaleEffect(isOpen ? (isFocused ? 1.09 : 1) : 0.3)
            .opacity(isOpen ? 1 : 0)
        }
        .buttonStyle(LiquidPressStyle())
        .animation(Theme.Motion.standard, value: focus)
        .accessibilityLabel(section.title)
    }

    /// One line at the top, because a radial menu is not a convention anybody
    /// arrives already knowing.
    private var hint: some View {
        VStack {
            Text("Sweep to choose · tap anywhere to close")
                .font(Theme.Typography.label)
                .tracking(0.4)
                .foregroundStyle(Theme.Palette.textTertiary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .liquidGlass(in: Capsule(style: .continuous), lifted: false)
                .padding(.top, 6)
                .opacity(isOpen ? 1 : 0)
                .animation(Theme.Motion.gentle.delay(0.18), value: isOpen)
            Spacer()
        }
    }

    // MARK: Geometry

    /// The fan's width in degrees. Wider for more items, and capped well short
    /// of a half-circle: an item level with the orb is one your thumb has to
    /// travel sideways to reach, which is the slowest direction there is, and
    /// it is also the one place the dock is in the way.
    private var span: Double { min(140, 50 + Double(items.count) * 12) }

    /// Alternate items sit closer in. One arc of nine tiles does not fit across
    /// a phone: the angle between neighbours works out at about fifty points of
    /// arc, and a tile is forty-four wide before its label. Pulling every other
    /// one inwards roughly doubles the gap between neighbours without needing a
    /// single extra point of width — which is the dimension that ran out.
    ///
    /// Only worth doing when there are enough items to crowd. Below that a
    /// staggered arc just looks like a wonky one.
    private var isStaggered: Bool { items.count > 6 }

    /// Even indices stay on the outer arc — which puts both ends and the top of
    /// the fan there, so its silhouette is still an arc rather than a zigzag
    /// with a notch cut out of the middle of it.
    private func tierScale(_ index: Int) -> CGFloat {
        guard isStaggered, !index.isMultiple(of: 2) else { return 1 }
        return 0.68
    }

    /// The largest radius that keeps the outermost tile fully on screen with
    /// clear air at the edges, floored so a small fan on a wide screen does not
    /// collapse into a cramped little ring.
    private func ringRadius(in size: CGSize) -> CGFloat {
        let halfSpan = (span / 2) * .pi / 180
        let width = min(size.width, 560)
        // The outermost tile's centre reaches R·sin(halfSpan) horizontally, so
        // the budget is half the width, less a margin. The margin is measured
        // against the *label*, not the tile: the label is the wider of the two,
        // and it is the one that reads as broken when it touches the bezel.
        let margin = OrbDock.bloomLabelWidth / 2 + 10
        let byWidth = (width / 2 - margin) / CGFloat(max(sin(halfSpan), 0.05))
        let byHeight = (size.height - 150) / verticalStretch
        return max(146, min(byWidth, byHeight, 260))
    }

    /// Where item `index` sits, as an offset from the orb. Angles run from the
    /// left end of the fan to the right, measured the usual way (0° is east,
    /// 90° is straight up), so the arc is centred on straight-up.
    private func placement(index: Int, radius: CGFloat) -> CGSize {
        let radians = angle(forIndex: index) * .pi / 180
        let r = radius * tierScale(index)
        return CGSize(width: cos(radians) * r,
                      height: -sin(radians) * r * verticalStretch)
    }

    /// The angle item `index` sits at, in degrees, 90° being straight up.
    private func angle(forIndex index: Int) -> Double {
        guard items.count > 1 else { return 90 }
        let start = 90 + span / 2
        let end = 90 - span / 2
        return start + (end - start) * (Double(index) / Double(items.count - 1))
    }

    /// Maps a finger position to the nearest item on the arc.
    ///
    /// Compared by angle rather than by distance, so a sweep that falls short of
    /// the ring still selects — the direction is what the user meant, and
    /// insisting they reach the exact radius would make the gesture feel broken
    /// on a large phone held one-handed.
    private func updateFocus(towards point: CGPoint, from origin: CGPoint, radius: CGFloat) {
        let dx = point.x - origin.x
        let dy = (point.y - origin.y) / verticalStretch
        guard hypot(dx, dy) > 44 else { return }
        let bearing = atan2(-dy, dx) * 180 / .pi
        let nearest = items.indices.min { a, b in
            abs(bearing - angle(forIndex: a)) < abs(bearing - angle(forIndex: b))
        }
        guard nearest != focus else { return }
        focus = nearest
        Haptics.shared.play(.selection)
    }

    /// Items arrive one after another rather than together. Thirty milliseconds
    /// apart is enough to read as a sweep and not enough to feel slow.
    private func entrance(index: Int) -> Animation {
        guard !reduceMotion else { return .easeOut(duration: 0.15) }
        return .spring(response: 0.5, dampingFraction: 0.78)
            .delay(0.02 + Double(index) * 0.03)
    }

    // MARK: Actions

    // The exit is the caller's transition, not ours. Animating `isOpen` back to
    // false here would be animating a view that is about to be removed from the
    // hierarchy in the same frame — which plays nothing at all.
    private func pick(_ section: AppSection) {
        Haptics.shared.play(.selection)
        onPick(section)
    }

    private func dismiss() {
        onDismiss()
    }
}

#Preview {
    ZStack {
        AmbientBackground().ignoresSafeArea()
        VStack {
            Spacer()
            OrbNavigationDock(tabs: [.home, .monitor, .simulator, .map],
                              selection: .home,
                              isBloomOpen: false,
                              onSelect: { _ in },
                              onOrbTap: {})
        }
    }
}
