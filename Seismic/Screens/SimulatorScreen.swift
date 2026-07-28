import SwiftUI
import SeismicCore
import SeismicSignal
import SeismicStructures
import SeismicData

/// The earthquake simulator.
///
/// A real building, a real earthquake record, and the actual structural solver
/// running between them. The 3D view fills the screen and the controls float
/// over it in a panel that collapses away, because the thing worth looking at is
/// the building moving.
struct SimulatorScreen: View {
    @EnvironmentObject private var env: AppEnvironment
    @StateObject private var controller = BuildingSceneController()
    @StateObject private var runner = SimulationRunner()

    @State private var selectedBuildingID: UUID?
    @State private var selectedRecordID: UUID?
    /// Starts collapsed so the building gets the whole screen. The controls are
    /// one tap away; a 3D view with half of it behind a panel is not.
    @State private var controlsExpanded = false
    @State private var showsSweep = false
    @State private var showsComparison = false
    @State private var showsAR = false
    @StateObject private var sonifier = PeriodSonifier()
    @StateObject private var recorder = SceneRecorder()
    @State private var exportedImage: UIImage?
    @State private var showingImageShare = false
    @State private var showsModeShapes = false
    @State private var selectedMode = 1
    @State private var intensityScale: Double = 1.0

    private var building: BuildingModel? {
        env.buildings.first { $0.id == selectedBuildingID } ?? env.selectedBuilding
    }

