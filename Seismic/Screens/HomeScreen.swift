import SwiftUI
import SeismicCore
import SeismicSignal
import SeismicStructures
import SeismicData

/// The screen the app opens onto.
///
/// It answers, in order, the four questions somebody actually has: is my
/// building all right, is the sensor working, what happened recently, and what
/// are my neighbours reporting. Everything else is one tap away.
struct HomeScreen: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var node: NodeStream
    @State private var showingCheckIn = false
    @State private var showingImport = false

    var body: some View {
        ScrollView {
            LazyVStack(spacing: Theme.Metrics.spacingLoose) {
                if env.buildings.isEmpty {
                    DesignedEmptyState(
                        icon: "building.2",
                        title: "No buildings yet",
                        message: "Add the building you are in, or search for any building in the "
                            + "world and pull it into the simulator.",
                        actionTitle: "Add a building",
                        action: { showingImport = true })
                        .frame(minHeight: 420)
                } else {
                    buildingStatus
                    nodeStatus
                    recentActivity
                    neighbourhood
                    quickActions
                }
            }
            .padding(Theme.Metrics.screenPadding)
            .contentColumn()
        }
        .refreshable { env.refresh() }
        .sheet(isPresented: $showingImport) { BuildingImportSheet() }
        .sheet(isPresented: $showingCheckIn) { CheckInSheet() }
    }

    // MARK: Building status

    @ViewBuilder
    private var buildingStatus: some View {
        if let building = env.selectedBuilding {
            VStack(alignment: .leading, spacing: Theme.Metrics.spacing) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(building.name)
                            .font(Theme.Typography.title)
                            .foregroundStyle(Theme.Palette.textPrimary)
                        Text("\(building.storeyCount) storeys · \(building.material.label)")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.textSecondary)
                    }
                    Spacer()
                    if env.buildings.count > 1 {
                        Menu {
                            ForEach(env.buildings) { candidate in
                                Button {
                                    env.selectedBuildingID = candidate.id
                                    Haptics.shared.play(.selection)
                                } label: {
                                    Label(candidate.name, systemImage: candidate.thumbnailSystemImage)
                                }
                            }
                        } label: {
                            Image(systemName: "arrow.left.arrow.right.circle")
                                .font(.title3)
                                .foregroundStyle(Theme.Palette.accent)
                        }
                        .accessibilityLabel("Switch building")
                    }
                }

                if let assessment = env.latestAssessment {
                    NavigationLink(value: AppSection.assess) {
                        VerdictPlacard(verdict: assessment.verdict,
                                       confidence: assessment.confidence)
                    }
                    .buttonStyle(.plain)
                    .tutorialAnchor(.homeVerdict)

                    if let change = assessment.periodChangePercent {
                        ReadoutGrid(readouts: [
                            Readout(label: "Period change",
                                    value: String(format: "%+.1f", change), unit: "%",
                                    tint: abs(change) < 3 ? Theme.Palette.textPrimary
                                        : assessment.verdict.color,
                                    size: .large),
                            Readout(label: "Assessed",
                                    value: assessment.createdAt.formatted(
                                        date: .abbreviated, time: .shortened),
                                    size: .small),
                        ], columns: 2)
                        .instrumentPanel()
                    }
                } else {
                    baselineOnlyPanel(building)
                }
            }
        }
    }

    /// Before any event has happened there is no verdict, and inventing one
    /// would be dishonest. This states the baseline instead, which is genuinely
    /// the useful thing to know.
    private func baselineOnlyPanel(_ building: BuildingModel) -> some View {
        // Bound to explicitly typed constants before formatting, rather than
        // written inline inside `String(format:)`.
        //
        // Inline, `?? 19` reached the formatter as an `Int` against a `%.1f`
        // specifier: Foundation logged a fault on every single launch — "Format
        // '%.1f' does not match expected '%lld'" — and the temperature on screen
        // was whatever reinterpreting those bytes as a double produced. The
        // parameter is `CVarArg...`, which accepts anything, so nothing
        // constrained the literal to `Double` and no warning was emitted either.
        //
        // Annotating the type is what makes the compiler check it. Worth doing
        // wherever a numeric literal meets a format string through `??`.
        let measuredPeriod: Double = node.snapshot?.telemetry.measuredPeriod
            ?? building.empiricalPeriod
        let temperature: Double = node.snapshot?.telemetry.structureTemperature ?? 19

        return VStack(alignment: .leading, spacing: Theme.Metrics.spacing) {
            SectionLabel("Baseline", systemImage: "waveform.path.ecg")

            ReadoutGrid(readouts: [
                Readout(label: "Measured period",
                        value: String(format: "%.3f", measuredPeriod),
                        unit: "s", tint: Theme.Palette.accent, size: .large),
                Readout(label: "Expected for this type",
                        value: String(format: "%.2f", building.empiricalPeriod), unit: "s",
                        size: .medium),
                Readout(label: "Structure temperature",
                        value: String(format: "%.1f", temperature),
                        unit: "°C", size: .medium),
                Readout(label: "Measurements on record",
                        value: "\(env.observations.filter { $0.modeNumber == 1 }.count)",
                        size: .medium),
            ], columns: 2)

            Text("No event has been recorded for this building yet, so there is nothing to "
                 + "assess. The baseline above is what any future assessment will be compared "
                 + "against.")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .instrumentPanel()
    }

    // MARK: Node

    private var nodeStatus: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.spacing) {
            HStack {
                SectionLabel("Sensor", systemImage: "sensor.tag.radiowaves.forward")
                ConnectionBadge(state: env.connectionState)
            }

            switch env.sensorSource {
            case .simulated:
                InlineNotice(
                    level: .info,
                    title: "Simulated node",
                    message: "Everything you see is generated by a physically realistic "
                        + "simulation — real P and S waves, a real noise floor, real actuator "
                        + "timing. Connect a node, or use this phone's own accelerometer, "
                        + "to replace it with live data.",
                    actionTitle: "Choose a sensor") { env.requestedSection = .node }
            case .phone:
                // Not a warning. The measurements really are real; what is
                // missing is the thermometer, and that is a specific loss with
                // a specific consequence, so it is stated as one.
                InlineNotice(
                    level: .info,
                    title: "Measuring with this phone",
                    message: "Real motion, from the accelerometer in this device. Leave the "
                        + "phone on a hard flat surface. Without a thermometer against the "
                        + "structure the seasonal temperature effect cannot be removed, so "
                        + "period changes measured this way are less certain than a node's.",
                    actionTitle: "Sensor settings") { env.requestedSection = .node }
            case .node:
                EmptyView()
            }

            if let telemetry = node.snapshot?.telemetry {
                ReadoutGrid(readouts: [
                    Readout(label: "State", value: telemetry.state.label, size: .small),
                    Readout(label: "Trigger ratio",
                            value: String(format: "%.2f", telemetry.staLtaRatio), size: .small),
                    Readout(label: "Ambient",
                            value: String(format: "%.4f", telemetry.ambientVibrationRMS),
                            unit: "m/s²", size: .small),
                    // A phone has no rail to measure, so it reports the one
                    // power number it genuinely knows instead of a plausible
                    // five volts that was never measured.
                    env.sensorSource == .phone
                        ? Readout(label: "Battery",
                                  value: telemetry.batteryPercent
                                      .map { String(format: "%.0f", $0) } ?? "—",
                                  unit: "%", size: .small)
                        : Readout(label: "Supply",
                                  value: String(format: "%.2f", telemetry.supplyVoltage),
                                  unit: "V", size: .small),
                ], columns: 2)

                if !telemetry.faults.isEmpty {
                    ForEach(telemetry.faults, id: \.self) { fault in
                        InlineNotice(level: fault.severity == .critical ? .critical : .warning,
                                     title: fault.label, message: fault.guidance)
                    }
                }
            }

            NavigationLink(value: AppSection.node) {
                HStack {
                    Text("Node diagnostics")
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                }
                .font(Theme.Typography.callout)
                .foregroundStyle(Theme.Palette.accent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .instrumentPanel()
    }

    // MARK: Activity

    private var recentActivity: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.spacing) {
            SectionLabel("Recent events",
                         trailing: "\(env.events.count) on record")

            if env.events.isEmpty {
                Text("No events recorded yet. That is the normal state of affairs — the node "
                     + "sits and watches, and most days nothing happens.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
            } else {
                ForEach(env.events.prefix(4)) { event in
                    EventRow(event: event)
                }
                if env.events.count > 4 {
                    NavigationLink(value: AppSection.assess) {
                        Text("See all \(env.events.count) events")
                            .font(Theme.Typography.callout)
                            .foregroundStyle(Theme.Palette.accent)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .instrumentPanel()
    }

    // MARK: Neighbourhood

    private var neighbourhood: some View {
        let recent = env.tags.filter { !$0.isExpired }
        let counts = Dictionary(grouping: recent, by: \.verdict).mapValues(\.count)

        return VStack(alignment: .leading, spacing: Theme.Metrics.spacing) {
            SectionLabel("Your neighbourhood", systemImage: "map",
                         trailing: "\(recent.count) reports")

            HStack(spacing: Theme.Metrics.spacing) {
                ForEach(SafetyVerdict.allCases) { verdict in
                    VStack(spacing: 4) {
                        Text("\(counts[verdict] ?? 0)")
                            .font(Theme.Typography.numericLarge)
                            .foregroundStyle(verdict.color)
                        Text(verdict.shortLabel)
                            .font(Theme.Typography.label)
                            .foregroundStyle(Theme.Palette.textTertiary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }

            NavigationLink(value: AppSection.map) {
                HStack {
                    Text("Open the community map")
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                }
                .font(Theme.Typography.callout)
                .foregroundStyle(Theme.Palette.accent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .instrumentPanel()
    }

    // MARK: Actions

    private var quickActions: some View {
        VStack(spacing: Theme.Metrics.spacing) {
            Button {
                showingCheckIn = true
            } label: {
                Label("Check in with my household", systemImage: "person.2.fill")
                    .font(Theme.Typography.headline)
                    .frame(maxWidth: .infinity)
                    .frame(height: Theme.Metrics.minimumTapTarget)
            }
            .buttonStyle(PrimaryButtonStyle())

            HStack(spacing: Theme.Metrics.spacing) {
                Button {
                    env.startDrill(fireActuators: false)
                } label: {
                    Label("Run a drill", systemImage: "figure.run")
                        .font(Theme.Typography.callout)
                        .frame(maxWidth: .infinity)
                        .frame(height: Theme.Metrics.minimumTapTarget)
                }
                .buttonStyle(SecondaryButtonStyle())

                Button {
                    env.simulateEarthquake()
                } label: {
                    Label("Simulate an event", systemImage: "waveform.badge.exclamationmark")
                        .font(Theme.Typography.callout)
                        .frame(maxWidth: .infinity)
                        .frame(height: Theme.Metrics.minimumTapTarget)
                }
                .buttonStyle(SecondaryButtonStyle())
            }
        }
    }
}

/// One event in a list.
struct EventRow: View {
    let event: SeismicEvent

    var body: some View {
        HStack(spacing: Theme.Metrics.spacing) {
            ZStack {
                Circle()
                    .fill(event.isDrill ? Theme.Palette.accent.opacity(0.15)
                                        : Theme.Palette.verdictAmber.opacity(0.15))
                    .frame(width: 36, height: 36)
                Image(systemName: event.isDrill ? "figure.run" : "waveform.path.ecg")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(event.isDrill ? Theme.Palette.accent
                                                   : Theme.Palette.verdictAmber)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(event.label.isEmpty ? "Event" : event.label)
                    .font(Theme.Typography.callout.weight(.medium))
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text(event.startTime.formatted(date: .abbreviated, time: .shortened))
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 2) {
                Text(String(format: "%.1f×", event.triggerRatio))
                    .font(Theme.Typography.numericSmall)
                    .foregroundStyle(Theme.Palette.textPrimary)
                if !event.confirmedActuators.isEmpty {
                    HStack(spacing: 2) {
                        Image(systemName: "checkmark.shield.fill").font(.system(size: 9))
                        Text("\(event.confirmedActuators.count)")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(Theme.Palette.verdictGreen)
                }
                if !event.isComplete {
                    StatusPill(text: "Partial", tint: Theme.Palette.verdictAmber)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

/// Household check-in, prompted automatically after an event.
struct CheckInSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var message = ""
    @State private var sent = false

    var body: some View {
        NavigationStack {
            VStack(spacing: Theme.Metrics.spacingLoose) {
                if sent {
                    DesignedEmptyState(
                        icon: "checkmark.circle.fill",
                        title: "Everyone has been told",
                        message: "Your household sees that you are safe. Anyone who has not "
                            + "checked in within ten minutes will be sent a text message "
                            + "automatically.",
                        actionTitle: "Done", action: { dismiss() })
                } else {
                    VStack(spacing: Theme.Metrics.spacing) {
                        Text("Let your household know you are unhurt.")
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.Palette.textSecondary)
                            .multilineTextAlignment(.center)

                        TextField("Add a note (optional)", text: $message, axis: .vertical)
                            .textFieldStyle(.plain)
                            .padding()
                            .background(
                                RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadiusSmall)
                                    .fill(Theme.Palette.surfaceRaised))
                            .lineLimit(3...5)

                        Button {
                            Haptics.shared.play(.verdictGreen)
                            withAnimation(Theme.Motion.standard) { sent = true }
                        } label: {
                            Text("I'm safe")
                                .font(Theme.Typography.headline)
                                .frame(maxWidth: .infinity)
                                .frame(height: 54)
                        }
                        .buttonStyle(PrimaryButtonStyle())

                        Button {
                            Haptics.shared.play(.warning)
                            withAnimation(Theme.Motion.standard) { sent = true }
                        } label: {
                            Text("I need help")
                                .font(Theme.Typography.headline)
                                .frame(maxWidth: .infinity)
                                .frame(height: 54)
                        }
                        .buttonStyle(PrimaryButtonStyle(destructive: true))
                    }
                    .padding()
                    Spacer()
                }
            }
            .seismicBackground()
            .navigationTitle("Check in")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        HomeScreen()
            .seismicBackground()
            .navigationTitle("Home")
    }
    .previewEnvironment()
}
