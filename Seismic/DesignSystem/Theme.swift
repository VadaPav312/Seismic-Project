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
        /// Deep, slightly blue-black. Not pure black: an OLED-black background
        /// makes thin instrument strokes shimmer as the panel refreshes.
        static let background = Color(red: 0.043, green: 0.051, blue: 0.063)
        static let surface = Color(red: 0.075, green: 0.086, blue: 0.106)
        static let surfaceRaised = Color(red: 0.106, green: 0.122, blue: 0.149)
        static let surfaceHighest = Color(red: 0.145, green: 0.165, blue: 0.196)

        static let hairline = Color.white.opacity(0.08)
        static let hairlineStrong = Color.white.opacity(0.16)

        static let textPrimary = Color(red: 0.937, green: 0.949, blue: 0.965)
        static let textSecondary = Color(red: 0.612, green: 0.647, blue: 0.694)
        static let textTertiary = Color(red: 0.408, green: 0.443, blue: 0.494)

        /// The single accent. A cyan that reads as instrumentation rather than
        /// decoration, and is deliberately nowhere near green.
        static let accent = Color(red: 0.227, green: 0.784, blue: 0.910)
        static let accentDim = Color(red: 0.227, green: 0.784, blue: 0.910).opacity(0.18)

        // Verdict colours. Used for nothing else, ever.
        static let verdictGreen = Color(red: 0.298, green: 0.808, blue: 0.478)
        static let verdictAmber = Color(red: 0.976, green: 0.694, blue: 0.204)
        static let verdictRed = Color(red: 0.937, green: 0.325, blue: 0.314)
        static let verdictUnknown = Color(red: 0.596, green: 0.612, blue: 0.663)

        /// Trace colours for the three axes. Distinguishable without relying on
        /// hue alone — each also has its own label and dash pattern.
        static let axisX = Color(red: 0.400, green: 0.780, blue: 1.000)
        static let axisY = Color(red: 0.780, green: 0.600, blue: 1.000)
        static let axisZ = Color(red: 0.980, green: 0.780, blue: 0.400)

        static let gridLine = Color.white.opacity(0.06)
        static let gridLineMajor = Color.white.opacity(0.12)

        /// Light-mode equivalents. The app is dark-first but must not be broken
        /// in light mode, and Dynamic Type users often pair it with light.
        static func background(_ scheme: ColorScheme) -> Color {
            scheme == .dark ? background : Color(red: 0.965, green: 0.969, blue: 0.976)
        }
        static func surface(_ scheme: ColorScheme) -> Color {
            scheme == .dark ? surface : .white
        }
        static func textPrimary(_ scheme: ColorScheme) -> Color {
            scheme == .dark ? textPrimary : Color(red: 0.08, green: 0.09, blue: 0.11)
        }
        static func textSecondary(_ scheme: ColorScheme) -> Color {
            scheme == .dark ? textSecondary : Color(red: 0.38, green: 0.41, blue: 0.46)
        }
    }

    // MARK: Typography

    enum Typography {
        /// The headline number: a countdown, a period change, a drift figure.
        /// Monospaced digits are not a stylistic choice — a proportional 1 is
        /// narrower than a 4, so a live counter visibly jumps without them.
        static func display(_ size: CGFloat = 64) -> Font {
            .system(size: size, weight: .light, design: .rounded).monospacedDigit()
        }

        static let titleLarge = Font.system(.largeTitle, design: .default).weight(.semibold)
        static let title = Font.system(.title2, design: .default).weight(.semibold)
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
        static let cornerRadius: CGFloat = 14
        static let cornerRadiusLarge: CGFloat = 20
        static let cornerRadiusSmall: CGFloat = 9
        static let hairline: CGFloat = 1 / 3

        static let spacingTight: CGFloat = 6
        static let spacing: CGFloat = 12
        static let spacingLoose: CGFloat = 20
        static let spacingSection: CGFloat = 28

        static let cardPadding: CGFloat = 16
        static let screenPadding: CGFloat = 16

        /// Minimum tap target. Non-negotiable during an emergency, when hands
        /// shake and the phone is being held badly.
        static let minimumTapTarget: CGFloat = 48
    }

    // MARK: Motion

    enum Motion {
        static let quick = Animation.easeOut(duration: 0.18)
        static let standard = Animation.spring(response: 0.38, dampingFraction: 0.82)
        static let gentle = Animation.spring(response: 0.6, dampingFraction: 0.9)
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
    static func color(for state: Int) -> Color {
        switch state {
        case 0: Color(red: 0.35, green: 0.55, blue: 0.75)
        case 1: Color(red: 0.45, green: 0.72, blue: 0.78)
        case 2: Color(red: 0.90, green: 0.78, blue: 0.42)
        case 3: Color(red: 0.90, green: 0.52, blue: 0.32)
        default: Color(red: 0.80, green: 0.28, blue: 0.30)
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

/// The standard panel: a raised surface with a hairline edge and just enough
/// shadow to lift it off the background.
struct InstrumentPanel: ViewModifier {
    var padding: CGFloat = Theme.Metrics.cardPadding
    var cornerRadius: CGFloat = Theme.Metrics.cornerRadius

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Theme.Palette.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Theme.Palette.hairline, lineWidth: 1)
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
        background(Theme.Palette.background.ignoresSafeArea())
    }
}
