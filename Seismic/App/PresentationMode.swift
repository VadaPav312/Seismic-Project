import SwiftUI
import Combine
import SeismicCore

/// Showing the app to somebody, without touching it.
///
/// Every demo of an app like this goes the same way: the person holding the
/// phone narrates while stabbing at controls, and the person watching sees a
/// hand. Presentation mode drives the app itself — it changes screens, fires a
/// simulated earthquake at the right moment, and captions what is about to
/// happen a beat before it does, so the audience is looking at the right part
/// of the screen when it changes.
///
/// It is also the fastest way for a new user to understand what they have. The
/// first run offers it, and it takes ninety seconds.
@MainActor
final class PresentationDirector: ObservableObject {

    struct Beat {
        var section: AppSection
        var caption: String
        var seconds: Double
        var action: ((AppEnvironment) -> Void)?
    }

    @Published private(set) var isRunning = false
    @Published private(set) var caption: String?
    @Published private(set) var beatIndex = 0
    @Published private(set) var progress: Double = 0

    private var task: Task<Void, Never>?

    /// The script.
    ///
    /// Ordered as an argument rather than as a feature tour: here is a building,
    /// here is what an earthquake does to it, here is the warning, here is the
    /// measurement that follows, here is what your neighbours see. Each beat is
    /// long enough to read the caption and watch the thing it describes.
    static let script: [Beat] = [
        Beat(section: .home,
             caption: "This is one building, continuously monitored by a sensor bolted to it.",
             seconds: 5),

        Beat(section: .simulator,
             caption: "The same building as a structural model. Every storey has a real mass "
                    + "and a real stiffness.",
             seconds: 6),

        Beat(section: .simulator,
             caption: "Now a real earthquake record, run through a real time-history solver. "
                    + "Watch the upper storeys.",
             seconds: 12,
             action: { environment in
                 environment.simulateEarthquake(magnitude: 6.6, distanceKm: 18)
             }),

        Beat(section: .monitor,
             caption: "The node detected the P wave and issued a warning before the damaging "
                    + "wave arrived. That gap is the entire point.",
             seconds: 8),

        Beat(section: .node,
             caption: "It also closed the gas valve — one actuator at a time, because a USB "
                    + "port cannot power two motors at once.",
             seconds: 7),

        Beat(section: .assess,
             caption: "Afterwards it measures the building's period again. Damage softens a "
                    + "building, and a softer building sways more slowly.",
             seconds: 9),

        Beat(section: .assess,
             caption: "Every piece of evidence behind the verdict is listed. Nothing "
                    + "contributes invisibly, and a wide interval stays wide.",
             seconds: 8),

        Beat(section: .map,
             caption: "Verdicts can be published to a map, so a street can see itself rather "
                    + "than waiting days for an inspector.",
             seconds: 7),

        Beat(section: .library,
             caption: "Any building can be pulled in by name — heights and footprints from "
                    + "public data, with every fact's source shown.",
             seconds: 7),

        Beat(section: .home,
             caption: "All of it works with no hardware, no keys and no network. That is the "
                    + "default, not the fallback.",
             seconds: 6),
    ]

    var totalSeconds: Double { Self.script.reduce(0) { $0 + $1.seconds } }

    func start(environment: AppEnvironment, select: @escaping (AppSection) -> Void) {
        stop()
        isRunning = true
        beatIndex = 0

        task = Task { @MainActor in
            var elapsed = 0.0
            for (index, beat) in Self.script.enumerated() {
                if Task.isCancelled { break }
                beatIndex = index
                withAnimation(Theme.Motion.standard) {
                    select(beat.section)
                    caption = beat.caption
                }
                beat.action?(environment)

                // Stepped rather than slept in one go, so the progress bar moves
                // and the thing can be stopped promptly.
                let steps = Int(beat.seconds * 10)
                for _ in 0..<steps {
                    if Task.isCancelled { break }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    elapsed += 0.1
                    progress = min(elapsed / max(totalSeconds, 1), 1)
                }
            }
            if !Task.isCancelled { finish() }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        isRunning = false
        caption = nil
        progress = 0
    }

    private func finish() {
        isRunning = false
        caption = nil
        progress = 1
        Haptics.shared.play(.assessmentComplete)
    }
}

/// The caption bar, and the way out of it.
struct PresentationOverlay: View {
    @ObservedObject var director: PresentationDirector
    let stop: () -> Void

    var body: some View {
        VStack {
            Spacer()
            if let caption = director.caption {
                VStack(alignment: .leading, spacing: 10) {
                    Text(caption)
                        .font(Theme.Typography.title)
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)

                    HStack {
                        ProgressView(value: director.progress)
                            .tint(Theme.Palette.accent)
                        Button("Stop") { stop() }
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.accent)
                    }
                }
                .padding(Theme.Metrics.cardPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadiusLarge,
                                            style: .continuous))
                .padding(Theme.Metrics.screenPadding)
                .padding(.bottom, 60)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .allowsHitTesting(director.caption != nil)
        .animation(Theme.Motion.gentle, value: director.caption)
    }
}

// MARK: - Coach marks

/// A one-line hint attached to a control, shown once.
///
/// Deliberately not a tour: a five-step modal walkthrough on first launch is
/// skipped by everybody and teaches nothing. These appear beside the control
/// they describe, the first time the screen holding it is opened, and never
/// again once dismissed.
struct CoachMark: ViewModifier {
    let id: String
    let text: String
    var edge: Edge = .bottom

    @AppStorage private var seen: Bool
    @State private var isVisible = false

    init(id: String, text: String, edge: Edge = .bottom) {
        self.id = id
        self.text = text
        self.edge = edge
        _seen = AppStorage(wrappedValue: false, "coach.\(id)")
    }

    func body(content: Content) -> some View {
        content
            .overlay(alignment: edge == .bottom ? .bottom : .top) {
                if isVisible && !seen {
                    bubble
                        .offset(y: edge == .bottom ? 44 : -44)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                        .zIndex(50)
                }
            }
            .onAppear {
                guard !seen else { return }
                // A beat after the screen settles, so it does not appear
                // mid-transition and get missed.
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    withAnimation(Theme.Motion.gentle) { isVisible = true }
                }
            }
    }

    private var bubble: some View {
        Button {
            withAnimation(Theme.Motion.quick) {
                seen = true
                isVisible = false
            }
            Haptics.shared.play(.selection)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "lightbulb")
                    .font(.system(size: 11))
                Text(text)
                    .font(Theme.Typography.caption)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
            .foregroundStyle(Theme.Palette.textPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadiusSmall, style: .continuous)
                    .fill(Theme.Palette.surfaceHighest)
                    .shadow(color: .black.opacity(0.4), radius: 12, y: 4))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadiusSmall, style: .continuous)
                    .strokeBorder(Theme.Palette.accent.opacity(0.35), lineWidth: 1))
            .frame(maxWidth: 260)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Tip: \(text). Double tap to dismiss.")
    }
}

extension View {
    /// Attaches a one-time hint. `id` is the storage key, so changing it shows
    /// the hint again — which is what you want after changing what it says.
    func coachMark(_ id: String, _ text: String, edge: Edge = .bottom) -> some View {
        modifier(CoachMark(id: id, text: text, edge: edge))
    }
}