    private var record: EarthquakeRecord? {
        env.earthquakes.first { $0.id == selectedRecordID } ?? env.earthquakes.first
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            BuildingSceneView(controller: controller)
                .ignoresSafeArea(edges: .bottom)
                .overlay(alignment: .topLeading) { overlayReadouts }
                .overlay(alignment: .topTrailing) { styleControls }

            controlPanel
        }
        .onAppear { setUp() }
        .onDisappear { sonifier.stop() }
        .onChange(of: selectedBuildingID) { _, _ in rebuild() }
        .sheet(isPresented: $showsSweep) {
            if let building { ResonanceSweepView(building: building) }
        }
        .sheet(isPresented: $showsComparison) {
            if let record {
                ComparisonView(record: record, candidates: env.buildings,
                               initialLeft: selectedBuildingID)
            }
        }
        .sheet(isPresented: $showingImageShare) {
            if let exportedImage {
                ActivityShareSheet(items: [exportedImage])
            }
        }
        .sheet(isPresented: $showsAR) {
            if let building { ARPlacementView(building: building) }
        }
        .onReceive(runner.$frame) { frame in
            guard let frame else { return }
            controller.apply(displacements: frame.displacements, drifts: frame.drifts)
            if frame.shakingIntensity > 0.15 {
                Haptics.shared.playShaking(intensity: frame.shakingIntensity)
            }
        }
    }

    // MARK: Setup

    private func setUp() {
        if selectedBuildingID == nil { selectedBuildingID = env.selectedBuilding?.id }
        if selectedRecordID == nil { selectedRecordID = env.earthquakes.first?.id }
        rebuild()
    }

    private func rebuild() {
        guard let building else { return }
        controller.build(building, animated: false)
        runner.prepare(building: building)
    }

    // MARK: Overlays

    @ViewBuilder
    private var overlayReadouts: some View {
        if let building {
            VStack(alignment: .leading, spacing: 8) {
                Text(building.name)
                    .font(Theme.Typography.headline)
                    .foregroundStyle(Theme.Palette.textPrimary)

                if let result = runner.result {
                    VStack(alignment: .leading, spacing: 6) {
                        overlayValue("Peak drift",
                                     String(format: "%.2f%%", result.maximumDrift * 100),
                                     DamageStateColors.color(for: result.overallDamageState.rawValue))
                        overlayValue("Worst storey", "\(result.worstStorey)",
                                     Theme.Palette.textPrimary)
                        overlayValue("Period", String(format: "%.2f s → %.2f s",
                                                      result.initialPeriod, result.finalPeriod),
                                     result.periodChangePercent > 1
                                        ? Theme.Palette.verdictAmber : Theme.Palette.textPrimary)
                        if result.periodChangePercent > 0.5 {
                            overlayValue("Softened",
                                         String(format: "%+.1f%%", result.periodChangePercent),
                                         Theme.Palette.verdictAmber)
                        }
                    }
                } else {
                    overlayValue("Natural period",
                                 String(format: "%.2f s", building.empiricalPeriod),
                                 Theme.Palette.accent)
                }

                if runner.isRunning {
                    Text(String(format: "t = %.1f s", runner.currentTime))
                        .font(Theme.Typography.numericSmall)
                        .foregroundStyle(Theme.Palette.accent)
                }

                // The exaggeration must always be visible: a building visibly
                // swinging a metre when it actually moved 20 mm would be a lie
                // if the factor were hidden.
                Text("Sway shown ×\(Int(controller.displacementExaggeration))")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
            .padding(12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12,
                                                                 style: .continuous))
            .padding(Theme.Metrics.screenPadding)
        }
    }

    private func overlayValue(_ label: String, _ value: String, _ tint: Color) -> some View {
        HStack(spacing: 6) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(Theme.Palette.textTertiary)
            Text(value)
                .font(Theme.Typography.numericSmall)
                .foregroundStyle(tint)
        }
    }

    private var styleControls: some View {
        VStack(spacing: 8) {
            ForEach(BuildingSceneController.VisualStyle.allCases) { style in
                Button {
                    Haptics.shared.play(.selection)
                    controller.style = style
                } label: {
                    Image(systemName: style.systemImage)
                        .font(.system(size: 15))
                        .frame(width: 38, height: 38)
                }
                .background(.ultraThinMaterial, in: Circle())
                .foregroundStyle(controller.style == style ? Theme.Palette.accent
                                                           : Theme.Palette.textSecondary)
                .accessibilityLabel(style.label)
            }
        }
        .padding(Theme.Metrics.screenPadding)
    }

    // MARK: Control panel

    private var controlPanel: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(Theme.Motion.standard) { controlsExpanded.toggle() }
            } label: {
                HStack {
                    Capsule()
                        .fill(Theme.Palette.hairlineStrong)
                        .frame(width: 36, height: 4)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 22)
                .contentShape(Rectangle())
            }
            .accessibilityLabel(controlsExpanded ? "Collapse controls" : "Expand controls")

            if controlsExpanded {
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Metrics.spacingLoose) {
                        buildingPicker
                        recordPicker
                        transport
                        exploreControls
                        whatIfControls
                        modeControls
                        sonificationControls
                        captureControls
                    }
                    .padding(.horizontal, Theme.Metrics.screenPadding)
                    .padding(.bottom, Theme.Metrics.spacingLoose)
                }
                .frame(maxHeight: 340)
            } else {
                compactTransport
                    .padding(.horizontal, Theme.Metrics.screenPadding)
                    .padding(.bottom, Theme.Metrics.spacing)
            }
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadiusLarge,
                                    style: .continuous))
        .padding(.horizontal, 8)
        .padding(.bottom, 4)
    }

    private var buildingPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Building")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(env.buildings) { candidate in
                        Button {
                            Haptics.shared.play(.selection)
                            selectedBuildingID = candidate.id
                        } label: {
                            VStack(spacing: 3) {
                                Image(systemName: candidate.thumbnailSystemImage)
                                    .font(.system(size: 16))
                                Text(candidate.name)
                                    .font(.system(size: 10, weight: .medium))
                                    .lineLimit(1)
                                Text(String(format: "%.2f s", candidate.empiricalPeriod))
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(Theme.Palette.textTertiary)
                            }
                            .frame(width: 92, height: 62)
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadiusSmall)
                                .strokeBorder(selectedBuildingID == candidate.id
                                              ? Theme.Palette.accent : .clear, lineWidth: 1.5))
                    }
                }
            }
        }
    }

    private var recordPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Earthquake record")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(env.earthquakes) { candidate in
                        Button {
                            Haptics.shared.play(.selection)
                            selectedRecordID = candidate.id
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(candidate.name)
                                    .font(.system(size: 11, weight: .semibold))
                                    .lineLimit(1)
                                Text("\(candidate.year) · M\(String(format: "%.1f", candidate.magnitude))")
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(Theme.Palette.textTertiary)
                                Text(String(format: "%.2f g", candidate.pgaTarget / gravity))
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(Theme.Palette.verdictAmber)
                            }
                            .frame(width: 108, alignment: .leading)
                            .padding(.vertical, 6)
                            .padding(.horizontal, 8)
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadiusSmall)
                                .strokeBorder(selectedRecordID == candidate.id
                                              ? Theme.Palette.accent : .clear, lineWidth: 1.5))
                    }
                }
            }
            if let record {
                Text(record.summary)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var transport: some View {
        VStack(spacing: Theme.Metrics.spacing) {
            HStack(spacing: Theme.Metrics.spacing) {
                Button {
                    runIt()
                } label: {
                    Label(runner.isRunning ? "Running…" : "Shake it",
                          systemImage: runner.isRunning ? "waveform" : "play.fill")
                        .font(Theme.Typography.headline)
                        .frame(maxWidth: .infinity)
                        .frame(height: Theme.Metrics.minimumTapTarget)
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(runner.isRunning)

                Button {
                    runner.stop()
                    controller.resetPositions()
                    Haptics.shared.play(.selection)
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .frame(width: 52, height: Theme.Metrics.minimumTapTarget)
                }
                .buttonStyle(SecondaryButtonStyle())
                .accessibilityLabel("Reset")
            }

            if runner.result != nil || runner.isRunning {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Playback")
                            .font(Theme.Typography.label)
                            .foregroundStyle(Theme.Palette.textTertiary)
                        Spacer()
                        Text(String(format: "%.1f s / %.0f s", runner.currentTime, runner.duration))
                            .font(Theme.Typography.numericSmall)
                            .foregroundStyle(Theme.Palette.textSecondary)
                    }
                    Slider(value: Binding(
                        get: { runner.progress },
                        set: { runner.scrub(to: $0) }), in: 0...1)
                        .tint(Theme.Palette.accent)
                }
            }
        }
    }

    private var compactTransport: some View {
        HStack(spacing: Theme.Metrics.spacing) {
            Button {
                runIt()
            } label: {
                Label("Shake", systemImage: "play.fill")
                    .font(Theme.Typography.callout)
                    .frame(maxWidth: .infinity)
                    .frame(height: 40)
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(runner.isRunning)

            if let result = runner.result {
                Text(String(format: "%.2f%% drift", result.maximumDrift * 100))
                    .font(Theme.Typography.numericSmall)
                    .foregroundStyle(DamageStateColors.color(for: result.overallDamageState.rawValue))
            }
        }
    }

    private var whatIfControls: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.spacing) {
            SectionLabel("What if", systemImage: "slider.horizontal.3")

            labelledSlider("Shaking strength", value: $intensityScale,
                           range: 0.1...4, format: "×%.1f")
            labelledSlider("Sway exaggeration",
                           value: Binding(get: { controller.displacementExaggeration },
                                          set: { controller.displacementExaggeration = $0 }),
                           range: 1...200, format: "×%.0f")
        }
    }

    private func labelledSlider(_ label: String, value: Binding<Double>,
                                range: ClosedRange<Double>, format: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label)
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Palette.textTertiary)
                Spacer()
                Text(String(format: format, value.wrappedValue))
                    .font(Theme.Typography.numericSmall)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            Slider(value: value, in: range).tint(Theme.Palette.accent)
        }
    }

    /// The three ways of looking at the same building that are not simply
    /// pressing play: the resonance curve, a second building beside it, and the
    /// thing itself standing on the floor in front of you.
    private var exploreControls: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.spacing) {
            SectionLabel("Explore", systemImage: "square.grid.2x2")
            HStack(spacing: 8) {
                exploreButton("Resonance", "waveform.path.badge.plus") { showsSweep = true }
                exploreButton("Side by side", "rectangle.split.2x1") { showsComparison = true }
                exploreButton("In the room", "arkit") { showsAR = true }
            }
        }
    }

    private func exploreButton(_ title: String, _ image: String,
                               action: @escaping () -> Void) -> some View {
        Button {
            Haptics.shared.play(.selection)
            action()
        } label: {
            VStack(spacing: 4) {
                Image(systemName: image).font(.system(size: 15))
                Text(title).font(.system(size: 10, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 50)
        }
        .buttonStyle(SecondaryButtonStyle())
    }

    /// The building, transposed six octaves up so it can be heard.
    ///
    /// After a run there are two periods to compare — before and after the
    /// softening — and playing them together turns the change into a throb you
    /// hear rather than a percentage you read.
    private var sonificationControls: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.spacing) {
            SectionLabel("Listen", systemImage: "waveform")

            HStack(spacing: 8) {
                Button {
                    if sonifier.isPlaying { sonifier.stop() }
                    else if let building { sonifier.play(period: building.empiricalPeriod) }
                } label: {
                    Label(sonifier.isPlaying && sonifier.mode == .single ? "Stop" : "This building",
                          systemImage: "speaker.wave.2")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryButtonStyle())

                if let result = runner.result, result.periodChangePercent > 0.2 {
                    Button {
                        if sonifier.isPlaying && sonifier.mode == .beat { sonifier.stop() }
                        else {
                            sonifier.playComparison(before: result.initialPeriod,
                                                    after: result.finalPeriod)
                        }
                    } label: {
                        Label("Before vs after", systemImage: "waveform.badge.exclamationmark")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            }

            if sonifier.isPlaying {
                Text(sonifier.describedPitch)
                    .font(Theme.Typography.numericSmall)
                    .foregroundStyle(Theme.Palette.accent)
                Text(sonifier.mode.explanation)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Getting it out of the app: a still for a report, a clip for somebody who
    /// is not in the room.
    private var captureControls: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.spacing) {
            SectionLabel("Capture", systemImage: "camera.viewfinder")

            HStack(spacing: 8) {
                Button {
                    guard let image = recorder.snapshot(controller.renderView) else { return }
                    exportedImage = image
                    showingImageShare = true
                    Haptics.shared.play(.selection)
                } label: {
                    Label("Still", systemImage: "camera")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryButtonStyle())

                Button {
                    if recorder.isRecording { recorder.stopRecording() }
                    else { recorder.startRecording(controller.renderView) }
                } label: {
                    Label(recorder.isRecording ? "Stop" : "Record",
                          systemImage: recorder.isRecording ? "stop.circle.fill" : "record.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryButtonStyle())
            }

            if let url = recorder.lastExportURL, !recorder.isRecording {
                ShareLink(item: url) {
                    Label("Share the clip", systemImage: "square.and.arrow.up")
                        .font(Theme.Typography.caption)
                }
            }

            if let status = recorder.status {
                Text(status)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textTertiary)
            }

            Text("Frames come from the 3D view itself, so the export has no controls or status "
                 + "bar in it.")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var modeControls: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.spacing) {
            SectionLabel("Mode shapes", systemImage: "waveform.path")

            if let building {
                let modes = ModalAnalysis.modes(of: ShearBuilding.from(building))
                HStack(spacing: 8) {
                    ForEach(modes.prefix(3)) { mode in
                        Button {
                            Haptics.shared.play(.selection)
                            selectedMode = mode.number
                            showsModeShapes = true
                            controller.animateModeShape(mode)
                        } label: {
                            VStack(spacing: 2) {
                                Text("Mode \(mode.number)")
                                    .font(.system(size: 10, weight: .semibold))
                                Text(String(format: "%.2f s", mode.period))
                                    .font(.system(size: 9, design: .monospaced))
                                Text(String(format: "%.0f%% mass", mode.massParticipationRatio * 100))
                                    .font(.system(size: 8))
                                    .foregroundStyle(Theme.Palette.textTertiary)
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                        }
                        .buttonStyle(SecondaryButtonStyle())
                    }
                }

                if showsModeShapes {
                    Button("Stop animation") {
                        showsModeShapes = false
                        controller.stopModeAnimation()
                    }
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.accent)
                }
            }
        }
    }

    private func runIt() {
        guard let building, let record else { return }
        Haptics.shared.play(.eventTriggered)
        controller.resetPositions()
        controller.stopModeAnimation()
        showsModeShapes = false

        var waveform = SeedLibrary.waveform(for: record)
        if intensityScale != 1 {
            waveform = Waveform(samples: waveform.samples.map { $0 * intensityScale },
                                sampleRate: waveform.sampleRate, unit: .acceleration)
        }

        runner.run(building: building, ground: waveform) { result in
            controller.markDamage(result.storeyResults)
            Haptics.shared.play(result.overallDamageState.rawValue >= 2
                                ? .verdictRed : .assessmentComplete)
        }
    }
}

/// Drives a solved simulation frame by frame.
///
/// The solve happens once, off the main thread; playback then just reads the
/// stored history. Re-solving per frame would be both far too slow and
/// unnecessary — the response does not change once the ground motion is fixed.
@MainActor
final class SimulationRunner: ObservableObject {

    struct Frame {
        var displacements: [Double]
        var drifts: [Double]
        var shakingIntensity: Double
    }

    @Published private(set) var frame: Frame?
    @Published private(set) var result: SimulationResult?
    @Published private(set) var isRunning = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0

    private var timer: Timer?
    private var index = 0
    private var model: ShearBuilding?
    private var thresholds: DriftThresholds = .forSystem(.momentFrame,
                                                          material: .reinforcedConcrete)

    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(max(currentTime / duration, 0), 1)
    }

    func prepare(building: BuildingModel) {
        model = ShearBuilding.from(building)
        thresholds = DriftThresholds.forSystem(building.system, material: building.material)
        result = nil
        frame = nil
        currentTime = 0
        duration = 0
    }

    func run(building: BuildingModel, ground: Waveform,
             completion: @escaping (SimulationResult) -> Void) {
        stop()
        let model = self.model ?? ShearBuilding.from(building)
        let thresholds = self.thresholds
        isRunning = true

        Task.detached(priority: .userInitiated) {
            let solved = StructuralSolver.run(model, groundAcceleration: ground,
                                              thresholds: thresholds,
                                              options: .init(allowDegradation: true,
                                                             keepHistory: true,
                                                             maximumStoredSteps: 3000))
            await MainActor.run { [weak self] in
                guard let self else { return }
                result = solved
                duration = solved.times.last ?? 0
                index = 0
                startPlayback()
                completion(solved)
            }
        }
    }

    private func startPlayback() {
        guard let result, !result.times.isEmpty else { isRunning = false; return }
        let interval = max((result.times.last ?? 1) / Double(result.times.count), 1.0 / 60)

        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.advance() }
        }
    }

    private func advance() {
        guard let result, index < result.times.count else {
            isRunning = false
            timer?.invalidate()
            return
        }
        currentTime = result.times[index]
        let displacements = index < result.displacement.count ? result.displacement[index] : []
        let drifts = index < result.drift.count ? result.drift[index] : []
        let intensity = drifts.map(abs).max().map { min($0 / 0.02, 1) } ?? 0
        frame = Frame(displacements: displacements, drifts: drifts, shakingIntensity: intensity)
        index += 1
    }

    func scrub(to fraction: Double) {
        guard let result, !result.times.isEmpty else { return }
        index = min(max(Int(fraction * Double(result.times.count)), 0), result.times.count - 1)
        currentTime = result.times[index]
        let displacements = index < result.displacement.count ? result.displacement[index] : []
        let drifts = index < result.drift.count ? result.drift[index] : []
        frame = Frame(displacements: displacements, drifts: drifts, shakingIntensity: 0)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isRunning = false
        index = 0
        currentTime = 0
    }
}

#Preview {
    NavigationStack {
        SimulatorScreen()
            .navigationTitle("Simulator")
            .navigationBarTitleDisplayMode(.inline)
    }
    .previewEnvironment()
}
