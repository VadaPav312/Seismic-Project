import SwiftUI
import SeismicCore
import SeismicStructures

/// Onboarding.
///
/// The target is that somebody reaches a working simulation of a real building
/// within three minutes of first launch, having understood *why* a building's
/// rhythm changes when it is damaged. So the science comes first, in one
/// animated idea rather than a wall of text, and every step has a way past it.
struct OnboardingFlow: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var node: NodeStream
    @State private var step = 0
    @AppStorage("onboardingStep") private var savedStep = 0

    private let steps = 5

    var body: some View {
        VStack(spacing: 0) {
            progressBar

            TabView(selection: $step) {
                WelcomeStep().tag(0)
                ScienceStep().tag(1)
                ConnectionStep().tag(2)
                FirstMeasurementStep().tag(3)
                FirstImportStep().tag(4)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .animation(Theme.Motion.standard, value: step)

            controls
        }
        .seismicBackground()
        .onAppear { step = min(savedStep, steps - 1) }
        .onChange(of: step) { _, newValue in savedStep = newValue }
    }

    private var progressBar: some View {
        HStack(spacing: 5) {
            ForEach(0..<steps, id: \.self) { index in
                Capsule()
                    .fill(index <= step ? Theme.Palette.accent : Theme.Palette.surfaceHighest)
                    .frame(height: 3)
            }
        }
        .padding(.horizontal, Theme.Metrics.screenPadding)
        .padding(.top, Theme.Metrics.spacing)
        .accessibilityLabel("Step \(step + 1) of \(steps)")
    }

    /// Back and Continue, in one bordered bar.
    ///
    /// The previous version had three faults that compounded into the glitch.
    /// `.padding` and `.frame` were applied to the Button *outside* the
    /// `buttonStyle`, so the style's filled background hugged the text while
    /// the padding sat uselessly around the outside — a pill with the label
    /// jammed against its edges. Back had no style at all, so the two controls
    /// did not look like the same kind of thing. And Skip was an overlay
    /// centred on the same HStack, so it drew straight through Continue.
    ///
    /// Skip is now gone entirely, which also removes the collision. Nobody is
    /// stranded: every individual step's own action is optional, and the flow
    /// is five taps at worst.
    private var controls: some View {
        HStack(spacing: Theme.Metrics.spacing) {
            Button {
                Haptics.shared.play(.selection)
                withAnimation(Theme.Motion.standard) { step -= 1 }
            } label: {
                Text("Back")
                    .font(Theme.Typography.headline)
                    .frame(maxWidth: .infinity)
                    .frame(height: Theme.Metrics.minimumTapTarget)
            }
            .buttonStyle(SecondaryButtonStyle())
            // Kept in the layout on the first step rather than removed, so
            // Continue does not jump sideways the moment you advance.
            .disabled(step == 0)
            .opacity(step == 0 ? 0.35 : 1)

            Button {
                Haptics.shared.play(.selection)
                if step == steps - 1 {
                    withAnimation(Theme.Motion.gentle) { env.didCompleteOnboarding = true }
                } else {
                    withAnimation(Theme.Motion.standard) { step += 1 }
                }
            } label: {
                Text(step == steps - 1 ? "Start using Seismic" : "Continue")
                    .font(Theme.Typography.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity)
                    .frame(height: Theme.Metrics.minimumTapTarget)
            }
            .buttonStyle(PrimaryButtonStyle())
        }
        .padding(Theme.Metrics.spacing)
        .background(
            RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius, style: .continuous)
                .fill(Theme.Palette.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius, style: .continuous)
                .strokeBorder(Theme.Palette.hairlineStrong, lineWidth: 2)
        )
        .frame(maxWidth: 460)
        .frame(maxWidth: .infinity)
        .padding(Theme.Metrics.screenPadding)
    }
}

private struct WelcomeStep: View {
    var body: some View {
        VStack(spacing: Theme.Metrics.spacingLoose) {
            Spacer()
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 66, weight: .thin))
                .foregroundStyle(Theme.Palette.accent)

            Text("SEISMIC")
                .font(.system(size: 34, weight: .semibold))
                .tracking(8)
                .foregroundStyle(Theme.Palette.textPrimary)

            Text("After a major earthquake there are never enough engineers. People sleep "
                 + "outside safe buildings for weeks, while others walk back into damaged ones.")
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Text("Seismic gives every building a continuous, evidence-backed assessment — and "
                 + "lets a neighbourhood share it.")
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.textPrimary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(Theme.Metrics.spacingSection)
    }
}

/// The one idea the whole product rests on, animated rather than explained.
private struct ScienceStep: View {
    @State private var damaged = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var period: Double { damaged ? 1.35 : 1.0 }

