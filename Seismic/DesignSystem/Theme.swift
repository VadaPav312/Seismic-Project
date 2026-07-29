import SwiftUI
import SeismicCore

/// The design language.
///
/// The reference is scientific instrumentation rather than a consumer
/// dashboard: an aviation glass cockpit, a spectrum analyser, a seismograph
/// drum. That means the data is the only thing with saturated colour, the chrome
/// recedes almost to nothing, and every number that changes is set in monospaced
/// figures so it does not jitter as it updates.
///
/// The one rule that overrides everything: green, amber and red are reserved
/// exclusively for structural verdicts. Nothing else in the app is allowed to be
/// those colours, because a user glancing at their phone in the dark after an
/// earthquake must be able to trust that a red thing means a red building.
enum Theme {

    // MARK: Colour

    enum Palette {
        /// Near-black with a blue cast, not pure black.
        ///
        /// An OLED-black background makes thin instrument strokes shimmer as the
        /// panel refreshes, and it gives translucent surfaces nothing to pick up.
        /// The three steps are the base, the layer glass sits over, and the
        /// deepest wells.
        static let background = Color(red: 0.020, green: 0.024, blue: 0.059)
        static let backgroundRaised = Color(red: 0.035, green: 0.043, blue: 0.102)
        static let backgroundDeep = Color(red: 0.055, green: 0.067, blue: 0.141)

        /// Surfaces are translucent white over the background rather than solid
        /// fills, so depth comes from blur and alpha instead of from more
        /// colours. Nothing in the interface is an opaque slab.
        static let glass = Color.white.opacity(0.06)
        static let glassStrong = Color.white.opacity(0.10)
        static let glassFaint = Color.white.opacity(0.035)

        static let hairline = Color.white.opacity(0.08)
        static let hairlineStrong = Color.white.opacity(0.14)
        /// The specular top edge of a glass surface.
        static let highlight = Color.white.opacity(0.55)

        /// Text is four alpha tiers of one white rather than four greys. Tiers
        /// of the same colour recede consistently over any background, which
        /// separate hexes do not.
        static let textPrimary = Color(red: 0.953, green: 0.961, blue: 1.0)
        static let textSecondary = Color(red: 0.953, green: 0.961, blue: 1.0).opacity(0.72)
        static let textTertiary = Color(red: 0.953, green: 0.961, blue: 1.0).opacity(0.46)
        static let textGhost = Color(red: 0.953, green: 0.961, blue: 1.0).opacity(0.26)

        /// The accent is a gradient, not a colour. One hue would have to be
        /// either the calm blue this app wants at rest or the bright edge it
        /// needs for a live control; a two-stop ramp is both.
        static let accent = Color(red: 0.486, green: 0.612, blue: 1.0)
        static let accentSecondary = Color(red: 0.616, green: 0.486, blue: 1.0)
        static let accentDim = Color(red: 0.486, green: 0.612, blue: 1.0).opacity(0.18)

        static let accentGradient = LinearGradient(
            colors: [accent, accentSecondary],
            startPoint: .topLeading, endPoint: .bottomTrailing)

        /// The rim light along a card's edge. Bright where the light would fall,
        /// gone where it would not — which is what stops a translucent panel
        /// reading as a flat grey rectangle.
        static let rim = LinearGradient(
            colors: [Color.white.opacity(0.28), Color.white.opacity(0.04),
                     Color.white.opacity(0.10)],
            startPoint: .topLeading, endPoint: .bottomTrailing)

        // Verdict colours. Used for nothing else, ever — a user glancing at
        // their phone in the dark after an earthquake must be able to trust
        // that a red thing means a red building.
        static let verdictGreen = Color(red: 0.373, green: 0.878, blue: 0.784)
        static let verdictAmber = Color(red: 1.0, green: 0.824, blue: 0.478)
        static let verdictRed = Color(red: 1.0, green: 0.541, blue: 0.612)
        static let verdictUnknown = Color(red: 0.486, green: 0.612, blue: 1.0).opacity(0.5)

        /// Trace colours for the three axes. Distinguishable without relying on
        /// hue alone — each also has its own label and dash pattern.
        static let axisX = Color(red: 0.486, green: 0.612, blue: 1.0)
        static let axisY = Color(red: 0.616, green: 0.486, blue: 1.0)
        static let axisZ = Color(red: 1.0, green: 0.824, blue: 0.478)

        static let gridLine = Color.white.opacity(0.06)
        static let gridLineMajor = Color.white.opacity(0.12)

