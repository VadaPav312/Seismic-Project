import SwiftUI
import Charts
import SeismicCore
import SeismicSignal
import SeismicStructures

/// The physical shake table, and the loop that closes.
///
/// Everywhere else in this app the solver's answer is asserted. Here it is
/// checked: the table sweeps a real model building through a range of
/// frequencies, the node measures what actually happened, and the measurement
/// is drawn on top of the prediction. Where the two curves agree, the model has
/// earned some trust. Where they part company, the model is wrong and the
/// screen says so rather than quietly rescaling the axes until it looks right.
struct ShakeTableScreen: View {
    @EnvironmentObject private var env: AppEnvironment

    @State private var predicted: [ResonanceSweep.Point] = []
    @State private var measured: [Measurement] = []
    @State private var isSweeping = false
    @State private var currentSpeed: Double = 0
    @State private var sweepTask: Task<Void, Never>?

    struct Measurement: Identifiable, Equatable {
        var id: Double { frequency }
        var frequency: Double
        var amplitude: Double
        var driveAmplitude: Double
        var amplification: Double { driveAmplitude > 1e-9 ? amplitude / driveAmplitude : 0 }
    }

    private var building: BuildingModel? { env.selectedBuilding }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Metrics.spacingLoose) {
                explanation
                chart
                if !measured.isEmpty { agreement }
                controls
            }
            .padding(Theme.Metrics.screenPadding)
        }
        .onDisappear { stop() }
        .task { await computePrediction() }
    }

    // MARK: Pieces

    private var explanation: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Validation", systemImage: "checkmark.circle.trianglebadge.exclamationmark")
            Text("The table sweeps slowly from a low frequency to a high one while the node "
                 + "measures the model's response. The blue curve is what the solver predicted "
                 + "before the sweep started. Nothing is fitted afterwards.")
                .font(Theme.Typography.callout)
                .foregroundStyle(Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            ConnectionBadge(state: env.connectionState)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .instrumentPanel()
    }

    private var chart: some View {
        Chart {
            ForEach(predicted) { point in
                LineMark(x: .value("Frequency", point.frequency),
                         y: .value("Amplification", point.amplification),
                         series: .value("Series", "Predicted"))
                    .foregroundStyle(Theme.Palette.accent)
                    .interpolationMethod(.catmullRom)
            }
            ForEach(measured) { point in
                PointMark(x: .value("Frequency", point.frequency),
                          y: .value("Amplification", point.amplification))
                    .foregroundStyle(Theme.Palette.verdictAmber)
                    .symbolSize(50)
            }
        }
        .chartForegroundStyleScale([
            "Predicted": Theme.Palette.accent,
            "Measured": Theme.Palette.verdictAmber,
        ])
        .chartXAxisLabel("Driving frequency (Hz)")
        .chartYAxisLabel("Amplification")
        .frame(height: 260)
        .instrumentPanel()
        .overlay(alignment: .topTrailing) {
            if isSweeping {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(String(format: "%.2f Hz", frequency(forSpeed: currentSpeed)))
                        .font(Theme.Typography.numeric)
                        .foregroundStyle(Theme.Palette.verdictAmber)
                    Text("sweeping")
                        .font(Theme.Typography.label)
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
                .padding(10)
            }
        }
    }

    /// The comparison, stated as a number and as a sentence.
    ///
    /// Agreement within about 20% is genuinely good for a lumped-mass model of
    /// a physical object with real joints and real friction, so the threshold is
    /// set there rather than somewhere flattering.
    private var agreement: some View {
        let paired = measured.compactMap { measurement -> (Double, Double)? in
            guard let nearest = predicted.min(by: {
                abs($0.frequency - measurement.frequency)
                    < abs($1.frequency - measurement.frequency)
            }), nearest.amplification > 0.01 else { return nil }
            return (measurement.amplification, nearest.amplification)
        }

        let ratios = paired.map { $0.0 / $0.1 }.filter { $0.isFinite && $0 > 0 }
        let medianRatio = ratios.isEmpty ? 0 : Stats.median(ratios)
        let measuredPeak = measured.max { $0.amplification < $1.amplification }
        let predictedPeak = predicted.max { $0.amplification < $1.amplification }

        let frequencyError: Double = {
            guard let measuredPeak, let predictedPeak, predictedPeak.frequency > 0 else { return 0 }
            return (measuredPeak.frequency - predictedPeak.frequency) / predictedPeak.frequency
        }()

        return VStack(alignment: .leading, spacing: Theme.Metrics.spacing) {
            SectionLabel("How well the model did")

            ReadoutGrid(readouts: [
                Readout(label: "Measured peak",
                        value: measuredPeak.map { String(format: "%.2f", $0.frequency) } ?? "—",
                        unit: "Hz", tint: Theme.Palette.verdictAmber),
                Readout(label: "Predicted peak",
                        value: predictedPeak.map { String(format: "%.2f", $0.frequency) } ?? "—",
                        unit: "Hz", tint: Theme.Palette.accent),
                Readout(label: "Frequency error",
                        value: String(format: "%+.0f", frequencyError * 100), unit: "%",
                        tint: abs(frequencyError) < 0.2 ? Theme.Palette.verdictGreen
                                                        : Theme.Palette.verdictAmber),
                Readout(label: "Amplitude ratio",
                        value: String(format: "%.2f", medianRatio), unit: "×",
                        caption: "measured ÷ predicted"),
            ])

            Text(verdictText(frequencyError: frequencyError, amplitudeRatio: medianRatio))
                .font(Theme.Typography.callout)
                .foregroundStyle(Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .instrumentPanel()
    }

    private func verdictText(frequencyError: Double, amplitudeRatio: Double) -> String {
        if abs(frequencyError) < 0.2 && amplitudeRatio > 0.5 && amplitudeRatio < 2 {
            return "The measured peak lands within a fifth of the predicted one, and the "
                 + "amplitudes are the same order. For a lumped-mass model of a physical object "
                 + "with real joints and real friction, that is about as close as this kind of "
                 + "model gets — the solver is behaving."
        }
        if abs(frequencyError) >= 0.2 {
            return frequencyError > 0
                ? "The real model is stiffer than the solver assumed: it peaks at a higher "
                  + "frequency than predicted. Usually the storey stiffness is set too low, or "
                  + "the base is more rigid than the fixed-base assumption allows for."
                : "The real model is softer than the solver assumed: it peaks lower than "
                  + "predicted. Usually joints are more flexible than the model's rigid "
                  + "connections, or mass has been under-counted."
        }
        return "The peak frequency matches but the amplitudes do not, which points at damping "
             + "rather than stiffness. The measured response being smaller means the real thing "
             + "dissipates more energy than the assumed damping ratio allows."
    }

    private var controls: some View {
        VStack(spacing: Theme.Metrics.spacing) {
            Button {
                isSweeping ? stop() : start()
            } label: {
                Label(isSweeping ? "Stop the sweep" : "Run a validation sweep",
                      systemImage: isSweeping ? "stop.fill" : "play.fill")
                    .frame(maxWidth: .infinity)
                    .frame(height: Theme.Metrics.minimumTapTarget)
            }
            .buttonStyle(PrimaryButtonStyle(destructive: isSweeping))

            if !measured.isEmpty {
                Button("Clear the measurements") {
                    measured = []
                }
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
            }

            if env.isUsingSimulatedData {
                InlineNotice(
                    level: .info,
                    title: "This is the simulated node",
                    message: "The sweep runs against the node's own physics rather than a real "
                        + "table, so the two curves will agree closely. Connected to real "
                        + "hardware they disagree, and the disagreement is the interesting part.")
            }
        }
    }

    // MARK: Behaviour

    /// The node's table maps its 0…1 speed onto roughly 0.5–6.5 Hz.
    private func frequency(forSpeed speed: Double) -> Double { 0.5 + speed * 6 }

    private func computePrediction() async {
        guard let building else { return }
        let model = ShearBuilding.from(building)
        predicted = await Task.detached(priority: .userInitiated) {
            ResonanceSweep.sweep(model, amplitude: 0.3)
        }.value
    }

    private func start() {
        guard !isSweeping else { return }
        isSweeping = true
        measured = []
        Haptics.shared.play(.eventTriggered)

        sweepTask = Task { @MainActor in
            // Eighteen steps, two seconds each: long enough at each frequency
            // for the model to reach steady state, which is the whole reason a
            // sweep is done slowly rather than as a chirp.
            for step in 0...18 {
                if Task.isCancelled { break }
                let speed = Double(step) / 18
                currentSpeed = speed
                env.session.send(.setShakeTableSpeed(speed))

                try? await Task.sleep(nanoseconds: 1_400_000_000)
                if Task.isCancelled { break }

                // Measure the response over the second half of the dwell, once
                // the transient from changing frequency has died away.
                let record = env.session.bufferedRecord()
                let window = Array(record.z.samples.suffix(Int(record.z.sampleRate * 0.8)))
                guard !window.isEmpty else { continue }

                let response = Stats.rms(window)
                let drive = max(speed, 0.05) * 1.2 * 0.7071   // rms of the drive sine
                measured.append(Measurement(frequency: frequency(forSpeed: speed),
                                            amplitude: response,
                                            driveAmplitude: drive))
            }
            stop()
        }
    }

    private func stop() {
        sweepTask?.cancel()
        sweepTask = nil
        env.session.send(.setShakeTableSpeed(0))
        currentSpeed = 0
        if isSweeping {
            isSweeping = false
            Haptics.shared.play(.assessmentComplete)
        }
    }
}

#Preview {
    NavigationStack {
        ShakeTableScreen()
            .seismicBackground()
            .navigationTitle("Shake table")
    }
    .previewEnvironment()
}
