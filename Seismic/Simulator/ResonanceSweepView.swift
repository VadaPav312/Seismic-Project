import SwiftUI
import Charts
import SeismicCore
import SeismicStructures

/// Drives the building across a range of frequencies and plots how much it
/// amplifies each one.
///
/// This is the demonstration that makes resonance land. Everyone has been told
/// that a building has a natural frequency; almost nobody has seen the curve,
/// and the curve is dramatic — a factor of ten or more, concentrated in a
/// narrow band, falling away to nothing on either side. It is also exactly what
/// the physical shake table measures, which is why the two can be laid over one
/// another on the same axes.
struct ResonanceSweepView: View {
    let building: BuildingModel
    /// Points measured on the shake table, if the user has run one. Overlaid so
    /// prediction and measurement can be compared directly rather than
    /// described to each other.
    var measured: [ResonanceSweep.Point] = []

    @Environment(\.dismiss) private var dismiss
    @StateObject private var sonifier = PeriodSonifier()

    @State private var points: [ResonanceSweep.Point] = []
    @State private var isSweeping = false
    @State private var progress: Double = 0
    @State private var selectedFrequency: Double?
    @State private var amplitude: Double = 0.5

    private var naturalFrequency: Double {
        let period = ModalAnalysis.fundamentalPeriod(of: ShearBuilding.from(building))
        return period > 0 ? 1 / period : 0
    }