        /// Light mode. The app is dark-first, but Dynamic Type users often pair
        /// it with light and it must not be broken there.
        static func background(_ scheme: ColorScheme) -> Color {
            scheme == .dark ? background : Color(red: 0.933, green: 0.945, blue: 1.0)
        }
        static func surface(_ scheme: ColorScheme) -> Color {
            scheme == .dark ? glass : .white
        }
        static func textPrimary(_ scheme: ColorScheme) -> Color {
            scheme == .dark ? textPrimary : Color(red: 0.078, green: 0.102, blue: 0.200)
        }
        static func textSecondary(_ scheme: ColorScheme) -> Color {
            scheme == .dark ? textSecondary : Color(red: 0.30, green: 0.34, blue: 0.42)
        }

        /// Opaque surfaces, for anything filled directly rather than through
        /// `instrumentPanel()`.
        ///
        /// These are deliberately *not* the glass tokens. Glass only works when
        /// something composites it — a material underneath, a rim on top. Used
        /// as a bare fill it is a 6% white wash that shows whatever is behind
        /// it, which is how the tutorial card ended up transparent with the
        /// Home screen legible through it. Chart backdrops, field wells and
        /// sheet chrome need a real colour, and these are the glass tones
        /// pre-composited over the background.
        static let surface = Color(red: 0.075, green: 0.086, blue: 0.145)
        static let surfaceRaised = Color(red: 0.106, green: 0.118, blue: 0.184)
        static let surfaceHighest = Color(red: 0.145, green: 0.161, blue: 0.235)
    }

    // MARK: Typography

    enum Typography {
        /// The headline number: a countdown, a period change, a drift figure.
        /// Monospaced digits are not a stylistic choice — a proportional 1 is
        /// narrower than a 4, so a live counter visibly jumps without them.
        static func display(_ size: CGFloat = 64) -> Font {
            .system(size: size, weight: .light, design: .rounded).monospacedDigit()
        }

        /// Headings are tight and heavy. Negative tracking at large sizes is
        /// what makes a title read as one shape rather than as a row of
        /// letters; at body size it would hurt legibility, so it is not used
        /// there.
        static let titleLarge = Font.system(.largeTitle, design: .default).weight(.bold)
        static let title = Font.system(.title2, design: .default).weight(.bold)
        static let headline = Font.system(.headline, design: .default).weight(.semibold)
        static let body = Font.system(.body)
        static let callout = Font.system(.callout)
        static let caption = Font.system(.caption)

        /// Any figure that updates.
        static let numeric = Font.system(.body, design: .monospaced).monospacedDigit()
        static let numericSmall = Font.system(.caption, design: .monospaced).monospacedDigit()
        static let numericLarge = Font.system(.title, design: .monospaced)
            .weight(.medium).monospacedDigit()

        /// Small, wide-tracked labels, as used on instrument panels.
        static let label = Font.system(.caption2, design: .default).weight(.semibold)
    }

    // MARK: Layout

    enum Metrics {
        /// Large radii, so nothing has a hard corner. A 22pt card next to a
        /// pill button reads as one family; a 9pt one reads as a dialog box.
        static let cornerRadius: CGFloat = 22
        static let cornerRadiusLarge: CGFloat = 28
        static let cornerRadiusSmall: CGFloat = 14
        static let cornerRadiusPill: CGFloat = 999
        static let hairline: CGFloat = 1 / 3

        /// A named scale rather than hand-picked numbers. Every gap in the app
        /// is one of these, which is most of why it looks deliberate.
        static let s1: CGFloat = 4
        static let s2: CGFloat = 8
        static let s3: CGFloat = 12
        static let s4: CGFloat = 16
        static let s5: CGFloat = 22
        static let s6: CGFloat = 28
        static let s7: CGFloat = 36
        static let s8: CGFloat = 48

        static let spacingTight = s2
        static let spacing = s3
        static let spacingLoose = s5
        static let spacingSection = s6

        /// 22pt inside every card and 20 down the side of every screen. The
        /// single biggest difference between an interface that looks finished
        /// and one that does not is whether the padding is the same everywhere.
        static let cardPadding: CGFloat = 22
        static let screenPadding: CGFloat = 20

        /// The content column. Capped so the app does not sprawl on an iPad or
        /// a Max-sized phone, where full-width text is unreadably long.
        static let contentWidth: CGFloat = 680

        /// Minimum tap target. Non-negotiable during an emergency, when hands
        /// shake and the phone is being held badly.
        static let minimumTapTarget: CGFloat = 48
    }

    // MARK: Motion

    enum Motion {
        static let quick = Animation.easeOut(duration: 0.16)
        /// The house curve: settles fast, overshoots barely, never wobbles.
        static let standard = Animation.spring(response: 0.35, dampingFraction: 0.82)
        static let gentle = Animation.spring(response: 0.55, dampingFraction: 0.9)
        /// For a control being pressed. Anything slower feels disconnected from
        /// the finger.
        static let press = Animation.spring(response: 0.22, dampingFraction: 0.7)
        /// For values that stream in continuously; anything springy here looks
        /// like the instrument is lagging.
        static let dataUpdate = Animation.linear(duration: 0.12)

