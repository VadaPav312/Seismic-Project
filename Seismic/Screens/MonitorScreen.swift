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
    @EnvironmentObject private var node: NodeStream

    @State private var frozen: TriaxialRecord?
    @State private var windowSeconds: Double = 30
    @State private var showsFiltered = true
    @State private var selectedAxes: Set<TriaxialRecord.Axis> = [.x, .y, .z]

    private var record: TriaxialRecord {
        frozen ?? node.snapshot?.recent ?? TriaxialRecord.zeros(count: 0, sampleRate: 100)
    }

    /// The window actually drawn, prepared off the render path.
    ///
    /// This used to be a computed property, and it was the single most
    /// expensive thing in the app. Slicing thirty seconds of three axes and
    /// running a fourth-order Butterworth over all of it is roughly nine
    /// thousand samples of IIR filtering — and being a computed property, it
    /// ran on *every* body evaluation, which the 20 Hz snapshot guaranteed.
    /// The chart then threw most of it away, because a trace 390 points wide
    /// cannot show three thousand samples per axis.
    ///
    /// Now it is computed when the data changes rather than when the view
    /// draws, and decimated to what the screen can actually resolve.
    @State private var prepared = TriaxialRecord.zeros(count: 0, sampleRate: 100)

    private var visible: TriaxialRecord {
        guard record.count > 0 else { return record }
        let from = max(record.duration - windowSeconds, 0)
        return TriaxialRecord(x: record.x.slice(from: from, to: record.duration),
                              y: record.y.slice(from: from, to: record.duration),
                              z: record.z.slice(from: from, to: record.duration))
    }

    /// Filters, then decimates to at most `maximumDrawnSamples` per axis.
    ///
    /// Decimation is by min/max pairs rather than by picking every nth sample:
    /// a seismic trace is mostly about its envelope, and plain subsampling
    /// makes a spike disappear entirely depending on where it happens to fall.
    private static let maximumDrawnSamples = 900

    private func prepare() {
        let window = visible
        guard window.count > 32 else { prepared = window; return }

        let source: TriaxialRecord
        if showsFiltered {
            let filter = ButterworthFilter(kind: .bandpass, order: 4,
                                           sampleRate: window.sampleRate,
                                           lowCutoff: 0.1,
                                           highCutoff: min(25, window.sampleRate / 2.5))
            source = TriaxialRecord(x: filter.apply(window.x),
                                    y: filter.apply(window.y),
                                    z: filter.apply(window.z))
        } else {
            source = window
        }

        prepared = TriaxialRecord(x: Self.decimated(source.x),
                                  y: Self.decimated(source.y),
                                  z: Self.decimated(source.z))
    }

    private static func decimated(_ waveform: Waveform) -> Waveform {
        guard waveform.samples.count > maximumDrawnSamples else { return waveform }
        let bucket = Int((Double(waveform.samples.count)
                          / Double(maximumDrawnSamples)).rounded(.up))
        guard bucket > 1 else { return waveform }

        var out: [Double] = []
        out.reserveCapacity(maximumDrawnSamples + 2)
        var index = 0
        while index < waveform.samples.count {
            let end = min(index + bucket, waveform.samples.count)
            let slice = waveform.samples[index..<end]
            // Both extremes of each bucket, in the order they occurred, so the
            // drawn envelope matches the real one.
            let lowest = slice.min() ?? 0
            let highest = slice.max() ?? 0
            if slice.firstIndex(of: lowest) ?? 0 <= (slice.firstIndex(of: highest) ?? 0) {
                out.append(lowest); out.append(highest)
            } else {
                out.append(highest); out.append(lowest)
            }
            index = end
        }
        // The rate is now nominal — the chart plots against sample index and the
        // window length is unchanged, so the time axis still reads correctly.
        let rate = waveform.sampleRate * Double(out.count)
            / Double(max(waveform.samples.count, 1))
        return Waveform(samples: out, sampleRate: max(rate, 1), unit: waveform.unit)
    }

    private var processed: TriaxialRecord { prepared }

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
                        action: {
                            // Clearing the freeze matters: freezing while the
                            // trace was empty latched an empty record into
                            // `frozen`, and since `record` prefers it, the
                            // screen stayed on this empty state no matter how
                            // much data arrived — which made this button look
                            // broken when it had worked perfectly.
                            frozen = nil
                            env.attachSimulatedNode()
                        })
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
                    if frozen == nil {
                        // Only freeze something worth looking at. Freezing an
                        // empty buffer pins the screen to the empty state.
                        let current = node.snapshot?.recent
                        frozen = (current?.count ?? 0) > 8 ? current : nil
                    } else {
                        frozen = nil
                    }
                } label: {
                    Label(frozen == nil ? "Freeze" : "Live",
                          systemImage: frozen == nil ? "pause.circle" : "play.circle")
                }
                .tint(frozen == nil ? Theme.Palette.accent : Theme.Palette.verdictAmber)
                .disabled(frozen == nil && (node.snapshot?.recent.count ?? 0) <= 8)
                .tutorialAnchor(.monitorFreeze)
            }
        }
        // Re-prepared when the data changes or a control moves — not on every
        // body evaluation.
        .task(id: node.revision) { prepare() }
        .onChange(of: windowSeconds) { _, _ in prepare() }
        .onChange(of: showsFiltered) { _, _ in prepare() }
        .onChange(of: frozen == nil) { _, _ in prepare() }
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

            if let ratio = node.snapshot?.ratio, ratio.count > 8 {
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
