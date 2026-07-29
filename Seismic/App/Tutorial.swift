import SwiftUI
import Combine

/// The guided tour that runs over the real app.
///
/// This is deliberately not more onboarding slides. The introduction explains
/// *why* a building's rhythm changes when it is damaged, which is an idea and
/// belongs on its own screen. This explains *where things are*, which is a
/// place, and the only honest way to show somebody a place is to stand them in
/// it. So the app keeps running underneath: the real tab bar, the real trace,
/// the real building — dimmed, with a hole cut around whatever is being
/// described.
///
/// Every step is skippable and the whole thing is resumable, because a tour
/// interrupted by an actual earthquake must not be the reason somebody cannot
/// find the Assess screen afterwards.
@MainActor
final class TutorialDirector: ObservableObject {

    /// One thing worth pointing at.
    struct Step: Identifiable, Equatable {
        let id: String
        /// The section to move to before this step is shown.
        let section: AppSection
        let title: String
        let body: String
        /// Which highlighted element to cut the spotlight around. Nil puts the
        /// card in the middle with no hole, for steps that describe a screen
        /// rather than a control.
        let anchor: TutorialAnchor?
        /// Where the card sits relative to the hole.
        var prefersCardBelow = true
    }

    @Published private(set) var isRunning = false
    @Published private(set) var index = 0
    /// Frames reported by highlighted views, in global coordinates.
    @Published var anchors: [TutorialAnchor: CGRect] = [:]

    /// Set once the tour has been finished or dismissed, so it never reappears
    /// uninvited. Replayable from Settings.
    @AppStorage("didCompleteTutorial") var didComplete = false

    /// Set when the user asks for the tour again from Settings.
    ///
    /// A separate published flag rather than watching `didComplete`, because
    /// `@AppStorage` inside an observable object does not publish — a Settings
    /// screen that only cleared the stored flag would appear to do nothing
    /// until the next launch.
    @Published var replayRequested = false

    func requestReplay() {
        didComplete = false
        replayRequested = true
    }

    private var navigate: ((AppSection) -> Void)?

    let steps: [Step] = [
        Step(id: "home", section: .home,
             title: "This is your building",
             body: "Everything the app knows about it lives here: how tall it is, what it is "
                 + "made of, and how it has behaved every time it has been shaken.",
             anchor: nil),
        Step(id: "verdict", section: .home,
             title: "The answer, in one line",
             body: "After an event this says whether the building is safe to be in. It is never "
                 + "hidden behind a menu and never phrased as a maybe — and tapping it shows "
                 + "you exactly which measurements produced it.",
             anchor: .homeVerdict),
        Step(id: "monitor", section: .monitor,
             title: "The live trace",
             body: "Three axes of ground motion, straight from the node. The strip underneath is "
                 + "the trigger ratio — when it crosses the line, the app decides an earthquake "
                 + "has started.",
             anchor: nil),
        Step(id: "freeze", section: .monitor,
             title: "Freeze what just happened",
             body: "The interesting moment is always the one that has just scrolled off. Freeze "
                 + "holds the trace still so you can look at it properly; the node keeps "
                 + "recording either way.",
             anchor: .monitorFreeze, prefersCardBelow: true),
        Step(id: "simulator", section: .simulator,
             title: "Your building, shaken",
             body: "Pick a real earthquake and watch what it does to this specific building. The "
                 + "sway is exaggerated so you can see it — the app tells you by how much rather "
                 + "than pretending otherwise.",
             anchor: nil),
        Step(id: "map", section: .map,
             title: "The street around you",
             body: "After an event, buildings near you appear here as other people assess them. "
                 + "Your own position is offset before anything is shared.",
             anchor: nil),
        Step(id: "more", section: .home,
             title: "Everything else is in here",
             body: "Assess, Analysis, Node, Preparedness, Household and the rest. Nine screens "
                 + "would not fit in a tab bar anybody could use in a hurry.",
             anchor: .moreMenu, prefersCardBelow: true),
    ]

    var current: Step? { steps.indices.contains(index) ? steps[index] : nil }
    var isLastStep: Bool { index >= steps.count - 1 }
    var progress: Double {
        guard !steps.isEmpty else { return 1 }
        return Double(index + 1) / Double(steps.count)
    }

    func start(navigate: @escaping (AppSection) -> Void) {
        self.navigate = navigate
        index = 0
        isRunning = true
        moveToCurrentSection()
    }

    func advance() {
        guard isRunning else { return }
        if isLastStep {
            finish()
        } else {
            index += 1
            moveToCurrentSection()
        }
    }

    func back() {
        guard isRunning, index > 0 else { return }
        index -= 1
        moveToCurrentSection()
    }

    func finish() {
        isRunning = false
        didComplete = true
        navigate = nil
    }

    private func moveToCurrentSection() {
        guard let step = current else { return }
        navigate?(step.section)
    }

    /// The hole to cut, in global coordinates, or nil for a centred card.
    ///
    /// Returns nil rather than a guess when the anchor has not reported a frame
    /// yet: a spotlight around a rectangle that is not there reads as a bug,
    /// whereas a plain dimmed screen with a card on it reads as intentional.
    func spotlight(for step: Step) -> CGRect? {
        guard let anchor = step.anchor, let frame = anchors[anchor],
              frame.width > 1, frame.height > 1 else { return nil }
        return frame.insetBy(dx: -8, dy: -8)
    }
}

/// The parts of the interface the tour can point at.
///
/// An enum rather than free strings so a renamed step cannot silently point at
/// nothing — the highlight and the step have to agree at compile time.
enum TutorialAnchor: String, Hashable, CaseIterable {
    case homeVerdict
    case monitorFreeze
    case moreMenu
}

