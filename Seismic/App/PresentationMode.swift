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

    /// Which script is running.
    enum Mode: String {
        /// Ninety seconds. The argument, and nothing else.
        case brief
        /// Three and a half minutes, the hardware included, meant to be watched
        /// by somebody who will then ask questions.
        case showcase
    }

    @Published private(set) var isRunning = false
    @Published private(set) var caption: String?
    @Published private(set) var beatIndex = 0
    @Published private(set) var progress: Double = 0
    @Published private(set) var mode: Mode = .brief

    /// How many words of the current caption have appeared.
    ///
    /// The caption arrives a word at a time rather than all at once. A block of
    /// text that appears whole is read in a second and then sat through; a line
    /// that assembles itself at roughly reading speed holds an audience's eye on
    /// the caption *while* the thing it describes happens behind it, which is
    /// the entire reason the captions exist. It also gives the room something to
    /// look at that is moving, during beats where the screen behind is
    /// deliberately still.
    @Published private(set) var revealedWords = 0

    /// The current caption split for that reveal, cached so the overlay is not
    /// splitting a string on every frame of the animation.
    @Published private(set) var captionWords: [String] = []

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

    /// The full demonstration.
    ///
    /// Three and a half minutes, which is roughly what a person will watch
    /// before wanting to interrupt — so it is built to *earn* that interruption
    /// rather than to be complete. It goes further than the brief script in one
    /// respect that matters: it runs the hardware. Beat by beat it triggers the
    /// node's own event sequence and then narrates what the node is actually
    /// doing while it does it, so the timings on screen are the board's and not
    /// this file's. If the node stalls, the demonstration visibly stalls with
    /// it, which is the honest behaviour and the one a rehearsed video cannot
    /// give you.
    static let showcaseScript: [Beat] = [
        Beat(section: .home,
             caption: "This is one building, watched continuously by a sensor bolted to it.",
             seconds: 8),

        Beat(section: .home,
             caption: "It already knows how this building sways when nothing is happening — "
                    + "about once every nine tenths of a second. That single number is the "
                    + "whole idea.",
             seconds: 11),

        Beat(section: .simulator,
             caption: "Here is the same building as a structural model. Every storey has a real "
                    + "mass and a real stiffness, taken from public data about the building "
                    + "itself.",
             seconds: 12),

        Beat(section: .simulator,
             caption: "Now a recorded earthquake, run through a real time-history solver rather "
                    + "than an animation. Watch the upper storeys.",
             seconds: 14,
             action: { environment in
                 environment.simulateEarthquake(magnitude: 6.6, distanceKm: 18)
             }),

        Beat(section: .monitor,
             caption: "The fast P wave arrives before the slow damaging one. Everything that "
                    + "follows happens inside that gap.",
             seconds: 10),

        // From here the hardware is in charge. The drill is fired once and the
        // beats afterwards describe what it is doing rather than driving it.
        Beat(section: .device,
             caption: "I'm going to shake the node now, and let it run its whole sequence "
                    + "without touching it again.",
             seconds: 7,
             action: { environment in
                 environment.link.send(.drill)
             }),

        Beat(section: .device,
             caption: "Three separate sensors have to agree before it declares anything. One is "
                    + "a slammed door. Two is an earthquake.",
             seconds: 13),

        Beat(section: .device,
             caption: "It cuts the building's power — and then watches a photoresistor to prove "
                    + "the current actually stopped, because a command that was sent is only a "
                    + "rumour.",
             seconds: 13),

        Beat(section: .device,
             caption: "Then the water main, eight hundred milliseconds later. One motor at a "
                    + "time: a USB port cannot power two, and browning out mid-earthquake is "
                    + "not a theoretical failure.",
             seconds: 13),

        Beat(section: .device,
             caption: "While that happens the phone is calling emergency services with "
                    + "everything a dispatcher needs and nobody inside could say. Nothing is "
                    + "dialled here — the screen says so.",
             seconds: 20),

        Beat(section: .device,
             caption: "The recording comes across in checksummed chunks, and when one goes "
                    + "missing it asks for that one rather than starting again.",
             seconds: 12,
             action: { environment in
                 // The call has made its point by now; the demonstration takes
                 // the screen back rather than leaving a dead call over it.
                 environment.emergencyCall.hangUp()
                 environment.emergencyCall.dismiss()
             }),

        Beat(section: .assess,
             caption: "Afterwards it measures the sway again. Damage takes stiffness out of a "
                    + "building, and a building with less stiffness sways more slowly.",
             seconds: 14),

        Beat(section: .assess,
             caption: "Cold concrete does the same thing, by about as much. So the measurement "
                    + "is normalised against this building's own temperature history — "
                    + "otherwise it would cry wolf every January.",
             seconds: 14),

        Beat(section: .assess,
             caption: "Every piece of evidence behind the verdict is listed. Nothing contributes "
                    + "invisibly, and evidence that disagrees widens the answer rather than "
                    + "being averaged away.",
             seconds: 13),

        Beat(section: .map,
             caption: "Verdicts can be published to a map, so a street can see itself instead of "
                    + "waiting days for an inspector to reach it.",
             seconds: 12),

        Beat(section: .library,
             caption: "Any building on Earth can be pulled in by name — height and footprint "
                    + "from public data, with the source of every fact shown.",
             seconds: 12),

        Beat(section: .channels,
             caption: "All six sensor channels are here individually, so you can watch which one "
                    + "voted and which one refused.",
             seconds: 10),

        Beat(section: .home,
             caption: "And all of it works with no hardware, no keys and no network. That is the "
                    + "default, not the fallback.",
             seconds: 9),
    ]

    func script(for mode: Mode) -> [Beat] {
        switch mode {
        case .brief: Self.script
        case .showcase: Self.showcaseScript
        }
    }

    var totalSeconds: Double { script(for: mode).reduce(0) { $0 + $1.seconds } }

    func start(environment: AppEnvironment, mode: Mode = .brief,
               select: @escaping (AppSection) -> Void) {
        stop()
        self.mode = mode
        isRunning = true
        beatIndex = 0

        let beats = script(for: mode)
        let total = beats.reduce(0) { $0 + $1.seconds }

        task = Task { @MainActor in
            var elapsed = 0.0
            for (index, beat) in beats.enumerated() {
                if Task.isCancelled { break }
                beatIndex = index
                let words = beat.caption.split(separator: " ").map(String.init)
                captionWords = words
                revealedWords = 0
                withAnimation(Theme.Motion.standard) {
                    select(beat.section)
                    caption = beat.caption
                }
                beat.action?(environment)

                // The caption finishes assembling itself well before the beat
                // ends, so there is a pause to look at what it described rather
                // than the last word landing as the screen changes.
                let revealWindow = min(beat.seconds * 0.6, Double(words.count) * 0.16)
                let perWord = words.isEmpty ? 0 : revealWindow / Double(words.count)

                // Stepped rather than slept in one go, so the progress bar moves
                // and the thing can be stopped promptly.
                let steps = Int(beat.seconds * 20)
                for step in 0..<steps {
                    if Task.isCancelled { break }
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    elapsed += 0.05
                    progress = min(elapsed / max(total, 1), 1)

                    let due = perWord > 0 ? Int((Double(step) * 0.05) / perWord) : words.count
                    let next = min(due, words.count)
                    if next != revealedWords {
                        withAnimation(.easeOut(duration: 0.22)) { revealedWords = next }
                    }
                }
                revealedWords = words.count
            }
            if !Task.isCancelled { finish() }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        isRunning = false
        caption = nil
        captionWords = []
        revealedWords = 0
        progress = 0
    }

    private func finish() {
        isRunning = false
        caption = nil
        captionWords = []
        revealedWords = 0
        progress = 1
        Haptics.shared.play(.assessmentComplete)
    }
}