        /// Respects Reduce Motion by collapsing to a cross-fade.
        static func adaptive(_ animation: Animation, reduceMotion: Bool) -> Animation {
            reduceMotion ? .easeInOut(duration: 0.15) : animation
        }
    }
}

// MARK: - Verdict presentation

extension SafetyVerdict {
    var color: Color {
        switch self {
        case .green: Theme.Palette.verdictGreen
        case .amber: Theme.Palette.verdictAmber
        case .red: Theme.Palette.verdictRed
        case .needsInspection: Theme.Palette.verdictUnknown
        }
    }

    /// Colour is never the only signal — see `systemImage` on the model, plus
    /// the distinct border weight and pattern used on placards.
    var borderWidth: CGFloat {
        switch self {
        case .red: 3
        case .amber: 2
        default: 1
        }
    }
}

extension DamageStateColors {
    /// Damage states use a graduated scale rather than the verdict colours, so a
    /// storey shaded orange in the simulator is never confused with a building
    /// tagged amber on the map.
    /// Dimmed roughly a fifth from the original ramp.
    ///
    /// These are painted across large solid faces of a 3D model on a near-black
    /// background, which is a very different thing from a few coloured pixels in
    /// a chart: at the old values a damaged tower filled the screen with
    /// saturated orange and was unpleasant to look at for any length of time.
    /// The ordering and the hue steps are unchanged, so the ramp still reads
    /// left to right as increasing damage, and each step still clears the
    /// contrast needed against the background.
    static func color(for state: Int) -> Color {
        switch state {
        case 0: Color(red: 0.29, green: 0.44, blue: 0.60)
        case 1: Color(red: 0.36, green: 0.58, blue: 0.63)
        case 2: Color(red: 0.74, green: 0.63, blue: 0.35)
        case 3: Color(red: 0.75, green: 0.44, blue: 0.28)
        default: Color(red: 0.68, green: 0.25, blue: 0.27)
        }
    }
}

enum DamageStateColors {}

extension ConnectionState {
    var color: Color {
        switch self {
        case .connected: Theme.Palette.accent
        case .simulated: Color(red: 0.65, green: 0.55, blue: 0.95)
        case .weakSignal: Color(red: 0.85, green: 0.70, blue: 0.35)
        case .reconnecting, .connecting, .scanning: Theme.Palette.textSecondary
        case .disconnected: Theme.Palette.textTertiary
        }
    }

    var systemImage: String {
        switch self {
        case .connected: "antenna.radiowaves.left.and.right"
        case .simulated: "cpu"
        case .weakSignal: "antenna.radiowaves.left.and.right.slash"
        case .connecting, .scanning: "dot.radiowaves.left.and.right"
        case .reconnecting: "arrow.clockwise"
        case .disconnected: "antenna.radiowaves.left.and.right.slash"
        }
    }
}

// MARK: - Shared modifiers

/// The standard panel: a pane of glass, not a grey rectangle.
///
/// Four layers, and each one is doing a job:
///
/// 1. A material, so the drifting colour behind the app shows through and every
///    card picks up a slightly different tint depending on where it sits.
/// 2. A vertical white wash, brighter at the top — the light in this interface
///    comes from above, and that single gradient is most of what sells the
///    surface as physical.
/// 3. A rim: a one-pixel gradient stroke, bright at the top-left and dim at the
///    bottom-right. Without it a translucent panel has no edge and dissolves
///    into whatever is behind it.
/// 4. A shadow with a long, soft falloff rather than a tight dark one, so the
///    card looks lifted rather than cut out.
struct InstrumentPanel: ViewModifier {
    var padding: CGFloat = Theme.Metrics.cardPadding
    var cornerRadius: CGFloat = Theme.Metrics.cornerRadius

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(LinearGradient(
                                colors: [Color.white.opacity(0.10),
                                         Color.white.opacity(0.03),
                                         Color.white.opacity(0.015)],
                                startPoint: .top, endPoint: .bottom))
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Theme.Palette.rim, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
    }
}

extension View {
    func instrumentPanel(padding: CGFloat = Theme.Metrics.cardPadding,
                         cornerRadius: CGFloat = Theme.Metrics.cornerRadius) -> some View {
        modifier(InstrumentPanel(padding: padding, cornerRadius: cornerRadius))
    }

    /// Applies the app's background, edge to edge.
    func seismicBackground() -> some View {
        background(AmbientBackground().ignoresSafeArea())
    }

    /// Caps the content column and centres it.
    ///
    /// Full-width body text on a Max-sized phone runs to about ninety
    /// characters, which is roughly twice a comfortable measure. On an iPad it
    /// is worse. This is the cheapest single thing that stops a layout looking
    /// like a stretched phone app.
    func contentColumn() -> some View {
        frame(maxWidth: Theme.Metrics.contentWidth)
            .frame(maxWidth: .infinity)
    }
}