    private var peak: ResonanceSweep.Point? {
        points.max { $0.amplification < $1.amplification }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Metrics.spacingSection) {
                    header
                    chart
                    readouts
                    if !points.isEmpty { explanation }
                }
                .padding(Theme.Metrics.screenPadding)
            }
            .seismicBackground()
            .navigationTitle("Resonance")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { sonifier.stop(); dismiss() }
                }
            }
            .task { if points.isEmpty { await runSweep() } }
            .onDisappear { sonifier.stop() }
        }
    }

    // MARK: Pieces

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(building.name)
                .font(Theme.Typography.headline)
                .foregroundStyle(Theme.Palette.textPrimary)
            Text("The building is driven at each frequency in turn and the roof movement is "
                 + "compared with the ground movement. The peak is where it amplifies most.")
                .font(Theme.Typography.callout)
                .foregroundStyle(Theme.Palette.textSecondary)
        }
    }

    @ViewBuilder
    private var chart: some View {
        if isSweeping && points.isEmpty {
            MeaningfulProgress(title: "Sweeping",
                               detail: "Running a full time-history solve at each of 60 "
                                     + "frequencies. This is the real solver, not a curve fit.",
                               progress: progress)
                .frame(height: 260)
                .instrumentPanel()
        } else if points.isEmpty {
            DesignedEmptyState(icon: "waveform.path",
                               title: "No sweep yet",
                               message: "Run a sweep to see which frequencies this building "
                                      + "amplifies.",
                               actionTitle: "Run sweep",
                               action: { Task { await runSweep() } })
                .frame(height: 260)
        } else {
            Chart {
                ForEach(points) { point in
                    LineMark(x: .value("Frequency", point.frequency),
                             y: .value("Amplification", point.amplification))
                        .foregroundStyle(Theme.Palette.accent)
                        .interpolationMethod(.catmullRom)
                }
                if !measured.isEmpty {
                    ForEach(measured) { point in
                        PointMark(x: .value("Frequency", point.frequency),
                                  y: .value("Amplification", point.amplification))
                            .foregroundStyle(Theme.Palette.verdictAmber)
                            .symbolSize(40)
                    }
                }
                if naturalFrequency > 0 {
                    RuleMark(x: .value("Natural", naturalFrequency))
                        .foregroundStyle(Theme.Palette.textTertiary)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        // Carries its own background. Sitting bare over the
                        // plot it collided with whatever line or label was
                        // behind it and neither could be read.
                        .annotation(position: .top, alignment: .leading) {
                            Text("natural")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(Theme.Palette.textTertiary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Theme.Palette.surface.opacity(0.92),
                                            in: Capsule(style: .continuous))
                                .padding(.leading, 3)
                        }
                }
                if let selectedFrequency,
                   let point = points.min(by: {
                       abs($0.frequency - selectedFrequency) < abs($1.frequency - selectedFrequency)
                   }) {
                    RuleMark(x: .value("Selected", point.frequency))
                        .foregroundStyle(Theme.Palette.accent.opacity(0.4))
                }
            }
            .chartXScale(type: .log)
            .chartXAxisLabel("Driving frequency (Hz)")
            .chartYAxisLabel("Roof movement ÷ ground movement")
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                guard let plotFrame = proxy.plotFrame else { return }
                                let x = value.location.x - geometry[plotFrame].origin.x
                                if let frequency: Double = proxy.value(atX: x) {
                                    selectedFrequency = frequency
                                    scrub(to: frequency)
                                }
                            }
                            .onEnded { _ in sonifier.stop() })
                }
            }
            .frame(height: 260)
            .instrumentPanel()
        }
    }

    @ViewBuilder
    private var readouts: some View {
        if let peak {
            ReadoutGrid(readouts: [
                Readout(label: "Peak amplification",
                        value: String(format: "%.1f", peak.amplification), unit: "×",
                        tint: Theme.Palette.accent, size: .large,
                        caption: "at \(String(format: "%.2f", peak.frequency)) Hz"),
                Readout(label: "Natural frequency",
                        value: String(format: "%.2f", naturalFrequency), unit: "Hz",
                        caption: String(format: "period %.2f s", 1 / max(naturalFrequency, 1e-6))),
                Readout(label: "Half-power width",
                        value: String(format: "%.2f", halfPowerWidth), unit: "Hz",
                        caption: "narrower means less damping"),
                Readout(label: "Damping implied",
                        value: String(format: "%.1f", impliedDamping * 100), unit: "%",
                        caption: "from the curve's width"),
            ])
        }

        if let selectedFrequency, let point = nearest(to: selectedFrequency) {
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel("At \(String(format: "%.2f", point.frequency)) Hz")
                Text(String(format: "The roof moves %.1f times as far as the ground, "
                            + "reaching %.0f mm.",
                            point.amplification, point.roofDisplacement * 1000))
                    .font(Theme.Typography.callout)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            .instrumentPanel()
        }
    }

    private var explanation: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.spacing) {
            SectionLabel("What this means", systemImage: "text.book.closed")
            Text(narrativeText)
                .font(Theme.Typography.callout)
                .foregroundStyle(Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                sonifier.play(period: 1 / max(naturalFrequency, 1e-6))
            } label: {
                Label("Hear this building", systemImage: "waveform")
            }
            .buttonStyle(SecondaryButtonStyle())

            if sonifier.isPlaying {
                Text(sonifier.describedPitch)
                    .font(Theme.Typography.numericSmall)
                    .foregroundStyle(Theme.Palette.accent)
                Button("Stop") { sonifier.stop() }
                    .buttonStyle(SecondaryButtonStyle())
            }
        }
        .instrumentPanel()
    }

    private var narrativeText: String {
        guard let peak else { return "" }
        let soil = building.soil
        var text = String(format: "This building amplifies motion near %.2f Hz by about %.0f "
                          + "times. Ground motion at other frequencies passes through it "
                          + "largely unchanged, which is why an earthquake's frequency content "
                          + "matters as much as its size.",
                          peak.frequency, peak.amplification)
        // Soil resonance is the reason two identical buildings a mile apart can
        // fare completely differently, so it is stated whenever it applies.
        let soilFrequency = soil.resonantPeriod > 0 ? 1 / soil.resonantPeriod : 0
        if soilFrequency > 0, abs(soilFrequency - peak.frequency) / peak.frequency < 0.3 {
            text += String(format: " The ground beneath it resonates near %.2f Hz as well, so "
                           + "soil and structure reinforce one another — the worst case, and "
                           + "the reason Mexico City's 1985 damage was concentrated in "
                           + "buildings of one particular height.", soilFrequency)
        }
        return text
    }

    private func nearest(to frequency: Double) -> ResonanceSweep.Point? {
        points.min { abs($0.frequency - frequency) < abs($1.frequency - frequency) }
    }

    /// Scrubbing the chart plays the frequency under the finger. Sweeping
    /// across the peak is audible as well as visible.
    private func scrub(to frequency: Double) {
        guard frequency > 0.05 else { return }
        sonifier.play(period: 1 / frequency)
    }

    /// The width of the peak at 1/√2 of its height. Narrow means lightly
    /// damped, which is the same reading a half-power bandwidth gives.
    private var halfPowerWidth: Double {
        guard let peak, peak.amplification > 0 else { return 0 }
        let threshold = peak.amplification / 1.4142
        let above = points.filter { $0.amplification >= threshold }.map(\.frequency)
        guard let low = above.min(), let high = above.max(), high > low else { return 0 }
        return high - low
    }

    private var impliedDamping: Double {
        guard let peak, peak.frequency > 0 else { return 0 }
        return halfPowerWidth / (2 * peak.frequency)
    }

    // MARK: Running

    private func runSweep() async {
        isSweeping = true
        progress = 0
        points = []
        let model = ShearBuilding.from(building)
        // Read on the main actor and passed in, rather than captured: reaching
        // for main-actor state from inside a detached task is a data race, and
        // one the Swift 6 language mode rejects outright.
        let driveAmplitude = amplitude

        // Off the main thread: 60 full time-history solves is a second or two
        // of work and would drop every frame if it ran here.
        //
        // Streamed rather than awaited whole. `progress` used to be set to zero
        // here and one at the end, so the bar it drove sat at nought for the
        // entire sweep and then vanished — a progress indicator that never
        // indicated progress. And the curve only existed once every frequency
        // was done, which throws away the best thing about a resonance sweep:
        // watching the peak rise out of the noise as the drive approaches the
        // building's own frequency.
        let stream = AsyncStream<(ResonanceSweep.Point, Double)> { continuation in
            Task.detached(priority: .userInitiated) {
                _ = ResonanceSweep.sweep(model, amplitude: driveAmplitude) { point, fraction in
                    continuation.yield((point, fraction))
                }
                continuation.finish()
            }
        }

        for await (point, fraction) in stream {
            points.append(point)
            progress = fraction
        }

        isSweeping = false
        progress = 1
        Haptics.shared.play(.assessmentComplete)
    }
}