    var body: some View {
        VStack(spacing: Theme.Metrics.spacingLoose) {
            Text("Every building has a rhythm")
                .font(Theme.Typography.titleLarge)
                .foregroundStyle(Theme.Palette.textPrimary)
                .multilineTextAlignment(.center)

            Text("Push a building sideways and let go, and it sways back and forth at a rate "
                 + "fixed by its stiffness. Damage makes it less stiff — so it sways more "
                 + "slowly. Typically 10 to 30% slower.")
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            SwayingBuildingAnimation(period: period, damaged: damaged)
                .frame(height: 220)

            Picker("", selection: $damaged) {
                Text("Undamaged").tag(false)
                Text("Damaged").tag(true)
            }
            .pickerStyle(.segmented)
            .onChange(of: damaged) { _, _ in Haptics.shared.play(.selection) }

            Text(damaged
                 ? "35% slower. That difference is large, and it is measurable — which is what "
                    + "this app does."
                 : "Tap “damaged” to see what cracking concrete does to the rhythm.")
                .font(Theme.Typography.callout)
                .foregroundStyle(damaged ? Theme.Palette.verdictAmber : Theme.Palette.textTertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.Metrics.spacingSection)
    }
}

/// A simple two-storey building swaying, drawn rather than simulated — this is
/// an explanation, not a measurement, and it should be legible above all.
private struct SwayingBuildingAnimation: View {
    let period: Double
    let damaged: Bool
    @State private var phase: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60)) { context in
            Canvas { drawContext, size in
                let time = context.date.timeIntervalSinceReferenceDate
                let sway = reduceMotion ? 0 : sin(2 * .pi * time / period)
                let amplitude = size.width * 0.11

                let storeys = 5
                let storeyHeight = size.height / CGFloat(storeys + 1)
                let width = size.width * 0.26

                for index in 0..<storeys {
                    let fraction = Double(index + 1) / Double(storeys)
                    // Mode-one shape: displacement grows with height.
                    let offset = CGFloat(sway * amplitude * fraction * fraction)
                    let y = size.height - CGFloat(index + 1) * storeyHeight

                    let rect = CGRect(x: size.width / 2 - width / 2 + offset,
                                      y: y, width: width, height: storeyHeight * 0.86)
                    let path = Path(roundedRect: rect, cornerRadius: 2)

                    drawContext.fill(path, with: .color(
                        damaged && index < 2
                            ? Theme.Palette.verdictAmber.opacity(0.65)
                            : Theme.Palette.accent.opacity(0.55)))
                    drawContext.stroke(path, with: .color(
                        damaged && index < 2
                            ? Theme.Palette.verdictAmber : Theme.Palette.accent),
                                       lineWidth: 1)
                }

                // Ground line.
                var ground = Path()
                ground.move(to: CGPoint(x: 0, y: size.height))
                ground.addLine(to: CGPoint(x: size.width, y: size.height))
                drawContext.stroke(ground, with: .color(Theme.Palette.hairlineStrong),
                                   lineWidth: 1.5)
            }
        }
        .accessibilityLabel(damaged
            ? "A damaged building swaying slowly"
            : "An undamaged building swaying quickly")
    }
}

/// The guided connection tutorial, with an escape at every step.
private struct ConnectionStep: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var completed: Set<Int> = []

    private let stages = [
        ("Turn on Bluetooth", "The node talks to your phone over Bluetooth Low Energy.",
         "antenna.radiowaves.left.and.right"),
        ("Scan for the node", "It advertises as soon as it has power.", "dot.radiowaves.left.and.right"),
        ("Connect", "Pairing persists — it reconnects on its own from then on.", "link"),
        ("Confirm data is streaming", "You should see a live trace within a second or two.",
         "waveform.path.ecg"),
        ("Run a self-test", "Every sensor and actuator is exercised once.", "checkmark.circle"),
        ("Calibrate the baseline", "Measures the building while it is quiet. This is what "
            + "future assessments are compared against.", "scope"),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Metrics.spacingLoose) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Connecting your node")
                        .font(Theme.Typography.titleLarge)
                        .foregroundStyle(Theme.Palette.textPrimary)
                    Text("Six steps. If you do not have hardware, the simulated node does all "
                         + "of this and behaves identically — you can complete the whole "
                         + "tutorial without it.")
                        .font(Theme.Typography.callout)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                ForEach(Array(stages.enumerated()), id: \.offset) { index, stage in
                    HStack(alignment: .top, spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(completed.contains(index)
                                      ? Theme.Palette.accent : Theme.Palette.surfaceHighest)
                                .frame(width: 28, height: 28)
                            Image(systemName: completed.contains(index)
                                  ? "checkmark" : stage.2)
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(completed.contains(index)
                                                 ? .black : Theme.Palette.textSecondary)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(stage.0)
                                .font(Theme.Typography.callout.weight(.medium))
                                .foregroundStyle(Theme.Palette.textPrimary)
                            Text(stage.1)
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Palette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                }

                Button {
                    Haptics.shared.play(.connectionEstablished)
                    env.attachSimulatedNode()
                    withAnimation(Theme.Motion.standard) {
                        completed = Set(0..<stages.count)
                    }
                } label: {
                    Label("Use the simulated node", systemImage: "cpu")
                        .font(Theme.Typography.headline)
                        .frame(maxWidth: .infinity)
                        .frame(height: Theme.Metrics.minimumTapTarget)
                }
                .buttonStyle(PrimaryButtonStyle())

                if completed.count == stages.count {
                    InlineNotice(level: .info, title: "Connected",
                                 message: "The simulated node is streaming physically realistic "
                                    + "data. Everything from here works exactly as it would "
                                    + "with hardware.")
                }
            }
            .padding(Theme.Metrics.spacingSection)
        }
    }
}

