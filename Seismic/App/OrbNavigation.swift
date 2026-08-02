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

    var body: some View {
        ZStack {
            scrim
            GeometryReader { proxy in
                let origin = CGPoint(
                    x: proxy.size.width / 2,
                    y: proxy.size.height - OrbDock.orbCentreFromBottom)
                let plan = Layout(count: items.count, size: proxy.size)
                ZStack {
                    // Only just enough spacing for two tiles that end up nearly
                    // touching to fuse at the edges. More than this and the
                    // whole fan runs together into one blob.
                    LiquidGlassGroup(spacing: 8) {
                        ForEach(Array(items.enumerated()), id: \.element) { index, section in
                            tile(section, index: index)
                                .position(origin)
                                .offset(isOpen ? plan.offset(of: index) : .zero)
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
                            updateFocus(towards: value.location, from: origin, plan: plan)
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

    /// Where every tile goes.
    ///
    /// This was a single arc, and a single arc is wrong past about six items.
    /// The radius that keeps the outermost tile on screen is set by the phone's
    /// *width*, and once that is fixed the gap between neighbours is just the
    /// radius times the angle between them — which with eleven sections came out
    /// at around forty points, against a tile forty-four wide and a label
    /// sixty-four. So they overlapped, and no amount of stretching the arc
    /// vertically fixed it, because vertical stretch does not change the spacing
    /// between two tiles near the top of the arc where the arc is horizontal.
    /// Widening the fan made it worse, not better: more angle at a smaller
    /// radius is the same arc length.
    ///
    /// Rows solve it outright, because the spacing stops being derived and
    /// becomes something chosen. Each row is bowed so the ends sit slightly
    /// lower than the middle, which keeps the silhouette of something fanning
    /// out of the orb rather than a grid dropped on top of it, and the rows
    /// climb the screen — which is where all the free space was.
    struct Layout {
        let rowSizes: [Int]
        let columnPitch: CGFloat
        let rowPitch: CGFloat
        let firstRowLift: CGFloat
        let bow: CGFloat

        /// At most four across: five fits the tiles on a large phone and not
        /// their labels, and a layout that is right on a Pro Max and broken on
        /// a mini is a layout that is broken.
        static let maximumPerRow = 4

        init(count: Int, size: CGSize) {
            // Rows are built full-width first and then reversed, so the short
            // row ends up at the *bottom*. That puts the widest part of the fan
            // furthest from the orb, which is the shape a bloom has, and it
            // keeps the first few items — the ones reached most often — nearest
            // the thumb.
            var sizes: [Int] = []
            var remaining = count
            while remaining > 0 {
                let take = min(Self.maximumPerRow, remaining)
                sizes.append(take)
                remaining -= take
            }
            rowSizes = sizes.reversed()

            let widest = CGFloat(sizes.max() ?? 1)
            // The label is the wider of tile and label, and it is the one that
            // reads as broken when two of them touch.
            let usable = min(size.width, 460) - 28
            columnPitch = max(OrbDock.bloomLabelWidth + 10,
                              min(96, usable / max(widest, 1)))

            // A row is a tile plus its label plus air, and then as much more air
            // as the screen will give — the fan climbs into the empty two
            // thirds above the dock rather than crouching over it. Compressed
            // when there are more rows than a short phone has room for, rather
            // than running the top row off under the hint.
            let rows = CGFloat(rowSizes.count)
            let available = size.height - OrbDock.orbCentreFromBottom - 150
            rowPitch = max(96, min(148, available / max(rows, 1)))
            firstRowLift = 118
            bow = 16
        }

        /// The row and column `index` falls in, counting rows from the bottom.
        func position(of index: Int) -> (row: Int, column: Int, rowSize: Int) {
            var remaining = index
            for (row, size) in rowSizes.enumerated() {
                if remaining < size { return (row, remaining, size) }
                remaining -= size
            }
            let last = rowSizes.count - 1
            return (max(last, 0), 0, rowSizes.last ?? 1)
        }

        /// Where item `index` sits, as an offset from the orb's centre.
        func offset(of index: Int) -> CGSize {
            let (row, column, rowSize) = position(of: index)
            let centred = CGFloat(column) - CGFloat(rowSize - 1) / 2
            let x = centred * columnPitch

            // The ends of a row dip, by an amount that grows with how far from
            // the middle they are. Quadratic rather than circular because it is
            // the same shape to the eye at this scale and does not need the row
            // to know a radius.
            let half = max(CGFloat(rowSize - 1) / 2, 0.5)
            let dip = bow * pow(centred / half, 2)

            let y = -(firstRowLift + CGFloat(row) * rowPitch) + dip
            return CGSize(width: x, height: y)
        }
    }

    /// Maps a finger position to the nearest tile.
    ///
    /// Nearest by distance now that the tiles are on a grid rather than a ring —
    /// but with the vertical axis weighted, because a thumb sweeping upward
    /// crosses rows quickly and a small wobble sideways should not jump columns
    /// while it does.
    private func updateFocus(towards point: CGPoint, from origin: CGPoint, plan: Layout) {
        let dx = point.x - origin.x
        let dy = point.y - origin.y
        guard hypot(dx, dy) > 44 else { return }

        let nearest = items.indices.min { a, b in
            distance(from: dx, dy, to: plan.offset(of: a))
                < distance(from: dx, dy, to: plan.offset(of: b))
        }
        guard nearest != focus else { return }
        focus = nearest
        Haptics.shared.play(.selection)
    }

    private func distance(from dx: CGFloat, _ dy: CGFloat, to offset: CGSize) -> CGFloat {
        hypot(dx - offset.width, (dy - offset.height) * 0.8)
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