// MARK: - Reporting a frame

private struct TutorialAnchorKey: PreferenceKey {
    static var defaultValue: [TutorialAnchor: CGRect] { [:] }
    static func reduce(value: inout [TutorialAnchor: CGRect],
                       nextValue: () -> [TutorialAnchor: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

extension View {
    /// Marks this view as something the tutorial can point at.
    ///
    /// Uses a preference rather than a binding so a view deep inside a
    /// navigation stack can report upward without knowing the director exists.
    /// `.global` coordinates because the overlay is drawn over everything,
    /// including the tab bar, which shares no coordinate space with the screen
    /// content.
    func tutorialAnchor(_ anchor: TutorialAnchor) -> some View {
        background(
            GeometryReader { proxy in
                Color.clear.preference(key: TutorialAnchorKey.self,
                                       value: [anchor: proxy.frame(in: .global)])
            }
        )
    }

    func collectsTutorialAnchors(into director: TutorialDirector) -> some View {
        onPreferenceChange(TutorialAnchorKey.self) { [weak director] frames in
            Task { @MainActor in
                guard let director else { return }
                for (anchor, frame) in frames { director.anchors[anchor] = frame }
            }
        }
    }
}

// MARK: - The overlay

struct TutorialOverlay: View {
    @ObservedObject var director: TutorialDirector
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            if let step = director.current {
                let hole = director.spotlight(for: step)

                ZStack(alignment: .topLeading) {
                    dimming(hole: hole, in: proxy.size)
                        // The hole is a real hole: taps inside it reach the app
                        // underneath, so somebody can try the control being
                        // described while it is being described.
                        .allowsHitTesting(false)

                    if let hole {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Theme.Palette.accent, lineWidth: 2)
                            .frame(width: hole.width, height: hole.height)
                            .position(x: hole.midX, y: hole.midY)
                            .allowsHitTesting(false)
                    }

                    card(step, hole: hole, in: proxy.size)
                }
                .ignoresSafeArea()
                .animation(reduceMotion ? nil : Theme.Motion.standard, value: director.index)
            }
        }
        .transition(.opacity)
    }

    /// A dimmed screen with a rectangle cut out of it.
    private func dimming(hole: CGRect?, in size: CGSize) -> some View {
        Canvas { context, canvasSize in
            context.fill(Path(CGRect(origin: .zero, size: canvasSize)),
                         with: .color(.black.opacity(0.78)))
            guard let hole else { return }
            // `.clear` with the copy blend mode punches through what has already
            // been drawn rather than painting transparent black over it.
            context.blendMode = .copy
            context.fill(Path(roundedRect: hole, cornerRadius: 12), with: .color(.clear))
        }
        .frame(width: size.width, height: size.height)
    }

    private func card(_ step: TutorialDirector.Step, hole: CGRect?, in size: CGSize) -> some View {
        let cardWidth = min(size.width - 32, 380)

        return VStack(alignment: .leading, spacing: Theme.Metrics.spacing) {
            HStack(spacing: 8) {
                ForEach(director.steps.indices, id: \.self) { index in
                    Capsule()
                        .fill(index <= director.index
                              ? Theme.Palette.accent : Theme.Palette.surfaceHighest)
                        .frame(height: 3)
                }
            }

            Text(step.title)
                .font(Theme.Typography.title)
                .foregroundStyle(Theme.Palette.textPrimary)

            Text(step.body)
                .font(Theme.Typography.callout)
                .foregroundStyle(Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            // No padding on the labels. The button styles apply their own, and
            // applying it twice made three controls too wide for the card —
            // which is why the words collapsed to an ellipsis and a stray
            // glyph rather than reading "Back" and "Next".
            HStack(spacing: Theme.Metrics.spacing) {
                if director.index > 0 {
                    Button {
                        Haptics.shared.play(.selection)
                        director.back()
                    } label: {
                        Text("Back")
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }

                Button {
                    Haptics.shared.play(.selection)
                    withAnimation(Theme.Motion.gentle) { director.advance() }
                } label: {
                    Text(director.isLastStep ? "Done" : "Next")
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(Theme.Metrics.spacingLoose)
        .frame(width: cardWidth, alignment: .leading)
        // Opaque, unlike the app's other panels. This card sits over a dimmed
        // screen and has to be the only legible thing on it; a translucent one
        // lets the interface it is explaining read straight through the text.
        .background(
            RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadiusLarge, style: .continuous)
                .fill(Theme.Palette.surfaceRaised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadiusLarge, style: .continuous)
                .strokeBorder(Theme.Palette.rim, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.5), radius: 24, y: 10)
        .position(cardPosition(hole: hole, cardWidth: cardWidth, in: size))
    }

    /// Pins the card to the bottom of the screen.
    ///
    /// It used to float beside whatever it was describing, which meant it
    /// landed in the middle of the screen and covered the very interface it was
    /// explaining. Anchoring it to the bottom keeps the whole app visible above
    /// it — and a tour whose subject is hidden behind the tour is no tour at
    /// all.
    ///
    /// The height estimate is deliberately generous; landing twenty points off
    /// is invisible next to covering the control being described.
    private func cardPosition(hole: CGRect?, cardWidth: CGFloat, in size: CGSize) -> CGPoint {
        let estimatedHeight: CGFloat = 250
        let bottomInset: CGFloat = 34   // clears the home indicator and the tab bar
        return CGPoint(x: size.width / 2,
                       y: size.height - bottomInset - estimatedHeight / 2)
    }
}