private struct FirstMeasurementStep: View {
    @EnvironmentObject private var node: NodeStream
    @EnvironmentObject private var env: AppEnvironment
    @State private var stage = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Metrics.spacingLoose) {
                Text("Your first assessment")
                    .font(Theme.Typography.titleLarge)
                    .foregroundStyle(Theme.Palette.textPrimary)

                Text("Watch the whole loop: measure the building, damage it, measure again, and "
                     + "see the verdict change.")
                    .font(Theme.Typography.callout)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let building = env.selectedBuilding {
                    ReadoutGrid(readouts: [
                        Readout(label: "Baseline period",
                                value: String(format: "%.3f",
                                              node.snapshot?.telemetry.measuredPeriod
                                              ?? building.empiricalPeriod),
                                unit: "s", tint: Theme.Palette.accent, size: .large),
                        Readout(label: "Building", value: building.name, size: .small),
                    ], columns: 2)
                    .instrumentPanel()
                }

                stepButton(0, "Establish a baseline", "scope") {
                    env.session.send(.calibrateBaseline)
                }
                stepButton(1, "Introduce simulated damage", "bandage") {
                    env.introduceSimulatedDamage()
                }
                stepButton(2, "Re-measure", "arrow.clockwise") {
                    env.session.send(.requestPeriodMeasurement)
                }

                if stage >= 3 {
                    InlineNotice(level: .warning, title: "The period lengthened",
                                 message: "That change is exactly what real damage produces, and "
                                    + "it is why the assessment moved. Nothing about the "
                                    + "building's appearance changed — only its rhythm.")
                }
            }
            .padding(Theme.Metrics.spacingSection)
        }
    }

    private func stepButton(_ index: Int, _ title: String, _ icon: String,
                            action: @escaping () -> Void) -> some View {
        Button {
            action()
            Haptics.shared.play(.selection)
            withAnimation(Theme.Motion.standard) { stage = max(stage, index + 1) }
        } label: {
            HStack {
                Image(systemName: stage > index ? "checkmark.circle.fill" : icon)
                    .foregroundStyle(stage > index ? Theme.Palette.verdictGreen
                                                   : Theme.Palette.accent)
                Text(title)
                Spacer()
            }
            .font(Theme.Typography.callout)
            .frame(height: Theme.Metrics.minimumTapTarget)
            .padding(.horizontal, 12)
        }
        .buttonStyle(SecondaryButtonStyle())
        .disabled(stage < index)
        .opacity(stage < index ? 0.45 : 1)
    }
}

private struct FirstImportStep: View {
    @State private var showingImport = false

    var body: some View {
        VStack(spacing: Theme.Metrics.spacingLoose) {
            Spacer()
            Image(systemName: "globe.europe.africa")
                .font(.system(size: 56, weight: .thin))
                .foregroundStyle(Theme.Palette.accent)

            Text("Now shake a real building")
                .font(Theme.Typography.titleLarge)
                .foregroundStyle(Theme.Palette.textPrimary)
                .multilineTextAlignment(.center)

            Text("Search for any building in the world. Seismic finds its facts, works out how "
                 + "it should behave, builds it in 3D, and shakes it with a real earthquake "
                 + "record.")
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                showingImport = true
            } label: {
                Label("Try it now", systemImage: "magnifyingglass")
                    .font(Theme.Typography.headline)
                    .frame(maxWidth: .infinity)
                    .frame(height: Theme.Metrics.minimumTapTarget)
            }
            .buttonStyle(PrimaryButtonStyle())
            Spacer()
        }
        .padding(Theme.Metrics.spacingSection)
        .sheet(isPresented: $showingImport) { BuildingImportSheet() }
    }
}

#Preview {
    OnboardingFlow()
        .previewEnvironment()
}