// MARK: - Words arriving one at a time

/// Lays words out as a paragraph so each can be animated separately.
///
/// `Text` cannot fade in its own words — it is one view, and one view has one
/// opacity. So each word becomes a view, and something has to wrap them, which
/// is what this is: rows filled left to right, wrapping when the next word will
/// not fit. About twenty lines to gain something `Text` will not do at any
/// price.
struct WordFlow: Layout {
    var spacing: CGFloat = 5
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = arrange(subviews: subviews, width: width)
        let height = rows.reduce(0) { $0 + $1.height } +
            lineSpacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        let rows = arrange(subviews: subviews, width: bounds.width)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                                      proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let projected = current.indices.isEmpty ? size.width
                                                    : current.width + spacing + size.width
            if projected > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
                current.indices = [index]
                current.width = size.width
                current.height = size.height
            } else {
                current.indices.append(index)
                current.width = projected
                current.height = max(current.height, size.height)
            }
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

/// The caption bar, and the way out of it.
struct PresentationOverlay: View {
    @ObservedObject var director: PresentationDirector
    let stop: () -> Void

    var body: some View {
        VStack {
            Spacer()
            if director.caption != nil {
                VStack(alignment: .leading, spacing: Theme.Metrics.s4) {
                    words

                    HStack(spacing: Theme.Metrics.s4) {
                        ProgressView(value: director.progress)
                            .tint(Theme.Palette.accent)
                        Text(remaining)
                            .font(Theme.Typography.numericSmall)
                            .foregroundStyle(Theme.Palette.textTertiary)
                            .monospacedDigit()
                        Button("Stop") { stop() }
                            .font(Theme.Typography.caption.weight(.semibold))
                            .foregroundStyle(Theme.Palette.accent)
                            .frame(height: Theme.Metrics.minimumTapTarget)
                    }
                }
                .padding(Theme.Metrics.cardPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadiusLarge,
                                            style: .continuous))
                .padding(.horizontal, Theme.Metrics.screenPadding)
                .padding(.bottom, OrbDock.clearance + Theme.Metrics.s4)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .allowsHitTesting(director.caption != nil)
        .animation(Theme.Motion.gentle, value: director.caption == nil)
    }

    /// The caption, assembling itself.
    ///
    /// A word that has not arrived yet is laid out but transparent, not absent —
    /// so the block keeps its final height from the first word and the controls
    /// below it do not walk down the screen as the sentence grows.
    private var words: some View {
        WordFlow(spacing: 5, lineSpacing: 5) {
            ForEach(Array(director.captionWords.enumerated()), id: \.offset) { index, word in
                Text(word)
                    .font(Theme.Typography.title)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .opacity(index < director.revealedWords ? 1 : 0)
                    .blur(radius: index < director.revealedWords ? 0 : 3)
                    .offset(y: index < director.revealedWords ? 0 : 5)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var remaining: String {
        let left = max(director.totalSeconds * (1 - director.progress), 0)
        return String(format: "%d:%02d", Int(left) / 60, Int(left) % 60)
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
