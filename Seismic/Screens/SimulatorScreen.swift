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

    @State private var selectedRecordID: UUID?
    /// Starts collapsed so the building gets the whole screen. The controls are
    /// one tap away; a 3D view with half of it behind a panel is not.
    @State private var controlsExpanded = false
    @State private var showsSweep = false
    @State private var showsComparison = false
    @State private var showsAR = false
    /// Cached because `modeControls` is evaluated on every pass through `body`,
    /// and the environment ticks at 20 Hz. Computing an eigendecomposition
    /// twenty times a second to label three buttons that have not changed is
    /// the sort of thing that makes a screen feel heavy for no visible reason.
    @State private var cachedModes: [ModeShape] = []
    @State private var cachedModesBuildingID: UUID?
    @StateObject private var sonifier = PeriodSonifier()
    @StateObject private var recorder = SceneRecorder()
    @State private var exportedImage: UIImage?
    @State private var showingImageShare = false
    @State private var showsModeShapes = false
    @State private var selectedMode = 1
    @State private var intensityScale: Double = 1.0
    /// Whether the neighbouring buildings are in the scene.
    ///
    /// Off by default. One building alone is the clearer picture for
    /// understanding *this* building, which is what the screen is mostly for;
    /// the street answers a different question — how it compares — and is worth
    /// asking for.
    @State private var showsStreet = false
    /// The collapse search. Dozens of full time histories, so it runs on
    /// demand and never as a side effect of opening a screen.
    @State private var ida: IncrementalDynamicAnalysis.Result?
    @State private var isRunningIDA = false

    /// The building being shaken, which is the app's current building and not a
    /// second copy of that choice.
    ///
    /// This screen used to keep its own `selectedBuildingID`, seeded once on
    /// first appearance. Two stores of the same fact drift apart the moment
    /// either is written: picking a building here left the rest of the app on
    /// the old one, and choosing one anywhere else was ignored here. "Simulate"
    /// in the Library wrote the shared value and this screen never read it
    /// again, which is precisely why that button did nothing.
    private var building: BuildingModel? { env.selectedBuilding }

    private var record: EarthquakeRecord? {
        env.earthquakes.first { $0.id == selectedRecordID } ?? env.earthquakes.first
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            if building == nil {
                // Reachable by deleting everything from Settings. An empty 3D
                // scene with no explanation is the dead end this avoids.
                DesignedEmptyState(
                    icon: "cube.transparent",
                    title: "No building to shake",
                    message: "The simulator needs a building. Restore the bundled examples — "
                           + "ten real buildings and ten real earthquake records — or import "
                           + "one by name.",
                    actionTitle: "Restore the example library",
                    action: { env.restoreSeedLibrary() })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .seismicBackground()
            } else {
                BuildingSceneView(controller: controller)
                    .ignoresSafeArea(edges: .bottom)
                    .overlay(alignment: .topLeading) { overlayReadouts }
                    .overlay(alignment: .topTrailing) { styleControls }

                controlPanel
            }
        }
        .onAppear { setUp() }
        .onDisappear {
            sonifier.stop()
            // A display link holds its target strongly, so a recording left
            // running when the screen goes away keeps capturing frames — and
            // keeps the recorder alive — for as long as the app runs.
            recorder.stopRecording()
        }
        // Follows the building wherever it was chosen — this screen's own
        // picker, the Library's "Simulate", the designer's "Save", a voice
        // command. One source, so all of them work.
        .onChange(of: env.selectedBuildingID) { _, _ in rebuild() }
        .sheet(isPresented: $showsSweep) {
            if let building { ResonanceSweepView(building: building) }
        }
        .sheet(isPresented: $showsComparison) {
            if let record {
                ComparisonView(record: record, candidates: env.buildings,
                               initialLeft: env.selectedBuildingID)
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
            // The street is driven by the ground, not by the solver — see
            // `BuildingSceneController.swayStreet`.
            if showsStreet {
                controller.swayStreet(groundDisplacement: frame.groundDisplacement,
                                      dominantPeriod: record?.dominantPeriod
                                          ?? runner.result?.initialPeriod ?? 0.5)
            }
            if frame.shakingIntensity > 0.15 {
                Haptics.shared.playShaking(intensity: frame.shakingIntensity)
            }
        }
        .onChange(of: showsStreet) { _, isOn in applyStreet(isOn) }
        .task(id: env.selectedBuildingID) {
            guard showsStreet, let building else { return }
            await env.block.fetch(for: building, using: env.services)
            applyStreet(true)
        }
    }

    /// Puts the neighbours in the scene, fetching them the first time.
    private func applyStreet(_ isOn: Bool) {
        guard let building else { return }
        guard isOn else {
            controller.clearStreet()
            return
        }
        let neighbours = env.block.neighbours(of: building.id)
        if neighbours.isEmpty {
            Task {
                await env.block.fetch(for: building, using: env.services)
                controller.setStreet(env.block.neighbours(of: building.id))
            }
        } else {
            controller.setStreet(neighbours)
        }
    }

    // MARK: Setup

    private func setUp() {
        if env.selectedBuildingID == nil { env.selectedBuildingID = env.buildings.first?.id }
        if selectedRecordID == nil { selectedRecordID = env.earthquakes.first?.id }
        rebuild()
    }

    private func rebuild() {
        guard let building else { return }
        controller.build(building, animated: false)
        runner.prepare(building: building)
        refreshModes(for: building)
        markPhotographedStoreys()
        applyStreet(showsStreet)
    }

    /// Puts a pin on every storey somebody has photographed damage on.
    ///
    /// Rebuilt with the geometry rather than tracked separately, because the
    /// storey nodes they hang off are thrown away and recreated on every
    /// `build`, and a pin attached to a node that no longer exists is a pin
    /// that silently stops appearing.
    private func markPhotographedStoreys() {
        guard let building else { return }
        let storeys = env.store.notesList()
            .filter { $0.buildingID == building.id }
            .compactMap(\.storey)
        controller.markPhotographedStoreys(Set(storeys))
    }

    /// Recomputed only when the building actually changes.
    private func refreshModes(for building: BuildingModel) {
        guard cachedModesBuildingID != building.id || cachedModes.isEmpty else { return }
        cachedModesBuildingID = building.id
        cachedModes = ModalAnalysis.modes(of: ShearBuilding.from(building))
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

                // What the twist means, in the one number worth quoting. The
                // building visibly rotates during a run and that would
                // otherwise look like a rendering flourish rather than the
                // measured consequence of its own plan.
                if controller.torsion.cornerAmplification > 0.02 {
                    overlayValue("Corner travels",
                                 String(format: "+%.0f%%",
                                        controller.torsion.cornerAmplification * 100),
                                 controller.torsion.isTorsionallyIrregular
                                    ? Theme.Palette.verdictAmber : Theme.Palette.textPrimary)
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
            .contentColumn()
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
                            env.selectedBuildingID = candidate.id
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
                                .strokeBorder(building?.id == candidate.id
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
                    Label(runner.isRunning ? "Running…" : (runner.isPaused ? "Start again"
                                                                           : "Shake it"),
                          systemImage: runner.isRunning ? "waveform" : "play.fill")
                        .font(Theme.Typography.headline)
                        .frame(maxWidth: .infinity)
                        .frame(height: Theme.Metrics.minimumTapTarget)
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(runner.isRunning)

                // Pause is where the simulator becomes useful rather than
                // impressive: the interesting instant is the one where a storey
                // crosses a drift threshold, and it goes past in a frame.
                if runner.isRunning || runner.isPaused {
                    Button {
                        runner.togglePause()
                        Haptics.shared.play(.selection)
                    } label: {
                        Image(systemName: runner.isPaused ? "play.fill" : "pause.fill")
                            .frame(width: 52, height: Theme.Metrics.minimumTapTarget)
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .accessibilityLabel(runner.isPaused ? "Resume" : "Pause")
                }

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
                Label(runner.isPaused ? "Restart" : "Shake", systemImage: "play.fill")
                    .font(Theme.Typography.callout)
                    .frame(maxWidth: .infinity)
                    .frame(height: 40)
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(runner.isRunning)

            // The collapsed bar is what the screen shows by default, so pause
            // has to be reachable without expanding the panel first.
            if runner.isRunning || runner.isPaused {
                Button {
                    runner.togglePause()
                    Haptics.shared.play(.selection)
                } label: {
                    Image(systemName: runner.isPaused ? "play.fill" : "pause.fill")
                        .frame(width: 44, height: 40)
                }
                .buttonStyle(SecondaryButtonStyle())
                .accessibilityLabel(runner.isPaused ? "Resume" : "Pause")
            }

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
            streetControl
            capacityControl
        }
    }

    /// How much the building had left, rather than what one earthquake did.
    ///
    /// Everything else on this screen answers "what happened". These answer
    /// "how close was that", which is the question somebody actually has after
    /// their building survives something — and it cannot be answered by
    /// replaying the record they already saw.
    @ViewBuilder
    private var capacityControl: some View {
        if let building {
            VStack(alignment: .leading, spacing: Theme.Metrics.spacing) {
                SectionLabel("How much it could take", systemImage: "gauge.with.needle")

                if let capacity {
                    ReadoutGrid(readouts: [
                        Readout(label: "Ductility",
                                value: String(format: "%.1f", capacity.ductility), unit: "×",
                                tint: capacity.ductility > 3 ? Theme.Palette.accent
                                                             : Theme.Palette.verdictAmber,
                                size: .small,
                                caption: "how far past yield before a mechanism"),
                        Readout(label: "Yields at",
                                value: String(format: "%.0f",
                                              capacity.yieldShear / 1000), unit: "kN",
                                size: .small),
                    ], columns: 2)

                    if let point = performancePoint {
                        Divider().overlay(Theme.Palette.hairline)
                        Readout(label: "Performance point",
                                value: String(format: "%.0f", point.roofDisplacement * 1000),
                                unit: "mm",
                                tint: point.converged ? Theme.Palette.accent
                                                      : Theme.Palette.verdictRed,
                                size: .large,
                                caption: point.converged
                                    ? String(format: "ductility demand %.1f×",
                                             point.ductilityDemand)
                                    : "no equilibrium — the demand exceeds the capacity")
                        Text(point.plainMeaning)
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Found by intersecting the building's capacity curve with this "
                             + "earthquake's demand spectrum, both converted into the same "
                             + "axes. The demand is reduced for the extra damping a building "
                             + "past yield produces — which depends on where the curves "
                             + "cross, so it is solved by iterating to a fixed point.")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                // P-delta, which only matters for a tall flexible building —
                // and says so plainly when it does not.
                if let worst = stabilityWorstStorey {
                    Divider().overlay(Theme.Palette.hairline)
                    HStack(alignment: .top, spacing: 10) {
                        Readout(label: "Stability θ",
                                value: String(format: "%.3f", worst.theta),
                                tint: worst.classification == .negligible
                                    ? Theme.Palette.textPrimary : Theme.Palette.verdictAmber,
                                size: .small,
                                caption: "storey \(worst.storey), worst")
                        Readout(label: "Drift amplified",
                                value: String(format: "%.2f", worst.amplification), unit: "×",
                                size: .small)
                    }
                    Text(worst.classification.explanation)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Soil, which is the one that can make an undamaged building
                // read as damaged.
                if let soil {
                    Divider().overlay(Theme.Palette.hairline)
                    ReadoutGrid(readouts: [
                        Readout(label: "Fixed base",
                                value: String(format: "%.3f", soil.fixedBasePeriod), unit: "s",
                                size: .small),
                        Readout(label: "On this soil",
                                value: String(format: "%.3f", soil.flexibleBasePeriod),
                                unit: "s",
                                tint: soil.periodLengthening > 0.05
                                    ? Theme.Palette.verdictAmber : Theme.Palette.accent,
                                size: .small),
                    ], columns: 2)
                    Text(soil.significance)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(soil.periodLengthening > 0.05
                                         ? Theme.Palette.textSecondary
                                         : Theme.Palette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button {
                    runIDA()
                } label: {
                    Label(ida == nil ? "Find where it breaks"
                                     : "Run the collapse search again",
                          systemImage: "arrow.up.forward.circle")
                        .font(Theme.Typography.callout)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(isRunningIDA || record == nil)

                if isRunningIDA {
                    MeaningfulProgress(
                        title: "Scaling the record up",
                        detail: "A full nonlinear time history at each intensity, until the "
                              + "building fails. There is no cheaper way — the whole thing "
                              + "being measured is the nonlinearity.")
                } else if let ida {
                    Text(ida.plainMeaning)
                        .font(Theme.Typography.callout)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    ForEach(ida.curve) { point in
                        HStack {
                            Text(String(format: "×%.2g", point.scale))
                                .font(Theme.Typography.numericSmall)
                                .foregroundStyle(Theme.Palette.textTertiary)
                                .frame(width: 46, alignment: .leading)
                            GeometryReader { proxy in
                                RoundedRectangle(cornerRadius: 2, style: .continuous)
                                    .fill(point.collapsed ? Theme.Palette.verdictRed
                                                          : Theme.Palette.accent)
                                    .frame(width: max(proxy.size.width
                                                      * min(point.maximumDrift / 0.05, 1), 2))
                            }
                            .frame(height: 10)
                            Text(String(format: "%.2f%%", point.maximumDrift * 100))
                                .font(Theme.Typography.numericSmall)
                                .foregroundStyle(Theme.Palette.textTertiary)
                                .frame(width: 58, alignment: .trailing)
                        }
                    }
                }
            }
            .padding(.top, Theme.Metrics.spacingTight)
        }
    }

    /// The capacity curve. Cheap enough to compute in a view, unlike the IDA.
    private var capacity: Pushover.Capacity? {
        guard let building else { return nil }
        return Pushover.run(ShearBuilding.from(building))
    }

    /// The demand this earthquake makes, in the form the capacity spectrum
    /// method wants: spectral acceleration against period.
    private var performancePoint: CapacitySpectrum.PerformancePoint? {
        guard let building, let capacity,
              let ground = record?.waveform else { return nil }
        let spectrum = ResponseSpectrumAnalysis.compute(ground)
        guard !spectrum.isEmpty else { return nil }
        let demand = zip(spectrum.periods, spectrum.sa).map {
            (period: $0, acceleration: $1)
        }
        return CapacitySpectrum.performancePoint(
            capacity: capacity, building: ShearBuilding.from(building), demand: demand)
    }

    /// The storey P-delta hurts most, from the drifts the last run produced.
    private var stabilityWorstStorey: PDelta.StoreyStability? {
        guard let building, let result = runner.result else { return nil }
        let model = ShearBuilding.from(building)
        let drifts = result.storeyResults.map { $0.peakDrift * model.storeys[
            min($0.storey - 1, model.storeys.count - 1)].height }
        guard drifts.count == model.storeys.count else { return nil }
        return PDelta.analyse(model, drifts: drifts).max { $0.theta < $1.theta }
    }

    private var soil: SoilStructureInteraction.Result? {
        guard let building else { return nil }
        return SoilStructureInteraction.analyse(
            ShearBuilding.from(building),
            foundation: .init(radius: max((building.footprintArea / .pi).squareRoot(), 3),
                              shearWaveVelocity: building.soil.shearWaveVelocity))
    }

    private func runIDA() {
        guard let building, let record else { return }
        isRunningIDA = true
        let model = ShearBuilding.from(building)
        let thresholds = DriftThresholds.forSystem(building.system, material: building.material)
        guard let ground = record.waveform else { isRunningIDA = false; return }

        Task.detached(priority: .userInitiated) {
            let result = IncrementalDynamicAnalysis.run(model, ground: ground,
                                                        thresholds: thresholds)
            await MainActor.run {
                ida = result
                isRunningIDA = false
                Haptics.shared.play(.assessmentComplete)
            }
        }
    }

    /// The whole street, shaken by the same earthquake.
    ///
    /// A single building swaying on a black background answers a question
    /// nobody was asking — everybody already knows buildings move. What people
    /// want to know is whether *theirs* moves more than the one next door, and
    /// that is a comparison one building cannot make. The neighbours come from
    /// OpenStreetMap, need no key, and are drawn as plain grey massing so it
    /// stays obvious which building in the scene is the one being assessed.
    private var streetControl: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: $showsStreet) {
                HStack(spacing: 6) {
                    Label("Shake the whole street", systemImage: "building.2.crop.circle")
                        .font(Theme.Typography.callout)
                    if env.block.isFetching.contains(building?.id ?? UUID()) {
                        ProgressView().controlSize(.mini)
                    }
                }
            }
            .tint(Theme.Palette.accent)

            if showsStreet, let summary = env.block.summary(for: building?.id) {
                Text(summary)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if showsStreet, controller.hasStreet {
                // The caveat that has to travel with the picture. The
                // neighbours are single-degree-of-freedom approximations from
                // an outline and a storey count — good enough to show
                // resonance, nowhere near good enough to conclude anything
                // about somebody else's building.
                Text("Your building is solved storey by storey. The neighbours are "
                     + "approximations from their outlines, so watch which ones move — "
                     + "not by how much.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
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

            if building != nil {
                let modes = cachedModes
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
        /// Where the ground itself is, this instant, in metres.
        ///
        /// Carried because the neighbouring buildings are driven by it and by
        /// nothing else — they have no solver, so the only thing shaking them
        /// is the same ground that shakes the assessed building.
        var groundDisplacement: Double = 0
    }

    @Published private(set) var frame: Frame?
    @Published private(set) var result: SimulationResult?

    /// Ground displacement per step, integrated once and kept, because
    /// integrating the whole record on every frame would be absurd.
    private var groundDisplacementCache: [Double] = []
    @Published private(set) var isRunning = false
    /// Stopped part-way through, with the response still loaded.
    ///
    /// Distinct from simply not running: a paused run can be resumed from where
    /// it stopped, scrubbed either way, and read off frame by frame — which is
    /// the whole point of pausing at the instant a storey goes red.
    @Published private(set) var isPaused = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0

    /// True once there is a solved response to play, whether or not it is
    /// currently moving.
    var hasResponse: Bool { result != nil }

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
        groundDisplacementCache = []
        isPaused = false
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
                groundDisplacementCache = []
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

    /// Holds the building where it is, mid-event.
    ///
    /// Only the clock stops. The solved response is untouched, so resuming
    /// carries on from the same step rather than re-solving — and the frame
    /// left on screen stays exactly as it was, which is what makes it possible
    /// to look at the moment a storey turned red instead of watching it go by.
    func pause() {
        guard isRunning else { return }
        timer?.invalidate()
        timer = nil
        isRunning = false
        isPaused = true
    }

    func resume() {
        guard isPaused, let result, index < result.times.count else { return }
        isPaused = false
        isRunning = true
        startPlayback()
    }

    /// Resumes if paused, pauses if running. What the one button does.
    func togglePause() { isPaused ? resume() : pause() }

    /// The ground's displacement at a step, integrated once from the
    /// acceleration record and cached.
    ///
    /// Twice-integrated accelerometer data drifts badly, so the running mean is
    /// removed first — enough for a visual, and it is only ever used as one.
    /// Nothing numeric on screen comes from this.
    private func groundDisplacement(at step: Int) -> Double {
        guard let result else { return 0 }
        if groundDisplacementCache.isEmpty {
            let samples = result.groundMotion.samples
            guard samples.count > 1 else { return 0 }
            let dt = 1 / max(result.groundMotion.sampleRate, 1)
            var velocity = 0.0, displacement = 0.0
            var series: [Double] = []
            series.reserveCapacity(samples.count)
            for value in samples {
                velocity += value * dt
                velocity *= 0.995            // bleeds off integration drift
                displacement += velocity * dt
                displacement *= 0.995
                series.append(displacement)
            }
            groundDisplacementCache = series
        }
        guard step >= 0, step < groundDisplacementCache.count else { return 0 }
        return groundDisplacementCache[step]
    }

    private func advance() {
        guard let result, index < result.times.count else {
            isRunning = false
            isPaused = false          // reached the end; there is nothing to resume
            timer?.invalidate()
            return
        }
        currentTime = result.times[index]
        let displacements = index < result.displacement.count ? result.displacement[index] : []
        let drifts = index < result.drift.count ? result.drift[index] : []
        let intensity = drifts.map(abs).max().map { min($0 / 0.02, 1) } ?? 0
        frame = Frame(displacements: displacements, drifts: drifts,
                      shakingIntensity: intensity,
                      groundDisplacement: groundDisplacement(at: index))
        index += 1
    }

    func scrub(to fraction: Double) {
        guard let result, !result.times.isEmpty else { return }
        index = min(max(Int(fraction * Double(result.times.count)), 0), result.times.count - 1)
        currentTime = result.times[index]
        let displacements = index < result.displacement.count ? result.displacement[index] : []
        let drifts = index < result.drift.count ? result.drift[index] : []
        frame = Frame(displacements: displacements, drifts: drifts, shakingIntensity: 0,
                      groundDisplacement: groundDisplacement(at: index))
        // Dragging the scrubber on a finished run leaves it ready to play on
        // from there, rather than stranded with a Resume button that does
        // nothing.
        if !isRunning, index < result.times.count - 1 { isPaused = true }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isRunning = false
        isPaused = false
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
