import SwiftUI
import Charts
import SeismicCore
import SeismicStructures
import SeismicData

/// Two buildings, one earthquake, at the same instant.
///
/// The argument this app makes — that a building's period decides its fate more
/// than the earthquake's size does — is abstract until you watch a squat block
/// sit almost still while a tower beside it tears itself about, on the same
/// ground motion, side by side. Nothing about the record differs between the
/// two panes. Only the buildings do.
struct ComparisonView: View {
    let record: EarthquakeRecord
    let candidates: [BuildingModel]
    var initialLeft: UUID?
    var initialRight: UUID?

    @Environment(\.dismiss) private var dismiss
    @StateObject private var leftController = BuildingSceneController()
    @StateObject private var rightController = BuildingSceneController()
    @StateObject private var leftRunner = SimulationRunner()
    @StateObject private var rightRunner = SimulationRunner()
    @StateObject private var sonifier = PeriodSonifier()

    @State private var leftID: UUID?
    @State private var rightID: UUID?
    @State private var hasRun = false

    private var left: BuildingModel? { candidates.first { $0.id == leftID } }
    private var right: BuildingModel? { candidates.first { $0.id == rightID } }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                panes
                verdictStrip
                controls
            }
            .seismicBackground()
            .navigationTitle("Side by side")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { stopEverything(); dismiss() }
                }
            }
            .onAppear(perform: setUp)
            .onChange(of: leftID) { _, _ in rebuild() }
            .onChange(of: rightID) { _, _ in rebuild() }
            .onReceive(leftRunner.$frame) { frame in
                guard let frame else { return }
                leftController.apply(displacements: frame.displacements, drifts: frame.drifts)
            }
            .onReceive(rightRunner.$frame) { frame in
                guard let frame else { return }
                rightController.apply(displacements: frame.displacements, drifts: frame.drifts)
            }
            .onDisappear { stopEverything() }
        }
    }

    // MARK: Panes

    private var panes: some View {
        GeometryReader { geometry in
            HStack(spacing: 1) {
                pane(building: left, controller: leftController, runner: leftRunner,
                     width: geometry.size.width / 2)
                pane(building: right, controller: rightController, runner: rightRunner,
                     width: geometry.size.width / 2)
            }
        }
        .background(Theme.Palette.hairline)
    }

    private func pane(building: BuildingModel?, controller: BuildingSceneController,
                      runner: SimulationRunner, width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            BuildingSceneView(controller: controller)
            VStack(alignment: .leading, spacing: 4) {
                Text(building?.name ?? "—")
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .lineLimit(2)
                if let building {
                    Text(String(format: "%.2f s · %d storeys",
                                building.empiricalPeriod, building.storeyCount))
                        .font(Theme.Typography.numericSmall)
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
                if let result = runner.result {
                    Text(String(format: "peak drift %.2f%%", result.maximumDrift * 100))
                        .font(Theme.Typography.numericSmall)
                        .foregroundStyle(DamageStateColors
                            .color(for: result.overallDamageState.rawValue))
                }
            }
            .padding(10)
        }
        .frame(width: width)
        .clipped()
    }

    /// The comparison stated in words. A picture of two swaying buildings is
    /// persuasive but ambiguous; this says which one is worse and by how much.
    @ViewBuilder
    private var verdictStrip: some View {
        if let leftResult = leftRunner.result, let rightResult = rightRunner.result,
           let left, let right {
            let ratio = rightResult.maximumDrift > 0
                ? leftResult.maximumDrift / rightResult.maximumDrift : 0
            let worse = ratio > 1 ? left : right
            let factor = ratio > 1 ? ratio : (ratio > 0 ? 1 / ratio : 0)

            VStack(alignment: .leading, spacing: 6) {
                Text(factor > 1.15
                     ? String(format: "%@ drifted %.1f× as far on the same ground motion.",
                              worse.name, factor)
                     : "Both buildings responded within about 15% of each other.")
                    .font(Theme.Typography.callout)
                    .foregroundStyle(Theme.Palette.textPrimary)

                Text(reason(left: left, right: right))
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Metrics.cardPadding)
            .background(Theme.Palette.surface)
        }
    }

    /// Why one fared worse — stated from the physics, not from the result.
    private func reason(left: BuildingModel, right: BuildingModel) -> String {
        let leftPeriod = left.empiricalPeriod
        let rightPeriod = right.empiricalPeriod
        let dominant = record.dominantPeriod
        let leftGap = abs(leftPeriod - dominant) / max(dominant, 1e-6)
        let rightGap = abs(rightPeriod - dominant) / max(dominant, 1e-6)

        if abs(leftGap - rightGap) < 0.15 {
            return String(format: "Both sit a similar distance from this record's dominant "
                          + "period of %.2f s, so the difference is coming from stiffness and "
                          + "damping rather than from resonance.", dominant)
        }
        let closer = leftGap < rightGap ? left : right
        let closerPeriod = leftGap < rightGap ? leftPeriod : rightPeriod
        return String(format: "This record's energy sits around %.2f s. %@ has a period of "
                      + "%.2f s, close enough to be driven near resonance; the other is far "
                      + "enough away to be pushed rather than pumped.",
                      dominant, closer.name, closerPeriod)
    }

    // MARK: Controls

    private var controls: some View {
        VStack(spacing: Theme.Metrics.spacing) {
            HStack(spacing: Theme.Metrics.spacing) {
                picker(title: "Left", selection: $leftID)
                picker(title: "Right", selection: $rightID)
            }

            HStack(spacing: Theme.Metrics.spacing) {
                Button {
                    run()
                } label: {
                    Label(hasRun ? "Run again" : "Run \(record.name)",
                          systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(left == nil || right == nil
                          || leftRunner.isRunning || rightRunner.isRunning)

                Button {
                    hearBoth()
                } label: {
                    Image(systemName: sonifier.isPlaying ? "speaker.wave.2.fill" : "speaker.wave.2")
                }
                .buttonStyle(SecondaryButtonStyle())
                .accessibilityLabel("Hear both periods at once")
            }

            if sonifier.isPlaying {
                Text(sonifier.describedPitch)
                    .font(Theme.Typography.numericSmall)
                    .foregroundStyle(Theme.Palette.accent)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(Theme.Metrics.screenPadding)
        .background(Theme.Palette.surface)
    }

    private func picker(title: String, selection: Binding<UUID?>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel(title)
            Menu {
                ForEach(candidates) { candidate in
                    Button(candidate.name) { selection.wrappedValue = candidate.id }
                }
            } label: {
                HStack {
                    Text(candidates.first { $0.id == selection.wrappedValue }?.name ?? "Choose")
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down").font(.caption2)
                }
                .font(Theme.Typography.callout)
                .foregroundStyle(Theme.Palette.textPrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadiusSmall)
                    .fill(Theme.Palette.surfaceRaised))
            }
        }
    }

    // MARK: Behaviour

    private func setUp() {
        leftID = initialLeft ?? candidates.first?.id
        rightID = initialRight
            ?? candidates.first(where: { $0.id != leftID })?.id
            ?? candidates.first?.id
        rebuild()
    }

    private func rebuild() {
        if let left {
            leftController.build(left, animated: false)
            leftRunner.prepare(building: left)
        }
        if let right {
            rightController.build(right, animated: false)
            rightRunner.prepare(building: right)
        }
        hasRun = false
    }

    /// Both solves use the identical ground motion. Generating it once and
    /// handing the same waveform to both is the whole point — a per-building
    /// synthesis would introduce a difference the user cannot see.
    private func run() {
        guard let left, let right else { return }
        let ground = SeedLibrary.waveform(for: record)
        hasRun = true
        Haptics.shared.play(.selection)
        leftRunner.run(building: left, ground: ground) { _ in }
        rightRunner.run(building: right, ground: ground) { _ in }
    }

    private func hearBoth() {
        if sonifier.isPlaying {
            sonifier.stop()
            return
        }
        guard let left, let right else { return }
        sonifier.playComparison(before: left.empiricalPeriod, after: right.empiricalPeriod)
    }

    private func stopEverything() {
        leftRunner.stop()
        rightRunner.stop()
        sonifier.stop()
    }
}
