import SwiftUI
import SeismicCore
import SeismicSignal

/// The live seismograph.
///
/// Three axes, the trigger ratio beneath, and the processing chain laid open so
/// the user can see exactly what has been done to the signal between the sensor
/// and the screen. Freezing the trace is a first-class action rather than a
/// hidden gesture, because the interesting moment is always the one that has
/// just scrolled past.
struct MonitorScreen: View {
    @EnvironmentObject private var env: AppEnvironment

    @State private var frozen: TriaxialRecord?
    @State private var windowSeconds: Double = 30
    @State private var showsFiltered = true
    @State private var selectedAxes: Set<TriaxialRecord.Axis> = [.x, .y, .z]

    private var record: TriaxialRecord {
        frozen ?? env.nodeSnapshot?.recent ?? TriaxialRecord.zeros(count: 0, sampleRate: 100)
    }

    private var visible: TriaxialRecord {
        guard record.count > 0 else { return record }
        let from = max(record.duration - windowSeconds, 0)
        return TriaxialRecord(x: record.x.slice(from: from, to: record.duration),
                              y: record.y.slice(from: from, to: record.duration),
                              z: record.z.slice(from: from, to: record.duration))
    }

    private var processed: TriaxialRecord {
        guard showsFiltered, visible.count > 32 else { return visible }
        let filter = ButterworthFilter(kind: .bandpass, order: 4,
                                       sampleRate: visible.sampleRate,
                                       lowCutoff: 0.1,
                                       highCutoff: min(25, visible.sampleRate / 2.5))
        return TriaxialRecord(x: filter.apply(visible.x),
                              y: filter.apply(visible.y),
                              z: filter.apply(visible.z))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Metrics.spacingLoose) {
                if record.count < 8 {
                    DesignedEmptyState(
                        icon: "waveform.path.ecg",
                        title: "Waiting for data",
                        message: "The node streams continuously once connected. If nothing "
                            + "appears within a few seconds, check the connection on the node "
                            + "screen — or use the simulated node, which needs no hardware.",
                        actionTitle: "Use the simulated node",
                        action: { env.attachSimulatedNode() })
                        .frame(minHeight: 380)
                } else {
                    traces
                    controls
                    liveValues
                    processingChain
                }
            }
            .padding(Theme.Metrics.screenPadding)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Haptics.shared.play(.selection)
                    frozen = frozen == nil ? env.nodeSnapshot?.recent : nil
                } label: {
                    Label(frozen == nil ? "Freeze" : "Live",
                          systemImage: frozen == nil ? "pause.circle" : "play.circle")
                }
                .tint(frozen == nil ? Theme.Palette.accent : Theme.Palette.verdictAmber)
            }
        }
    }

    private var traces: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.spacing) {
            HStack {
                SectionLabel("Ground motion", systemImage: "waveform")
                if frozen != nil {
                    StatusPill(text: "Frozen", systemImage: "pause.fill",
                               tint: Theme.Palette.verdictAmber, filled: true)
                }
                ConnectionBadge(state: env.connectionState, showsLabel: false)
            }

            WaveformChart(channels: channels, height: 210, unitLabel: "m/s²")

            if let ratio = env.nodeSnapshot?.ratio, ratio.count > 8 {
                TriggerRatioStrip(ratio: ratio, threshold: 4.0)
            }
        }
        .instrumentPanel()
    }

    private var channels: [WaveformChart.Channel] {
        let source = processed
        var out: [WaveformChart.Channel] = []
        if selectedAxes.contains(.x) {
            out.append(.init(id: "x", waveform: source.x,
                             color: Theme.Palette.axisX, label: "N–S"))
        }
        if selectedAxes.contains(.y) {
            out.append(.init(id: "y", waveform: source.y,
                             color: Theme.Palette.axisY, label: "E–W"))
        }
        if selectedAxes.contains(.z) {
            out.append(.init(id: "z", waveform: source.z,
                             color: Theme.Palette.axisZ, label: "Vertical", dashed: true))
        }
        return out
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.spacing) {
            SectionLabel("View")

            HStack(spacing: 8) {
                ForEach(TriaxialRecord.Axis.allCases, id: \.self) { axis in
                    Button {
                        Haptics.shared.play(.selection)
                        if selectedAxes.contains(axis), selectedAxes.count > 1 {
                            selectedAxes.remove(axis)
                        } else {
                            selectedAxes.insert(axis)
                        }
                    } label: {
                        Text(axis.label)
                            .font(Theme.Typography.label)
                            .frame(maxWidth: .infinity)
                            .frame(height: 34)
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .opacity(selectedAxes.contains(axis) ? 1 : 0.45)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Window")
                        .font(Theme.Typography.label)
                        .foregroundStyle(Theme.Palette.textTertiary)
                    Spacer()
                    Text("\(Int(windowSeconds)) s")
                        .font(Theme.Typography.numericSmall)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
                Slider(value: $windowSeconds, in: 5...60, step: 5)
                    .tint(Theme.Palette.accent)
            }

            Toggle(isOn: $showsFiltered) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Bandpass filter")
                        .font(Theme.Typography.callout)
                    Text("0.1–25 Hz. Removes drift and electrical hash without touching the "
                         + "seismic band.")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
            }
            .tint(Theme.Palette.accent)
        }
        .instrumentPanel()
    }

    private var liveValues: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.spacing) {
            SectionLabel("Live values")

            let peaks = GroundMotion.peaks(visible)
            ReadoutGrid(readouts: [
                Readout(label: "Peak acceleration",
                        value: String(format: "%.4f", peaks.pga / gravity), unit: "g",
                        tint: Theme.Palette.accent, size: .large),
                Readout(label: "Intensity",
                        value: peaks.mercalli.roman,
                        size: .large,
                        caption: peaks.mercalli.shortLabel),
                Readout(label: "Peak velocity",
                        value: String(format: "%.4f", peaks.pgv), unit: "m/s"),
                Readout(label: "Peak displacement",
                        value: String(format: "%.4f", peaks.pgd), unit: "m"),
            ], columns: 2)
        }
        .instrumentPanel()
    }

    /// The processing chain, laid open.
    ///
    /// Anyone can claim their app filters the signal. Showing which stages ran,
    /// in order, with their settings, is what lets an engineer decide whether to
    /// believe the number at the end of it.
    private var processingChain: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.spacing) {
            SectionLabel("Processing chain", systemImage: "gearshape.2")

            ForEach(Array(chainSteps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .top, spacing: 10) {
                    Text("\(index + 1)")
                        .font(Theme.Typography.numericSmall)
                        .foregroundStyle(Theme.Palette.accent)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(step.0)
                            .font(Theme.Typography.callout.weight(.medium))
                            .foregroundStyle(Theme.Palette.textPrimary)
                        Text(step.1)
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .instrumentPanel()
    }

    private var chainSteps: [(String, String)] {
        var steps: [(String, String)] = [
            ("Raw samples", "\(Int(record.sampleRate)) Hz, three axes, "
             + "\(record.count) samples buffered."),
            ("DC offset removal", "The sensor's resting bias is subtracted, so integration "
             + "does not run away."),
        ]
        if showsFiltered {
            steps.append(("Butterworth bandpass",
                          "4th order, 0.1–25 Hz, zero phase. Applied forward and backward so "
                          + "arrival times are not shifted."))
        }
        steps.append(("Recursive STA/LTA",
                      "0.5 s over 10 s, triggering at 4.0×. This is the same arithmetic the "
                      + "node runs continuously."))
        steps.append(("Min/max decimation",
                      "The trace is reduced to the screen's pixel width while keeping every "
                      + "peak, so nothing is lost to drawing."))
        return steps
    }
}

#Preview {
    NavigationStack {
        MonitorScreen()
            .seismicBackground()
            .navigationTitle("Monitor")
    }
    .previewEnvironment()
}
