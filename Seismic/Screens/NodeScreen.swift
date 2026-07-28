import SwiftUI
import SeismicCore
import SeismicDevice

/// Hardware status, actuators, diagnostics and the power budget.
struct NodeScreen: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var showingScanner = false

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Metrics.spacingLoose) {
                connection
                actuatorConsole
                powerBudget
                sensors
                diagnostics
                demoControls
                logView
            }
            .padding(Theme.Metrics.screenPadding)
        }
        .sheet(isPresented: $showingScanner) { NodeScannerSheet() }
    }

    // MARK: Connection

    private var connection: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.spacing) {
            HStack {
                SectionLabel("Connection", systemImage: "antenna.radiowaves.left.and.right")
                ConnectionBadge(state: env.connectionState)
            }

            if let snapshot = env.nodeSnapshot {
                ReadoutGrid(readouts: [
                    Readout(label: "Node", value: snapshot.nodeName, size: .small),
                    Readout(label: "State", value: snapshot.telemetry.state.label, size: .small),
                    Readout(label: "Dropped batches", value: "\(env.session.droppedBatches)",
                            size: .small),
                    Readout(label: "Buffered samples", value: "\(snapshot.recent.count)",
                            size: .small),
                ], columns: 2)

                if let progress = snapshot.transferProgress {
                    VStack(alignment: .leading, spacing: 5) {
                        MeaningfulProgress(
                            title: "Transferring a recording",
                            detail: snapshot.transferSummary,
                            progress: progress)
                    }
                }
            }

            HStack(spacing: Theme.Metrics.spacing) {
                Button {
                    showingScanner = true
                } label: {
                    Label("Scan for hardware", systemImage: "dot.radiowaves.left.and.right")
                        .font(Theme.Typography.callout)
                        .frame(maxWidth: .infinity)
                        .frame(height: Theme.Metrics.minimumTapTarget)
                }
                .buttonStyle(SecondaryButtonStyle())

                Button {
                    env.attachSimulatedNode()
                } label: {
                    Label("Use simulator", systemImage: "cpu")
                        .font(Theme.Typography.callout)
                        .frame(maxWidth: .infinity)
                        .frame(height: Theme.Metrics.minimumTapTarget)
                }
                .buttonStyle(SecondaryButtonStyle())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .instrumentPanel()
    }

    // MARK: Actuators

    private var actuatorConsole: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.spacing) {
            SectionLabel("Safety actuators", systemImage: "bolt.shield")

            ForEach(ActuatorKind.allCases) { kind in
                let report = env.nodeSnapshot?.actuators[kind]
                ActuatorRow(kind: kind, report: report) { command in
                    env.session.send(command)
                    Haptics.shared.play(.actuatorFired)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .instrumentPanel()
    }

    // MARK: Power

    /// The USB constraint, presented as the engineering feature it is.
    private var powerBudget: some View {
        let budget = PowerBudget.usb2
        let planner = ActuationPlanner(budget: budget)
        let steps = planner.plan(ActuatorKind.allCases)
        let draw = env.nodeSnapshot?.telemetry.activeCurrentDraw_mA ?? budget.quiescent

        return VStack(alignment: .leading, spacing: Theme.Metrics.spacing) {
            SectionLabel("Power budget", systemImage: "bolt")

            VStack(alignment: .leading, spacing: 6) {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.Palette.surfaceHighest)
                        Capsule()
                            .fill(draw > budget.supply - budget.reserve
                                  ? Theme.Palette.verdictRed : Theme.Palette.accent)
                            .frame(width: geometry.size.width
                                   * CGFloat(min(draw / budget.supply, 1)))
                    }
                }
                .frame(height: 8)

                HStack {
                    Text("\(Int(draw)) mA drawn")
                    Spacer()
                    Text("\(Int(budget.supply)) mA available")
                }
                .font(Theme.Typography.numericSmall)
                .foregroundStyle(Theme.Palette.textSecondary)
            }

            Text(budget.explanation)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider().background(Theme.Palette.hairline)

            Text("FIRING SEQUENCE")
                .font(Theme.Typography.label)
                .tracking(1)
                .foregroundStyle(Theme.Palette.textTertiary)

            ForEach(steps) { step in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Image(systemName: step.kind.systemImage)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.Palette.accent)
                        Text(step.kind.actionVerb)
                            .font(Theme.Typography.callout)
                            .foregroundStyle(Theme.Palette.textPrimary)
                        Spacer()
                        Text(String(format: "t+%.1f s · %.1f s · %d mA",
                                    step.startOffset, step.duration, Int(step.currentDraw)))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Theme.Palette.textTertiary)
                    }
                    Text(step.reason)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .instrumentPanel()
    }

    // MARK: Sensors

    private var sensors: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.spacing) {
            SectionLabel("Sensors", systemImage: "sensor")

            if let telemetry = env.nodeSnapshot?.telemetry {
                ReadoutGrid(readouts: [
                    Readout(label: "Board temp",
                            value: String(format: "%.1f", telemetry.boardTemperature), unit: "°C",
                            size: .small),
                    Readout(label: "Structure temp",
                            value: String(format: "%.1f", telemetry.structureTemperature),
                            unit: "°C", size: .small),
                    Readout(label: "Residual displacement",
                            value: String(format: "%.1f", telemetry.residualDisplacement * 1000),
                            unit: "mm",
                            tint: telemetry.residualDisplacement > 0.005
                                ? Theme.Palette.verdictAmber : Theme.Palette.textPrimary,
                            size: .small),
                    Readout(label: "Tilt",
                            value: String(format: "%.2f", telemetry.tiltAngle), unit: "°",
                            tint: telemetry.permanentTilt ? Theme.Palette.verdictRed
                                                          : Theme.Palette.textPrimary,
                            size: .small),
                ], columns: 2)

                Divider().background(Theme.Palette.hairline)

                stateRow("Grid power", telemetry.gridPowerPresent, trueLabel: "Present",
                         falseLabel: "Lost", trueIsGood: true)
                stateRow("Water", telemetry.waterDetected, trueLabel: "Detected",
                         falseLabel: "Dry", trueIsGood: false)
                stateRow("Occupancy", telemetry.occupancyDetected, trueLabel: "Occupied",
                         falseLabel: "Empty", trueIsGood: true, neutral: true)
                stateRow("Permanent tilt", telemetry.permanentTilt, trueLabel: "Latched",
                         falseLabel: "Level", trueIsGood: false)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .instrumentPanel()
    }

    private func stateRow(_ label: String, _ value: Bool, trueLabel: String,
                          falseLabel: String, trueIsGood: Bool,
                          neutral: Bool = false) -> some View {
        let good = neutral ? true : (value == trueIsGood)
        return HStack {
            Text(label)
                .font(Theme.Typography.callout)
                .foregroundStyle(Theme.Palette.textSecondary)
            Spacer()
            StatusPill(text: value ? trueLabel : falseLabel,
                       systemImage: good ? "checkmark" : "exclamationmark",
                       tint: neutral ? Theme.Palette.textSecondary
                           : (good ? Theme.Palette.verdictGreen : Theme.Palette.verdictAmber))
        }
    }

    // MARK: Diagnostics

    private var diagnostics: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.spacing) {
            SectionLabel("Diagnostics", systemImage: "stethoscope")

            HStack(spacing: Theme.Metrics.spacing) {
                Button {
                    env.session.send(.selfTest)
                } label: {
                    Label("Self-test", systemImage: "checkmark.circle")
                        .font(Theme.Typography.callout)
                        .frame(maxWidth: .infinity)
                        .frame(height: Theme.Metrics.minimumTapTarget)
                }
                .buttonStyle(SecondaryButtonStyle())

                Button {
                    env.session.send(.calibrateBaseline)
                } label: {
                    Label("Calibrate", systemImage: "scope")
                        .font(Theme.Typography.callout)
                        .frame(maxWidth: .infinity)
                        .frame(height: Theme.Metrics.minimumTapTarget)
                }
                .buttonStyle(SecondaryButtonStyle())
            }

            if let result = env.lastSelfTest {
                HStack(spacing: 6) {
                    Image(systemName: result.passed ? "checkmark.seal.fill"
                                                    : "exclamationmark.triangle.fill")
                        .foregroundStyle(result.passed ? Theme.Palette.verdictGreen
                                                       : Theme.Palette.verdictAmber)
                    Text(result.summary)
                        .font(Theme.Typography.callout)
                        .foregroundStyle(Theme.Palette.textPrimary)
                }

                ForEach(result.checks) { check in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: check.passed ? "checkmark" : "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(check.passed ? Theme.Palette.verdictGreen
                                                          : Theme.Palette.verdictRed)
                            .frame(width: 14)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(check.name)
                                .font(Theme.Typography.caption.weight(.medium))
                                .foregroundStyle(Theme.Palette.textPrimary)
                            Text(check.detail)
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Palette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            NavigationLink {
                AlgorithmCatalogScreen()
                    .seismicBackground()
                    .navigationTitle("Algorithms")
            } label: {
                HStack {
                    Text("Algorithm catalogue")
                    Spacer()
                    Text("\(AlgorithmCatalog.all.count)")
                        .font(Theme.Typography.numericSmall)
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                }
                .font(Theme.Typography.callout)
                .foregroundStyle(Theme.Palette.accent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .instrumentPanel()
    }

    // MARK: Demo

    /// Explicit demonstration controls.
    ///
    /// Present and labelled rather than hidden behind a debug flag, because the
    /// product is meant to be shown to somebody with no hardware, and hunting
    /// for a secret gesture during a demonstration is a bad look.
    private var demoControls: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.spacing) {
            SectionLabel("Demonstration", systemImage: "play.rectangle")

            Text("These inject simulated conditions so every feature can be seen without "
                 + "waiting for a real earthquake.")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            demoButton("Simulate a magnitude 6.4 nearby", "waveform.badge.exclamationmark") {
                env.simulateEarthquake(magnitude: 6.4, distanceKm: 22)
            }
            demoButton("Simulate a distant magnitude 7.4", "globe") {
                env.simulateEarthquake(magnitude: 7.4, distanceKm: 140)
            }
            demoButton("Introduce structural damage", "bandage") {
                env.introduceSimulatedDamage()
            }
            demoButton("Drop the connection mid-event", "wifi.slash") {
                env.simulateConnectionLoss()
            }
            demoButton("Restore the connection", "wifi") {
                env.restoreConnection()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .instrumentPanel()
    }

    private func demoButton(_ title: String, _ icon: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(Theme.Typography.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 42)
                .padding(.horizontal, 12)
        }
        .buttonStyle(SecondaryButtonStyle())
    }

    private var logView: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Node log", trailing: "\(env.nodeLog.count) lines")

            if env.nodeLog.isEmpty {
                Text("Nothing logged yet.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textTertiary)
            } else {
                ForEach(env.nodeLog.prefix(25)) { line in
                    HStack(alignment: .top, spacing: 8) {
                        Text(line.at.formatted(date: .omitted, time: .standard))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Theme.Palette.textTertiary)
                        Text(line.text)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .instrumentPanel()
    }
}

/// One actuator, with its state and how it was confirmed.
struct ActuatorRow: View {
    let kind: ActuatorKind
    let report: ActuatorReport?
    let send: (NodeCommand) -> Void

    private var state: ActuatorState { report?.state ?? .idle }

    private var tint: Color {
        switch state {
        case .confirmed: Theme.Palette.verdictGreen
        case .failed: Theme.Palette.verdictRed
        case .inProgress, .commanded, .queued: Theme.Palette.verdictAmber
        default: Theme.Palette.textSecondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: kind.systemImage)
                    .font(.system(size: 15))
                    .foregroundStyle(tint)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 1) {
                    Text(kind.label)
                        .font(Theme.Typography.callout.weight(.medium))
                        .foregroundStyle(Theme.Palette.textPrimary)
                    Text(state.label)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(tint)
                }

                Spacer(minLength: 0)

                Button("Fire") { send(.fireActuator(kind)) }
                    .font(Theme.Typography.label)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .buttonStyle(SecondaryButtonStyle())

                Button("Reset") { send(.resetActuator(kind)) }
                    .font(Theme.Typography.label)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .buttonStyle(SecondaryButtonStyle())
            }

            // How it was confirmed matters more than that it was commanded.
            // A command with no independent confirmation is a rumour.
            HStack(spacing: 5) {
                Image(systemName: state == .confirmed ? "checkmark.seal.fill" : "questionmark.circle")
                    .font(.system(size: 10))
                Text(state == .confirmed
                     ? kind.confirmation.label
                     : "Will be confirmed by: \(kind.confirmation.label.lowercased())")
                    .font(Theme.Typography.caption)
            }
            .foregroundStyle(state == .confirmed ? Theme.Palette.verdictGreen
                                                 : Theme.Palette.textTertiary)

            if let reason = report?.failureReason {
                Text(reason)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.verdictRed)
            }
            if let elapsed = report?.elapsed {
                Text(String(format: "Completed in %.2f s", elapsed))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

/// The bluetooth scanner, structured as a guided list.
struct NodeScannerSheet: View {
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.Metrics.spacing) {
                    if env.discoveredNodes.isEmpty {
                        DesignedEmptyState(
                            icon: "dot.radiowaves.left.and.right",
                            title: "Looking for nodes",
                            message: "Make sure the node is powered and within a few metres. "
                                + "If you do not have hardware yet, the simulated node behaves "
                                + "identically and needs nothing at all.",
                            actionTitle: "Use the simulated node",
                            action: {
                                env.attachSimulatedNode()
                                dismiss()
                            })
                            .frame(minHeight: 360)
                    } else {
                        ForEach(env.discoveredNodes) { node in
                            Button {
                                env.session.connect(to: node.id)
                                dismiss()
                            } label: {
                                HStack(spacing: Theme.Metrics.spacing) {
                                    Image(systemName: node.isSimulated
                                          ? "cpu" : "sensor.tag.radiowaves.forward")
                                        .font(.title3)
                                        .foregroundStyle(Theme.Palette.accent)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(node.name)
                                            .font(Theme.Typography.headline)
                                            .foregroundStyle(Theme.Palette.textPrimary)
                                        Text("\(node.rssi) dBm · \(node.signalBars)/4 bars")
                                            .font(Theme.Typography.caption)
                                            .foregroundStyle(Theme.Palette.textSecondary)
                                    }
                                    Spacer()
                                    if node.isSimulated {
                                        StatusPill(text: "Simulated",
                                                   tint: Theme.Palette.accent)
                                    }
                                }
                                .instrumentPanel()
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(Theme.Metrics.screenPadding)
            }
            .seismicBackground()
            .navigationTitle("Find a node")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .onAppear { env.session.startScanning() }
        }
    }
}

/// Every algorithm, and where its output appears. Tapping one explains it.
struct AlgorithmCatalogScreen: View {
    @State private var family: AlgorithmEntry.Family?

    private var entries: [AlgorithmEntry] {
        guard let family else { return AlgorithmCatalog.all }
        return AlgorithmCatalog.family(family)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Metrics.spacing) {
                Text("Every algorithm in the system, and where you can see its output. "
                     + "\(AlgorithmCatalog.countedAlgorithms) of these are the core set; the "
                     + "rest are the supporting infrastructure they need.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        chip("All", isSelected: family == nil) { family = nil }
                        ForEach(AlgorithmEntry.Family.allCases) { candidate in
                            chip(candidate.rawValue, isSelected: family == candidate) {
                                family = candidate
                            }
                        }
                    }
                }

                ForEach(entries) { entry in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 8) {
                            Text("\(entry.number)")
                                .font(Theme.Typography.numericSmall)
                                .foregroundStyle(Theme.Palette.accent)
                                .frame(width: 24, alignment: .trailing)
                            Text(entry.name)
                                .font(Theme.Typography.callout.weight(.medium))
                                .foregroundStyle(Theme.Palette.textPrimary)
                        }
                        Text(entry.purpose)
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 4) {
                            Image(systemName: "eye")
                                .font(.system(size: 9))
                            Text(entry.surfacedAt)
                                .font(.system(size: 10))
                        }
                        .foregroundStyle(Theme.Palette.textTertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .instrumentPanel(padding: 12)
                }
            }
            .padding(Theme.Metrics.screenPadding)
        }
    }

    private func chip(_ title: String, isSelected: Bool,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Theme.Typography.label)
                .padding(.horizontal, 11).padding(.vertical, 7)
        }
        .buttonStyle(SecondaryButtonStyle())
        .opacity(isSelected ? 1 : 0.5)
    }
}

#Preview {
    NavigationStack {
        NodeScreen()
            .seismicBackground()
            .navigationTitle("Node")
    }
    .previewEnvironment()
}
