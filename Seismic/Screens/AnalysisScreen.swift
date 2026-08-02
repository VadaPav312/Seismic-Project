import SwiftUI
import Charts
import SeismicCore
import SeismicSignal
import SeismicStructures

/// The working, shown.
///
/// Everywhere else the app states a conclusion — a period, a damping ratio, a
/// verdict. This screen is where those numbers come from: the spectrum they
/// were picked off, the peaks that were identified, the two independent
/// estimates that agree or disagree with the spectral one, and the decay curve
/// the damping was fitted to. An engineer asked to trust a verdict is entitled
/// to see the spectrum behind it, and everybody else is entitled to discover
/// that it exists.
struct AnalysisScreen: View {
    @EnvironmentObject private var env: AppEnvironment

    @State private var recordSource: RecordSource = .ambient
    @State private var window: Window = .hann
    @State private var smoothingBandwidth: Double = 40
    @State private var estimator: Estimator = .welch
    @State private var smoother: Smoother = .konnoOhmachi
    @State private var analysis: Analysis?
    @State private var isWorking = false
    @State private var anomalyModel: AnomalyDetection.Model?
    @State private var anomalyVerdict: AnomalyDetection.Verdict?

    enum RecordSource: String, CaseIterable, Identifiable {
        case ambient, lastEvent
        var id: String { rawValue }

        var label: String {
            switch self {
            case .ambient: "Ambient"
            case .lastEvent: "Last event"
            }
        }

        var explanation: String {
            switch self {
            case .ambient:
                "The building's response to wind and traffic. Tiny, continuous, and enough "
                + "to measure a period from — which is why the baseline does not need an "
                + "earthquake to establish it."
            case .lastEvent:
                "The recorded event. Far more energy, so the peaks are sharper, but the "
                + "building was changing during it."
            }
        }
    }

    /// A chart point. Named rather than a tuple, because a zipped tuple inside
    /// a chart builder is what makes the type checker give up.
    struct Point: Identifiable {
        let id: Int
        let x: Double
        let y: Double
    }

    /// How the spectrum is estimated.
    enum Estimator: String, CaseIterable, Identifiable {
        case welch, multitaper
        var id: String { rawValue }

        var label: String {
            switch self {
            case .welch: "Welch"
            case .multitaper: "Multitaper"
            }
        }

        var explanation: String {
            switch self {
            case .welch:
                "Cuts the record into overlapping segments and averages them. Smoother, at "
                + "the cost of resolving frequencies that are close together — eight "
                + "segments means eight times the smoothing and eight times the blur."
            case .multitaper:
                "Several orthogonal tapers over the *whole* record instead. Each taper is a "
                + "nearly independent estimate, so averaging them smooths without ever "
                + "shortening the record — which is what keeps a two per cent period shift "
                + "resolvable."
            }
        }
    }

    /// How the spectrum is smoothed afterwards.
    enum Smoother: String, CaseIterable, Identifiable {
        case none, konnoOhmachi, savitzkyGolay
        var id: String { rawValue }

        var label: String {
            switch self {
            case .none: "None"
            case .konnoOhmachi: "Konno-Ohmachi"
            case .savitzkyGolay: "Savitzky-Golay"
            }
        }

        var explanation: String {
            switch self {
            case .none:
                "The raw estimate. Noisier, and the only one that has definitely not had a "
                + "peak reshaped by the smoothing."
            case .konnoOhmachi:
                "Constant width on a log axis, so a peak at 8 Hz is smoothed as much as one "
                + "at 1 Hz — which linear smoothing gets wrong."
            case .savitzkyGolay:
                "Fits a cubic to a sliding window instead of averaging it. A cubic can "
                + "follow a peak, so the peak keeps its height and width — which matters "
                + "because width is what damping is read from."
            }
        }
    }

    /// Everything computed in one pass, off the main thread.
    struct Analysis {
        var spectrum: PowerSpectrum
        var smoothed: PowerSpectrum
        var peaks: [SpectralPeak]
        var crossChecked: PeriodEstimation.CrossCheckedPeriod
        var damping: DampingEstimate
        var envelope: Waveform
        var randomDecrement: RandomDecrement.AmbientMeasurement?
        var responseSpectrum: ResponseSpectrum
        var spectrogram: Spectrogram
        var rectilinearity: Waveform?
        var energy: EnergyMeasures
        var trigger: TriggerResult
        var falseTrigger: FalseTriggerRejection.Verdict

        // Operational modal analysis — several modes at once, from ambient
        // motion, with an honest account of which of them are real.
        var decomposition: FrequencyDomainDecomposition.Result?
        var poles: [PronyAnalysis.Pole]
        var stablePoles: [StabilisationDiagram.StablePole]

        /// The F statistic per bin, for telling a mains harmonic from a mode.
        var lineTest: [Double]
        /// Intrinsic mode functions, fastest first, with their frequencies.
        var intrinsicModes: [(frequency: Double, energy: Double)]
        /// The building's period through the record, from the wavelet ridge.
        var ridge: WaveletRidge.Result?
        /// Displacement recovered with the sensor pinned still at both ends.
        var displacement: ConstrainedDisplacement.Result?
        /// Aftershocks found by correlating the record against its own onset.
        var aftershocks: [MatchedFilter.Detection]
        /// The kurtosis onset pick, and how it compares with the AIC pick.
        var kurtosisPick: KurtosisPicker.Pick?
        var pickComparison: (differenceSeconds: Double, interpretation: String)?
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Metrics.spacingSection) {
                sourcePicker

                if isWorking {
                    MeaningfulProgress(title: "Computing",
                                       detail: "Welch spectrum, peak picking, damping fit, "
                                             + "response spectrum and spectrogram.")
                } else if let analysis {
                    spectrumSection(analysis)
                    modesSection(analysis)
                    operationalModalSection(analysis)
                    crossCheckSection(analysis)
                    dampingSection(analysis)
                    ambientSection(analysis)
                    ridgeSection(analysis)
                    intrinsicModesSection(analysis)
                    displacementSection(analysis)
                    historySection
                    anomalySection
                    responseSpectrumSection(analysis)
                    spectrogramSection(analysis)
                    detectionSection(analysis)
                    aftershockSection(analysis)
                } else {
                    DesignedEmptyState(
                        icon: "waveform.and.magnifyingglass",
                        title: "Nothing to analyse yet",
                        message: "Analysis needs a recording. The node is always buffering "
                               + "ambient motion, so this normally fills in within a few "
                               + "seconds of connecting.",
                        actionTitle: "Try again",
                        action: { Task { await compute() } })
                }
            }
            .padding(Theme.Metrics.screenPadding)
            .contentColumn()
        }
        .task(id: recordSource) { await compute() }
        .task(id: env.observations.count) { trainAnomalyModel() }
        .onChange(of: window) { _, _ in Task { await compute() } }
        .onChange(of: estimator) { _, _ in Task { await compute() } }
        .onChange(of: smoother) { _, _ in Task { await compute() } }
    }

    // MARK: Source

    private var sourcePicker: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.spacing) {
            Picker("Source", selection: $recordSource) {
                ForEach(RecordSource.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)

            Text(recordSource.explanation)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Spectrum

    private func spectrumSection(_ analysis: Analysis) -> some View {
        let shown = analysis.smoothed

        return VStack(alignment: .leading, spacing: Theme.Metrics.spacing) {
            SectionLabel("Spectrum", systemImage: "waveform.path",
                         trailing: "\(estimator.label), \(window.label)")

            let points = Self.points(x: shown.frequencies, y: shown.power,
                                     keepingX: { $0 > 0.05 && $0 < 15 },
                                     flooringY: 1e-14)

            Chart {
                ForEach(points) { point in
                    LineMark(x: .value("Frequency", point.x),
                             y: .value("Power", point.y))
                        .foregroundStyle(Theme.Palette.accent)
                }
                ForEach(analysis.peaks.prefix(3), id: \.frequency) { peak in
                    RuleMark(x: .value("Peak", peak.frequency))
                        .foregroundStyle(Theme.Palette.verdictAmber.opacity(0.6))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }
            .chartYScale(type: .log)
            .chartXAxisLabel("Frequency (Hz)")
            .chartYAxisLabel("Power")
            .frame(height: 200)

            // Every stage of the estimate is a control rather than a default,
            // because each one reshapes the peak that a period is read off and
            // a user is entitled to see what each did.
            VStack(alignment: .leading, spacing: 6) {
                Text("ESTIMATOR")
                    .font(Theme.Typography.label)
                    .tracking(1.1)
                    .foregroundStyle(Theme.Palette.textTertiary)
                Picker("Estimator", selection: $estimator) {
                    ForEach(Estimator.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Text(estimator.explanation)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("SMOOTHING")
                    .font(Theme.Typography.label)
                    .tracking(1.1)
                    .foregroundStyle(Theme.Palette.textTertiary)
                Picker("Smoothing", selection: $smoother) {
                    ForEach(Smoother.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Text(smoother.explanation)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if estimator == .welch {
                Picker("Window", selection: $window) {
                    ForEach(Window.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)

                Text("A window is applied before the transform because a finite record has "
                     + "hard ends, and hard ends smear energy across every frequency.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            lineTestNotice(analysis)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .instrumentPanel()
    }

    /// Warns when a peak is a machine rather than a building.
    ///
    /// Only shown when it has something to say. A permanent panel reading "no
    /// lines detected" is a panel people stop reading, and this is precisely
    /// the warning that must be noticed the once it appears.
    @ViewBuilder
    private func lineTestNotice(_ analysis: Analysis) -> some View {
        let lines = deterministicLines(analysis)
        if !lines.isEmpty {
            InlineNotice(
                level: .warning,
                title: lines.count == 1 ? "One peak is a machine, not the building"
                                        : "\(lines.count) peaks are machines, not the building",
                message: "Thomson's F-test says the "
                    + lines.map { String(format: "%.2f Hz", $0) }.joined(separator: ", ")
                    + " peak\(lines.count == 1 ? " is" : "s are") a pure sinusoid. A building's "
                    + "resonance has width to it, because damping gives it width; a lift "
                    + "motor, a transformer or a mains harmonic has none. Tracking one as a "
                    + "mode would give a period that never changes — and never changing is "
                    + "exactly what a healthy building is supposed to look like.")
        }
    }

    /// Frequencies where the F-test fires and a peak was picked.
    ///
    /// Both conditions, deliberately: the F-test fires at plenty of bins that
    /// nothing is being read off, and warning about those would be noise about
    /// noise.
    private func deterministicLines(_ analysis: Analysis) -> [Double] {
        guard !analysis.lineTest.isEmpty else { return [] }
        return analysis.peaks.prefix(6).compactMap { peak -> Double? in
            let bin = Int((peak.frequency / max(analysis.spectrum.sampleRate, 1))
                          * Double(analysis.lineTest.count) * 2)
            guard bin > 0, bin < analysis.lineTest.count else { return nil }
            // A little either side, because a line rarely sits on a bin centre.
            let window = max(bin - 1, 0)...min(bin + 1, analysis.lineTest.count - 1)
            let peakF = window.map { analysis.lineTest[$0] }.max() ?? 0
            return peakF > 12 ? peak.frequency : nil
        }
    }

    // MARK: Modes

    private func modesSection(_ analysis: Analysis) -> some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.spacing) {
            SectionLabel("Identified modes", systemImage: "chart.dots.scatter",
                         trailing: "\(analysis.peaks.count) peaks")

            if analysis.peaks.isEmpty {
                Text("No peak stood far enough above its surroundings to be called a mode. "
                     + "That is a real answer: a record dominated by noise should not produce "
                     + "confident modes.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(Array(analysis.peaks.prefix(4).enumerated()), id: \.offset) { index, peak in
                HStack(alignment: .firstTextBaseline) {
                    Text("Mode \(index + 1)")
                        .font(Theme.Typography.callout.weight(.medium))
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .frame(width: 70, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(format: "%.3f Hz  ·  %.3f s",
                                    peak.frequency, 1 / max(peak.frequency, 1e-6)))
                            .font(Theme.Typography.numeric)
                            .foregroundStyle(Theme.Palette.accent)
                        Text(String(format: "prominence %.2f", peak.prominence))
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.textTertiary)
                    }
                    Spacer()
                }
            }

            Text("Peaks are picked by prominence rather than height, so a small bump on the "
                 + "shoulder of a large one is not mistaken for a mode. The frequency is then "
                 + "refined by fitting a parabola through the three bins around the peak, "
                 + "which recovers roughly a tenth of a bin.")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .instrumentPanel()
    }

    // MARK: Operational modal analysis

    /// Every mode at once, and which of them can be believed.
    ///
    /// The peak-picking section above answers "where are the bumps". This
    /// answers the two questions that follow and that a spectrum cannot: is
    /// each bump one mode or two, and is it a property of the building or of
    /// the fit that found it.
    private func operationalModalSection(_ analysis: Analysis) -> some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.spacing) {
            SectionLabel("Operational modal analysis", systemImage: "tuningfork",
                         trailing: analysis.stablePoles.isEmpty
                            ? nil : "\(analysis.stablePoles.count) stable")

            if let decomposition = analysis.decomposition,
               let first = analysis.peaks.first,
               decomposition.hasClosePair(near: first.frequency) {
                InlineNotice(
                    level: .warning,
                    title: "Two modes are sitting on top of each other",
                    message: String(format: "Near %.2f Hz ", first.frequency)
                        + "the second singular value is close to the first, which means two "
                        + "modes are overlapping rather than one. A single-channel spectrum "
                        + "cannot see that: it reports a period between the two, belonging to "
                        + "neither, and reports it moving as they trade dominance. Read the "
                        + "period history through this band with suspicion.")
            }

            if analysis.stablePoles.isEmpty {
                Text("Not enough free decay to fit poles to yet. This needs a random "
                     + "decrement signature, which builds up over a minute or two of ambient "
                     + "recording.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(analysis.stablePoles.prefix(4)) { pole in
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Metrics.spacing) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(String(format: "%.3f Hz · %.3f s",
                                        pole.frequency, 1 / max(pole.frequency, 1e-6)))
                                .font(Theme.Typography.numeric)
                                .foregroundStyle(Theme.Palette.accent)
                            Text(String(format: "damping %.2f%%  ·  survived %d model orders",
                                        pole.damping * 100, pole.appearances))
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Palette.textTertiary)
                        }
                        Spacer(minLength: 0)
                        // The stability bar is the whole point of the section:
                        // it is the difference between a mode and an artefact.
                        ConfidenceBar(confidence: pole.stability)
                            .frame(width: 74)
                    }
                }

                Text("Each pole carries its own frequency *and* its own damping, from one "
                     + "fit — so a change in the third mode is not hidden behind the first. "
                     + "The bar is how many model orders the pole survived: a real mode is a "
                     + "property of the building and keeps coming back, while a numerical one "
                     + "moves every time the fit changes.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if analysis.poles.count > analysis.stablePoles.count {
                    Text("\(analysis.poles.count - analysis.stablePoles.count) further poles "
                         + "were fitted and discarded for not surviving a change of model "
                         + "order.")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .instrumentPanel()
    }

    // MARK: Intrinsic modes

    /// What the record is made of, without assuming a basis first.
    private func intrinsicModesSection(_ analysis: Analysis) -> some View {
        let total = max(analysis.intrinsicModes.reduce(0) { $0 + $1.energy }, 1e-18)

        return VStack(alignment: .leading, spacing: Theme.Metrics.spacing) {
            SectionLabel("Intrinsic modes", systemImage: "square.stack.3d.down.right",
                         trailing: "\(analysis.intrinsicModes.count)")

            if analysis.intrinsicModes.isEmpty {
                Text("The record has too few turning points to decompose — which is what a "
                     + "pure trend looks like, and there is nothing oscillating in it to "
                     + "separate.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(Array(analysis.intrinsicModes.enumerated()), id: \.offset) { index, mode in
                HStack(alignment: .firstTextBaseline) {
                    Text("IMF \(index + 1)")
                        .font(Theme.Typography.callout.weight(.medium))
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .frame(width: 62, alignment: .leading)
                    Text(String(format: "%.2f Hz", mode.frequency))
                        .font(Theme.Typography.numeric)
                        .foregroundStyle(Theme.Palette.accent)
                    Spacer()
                    Text(String(format: "%.0f%% of energy", mode.energy / total * 100))
                        .font(Theme.Typography.numericSmall)
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
            }

            Text("Sifted out of the data's own turning points rather than fitted to "
                 + "sinusoids. Everything else here assumes a basis before it looks — Fourier "
                 + "assumes sine waves, wavelets assume scaled copies of one shape — and both "
                 + "distort a signal whose frequency is moving. This assumes nothing, which "
                 + "is what separates the building's sway from the traffic under it without "
                 + "anybody saying in advance what frequency either is at.")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .instrumentPanel()
    }

    // MARK: The period during the shaking

    /// The measurement the whole product is about, taken *during* the event.
    @ViewBuilder
    private func ridgeSection(_ analysis: Analysis) -> some View {
        if let ridge = analysis.ridge, ridge.times.count > 8 {
            let threshold = (ridge.amplitudes.max() ?? 0) * 0.25
            let points = ridge.times.indices.compactMap { i -> Point? in
                guard ridge.amplitudes[i] >= threshold, ridge.frequencies[i] > 0 else {
                    return nil
                }
                return Point(id: i, x: ridge.times[i], y: 1 / ridge.frequencies[i])
            }

            VStack(alignment: .leading, spacing: Theme.Metrics.spacing) {
                SectionLabel("Period during the shaking", systemImage: "waveform.path.ecg",
                             trailing: ridge.periodChange.map {
                                String(format: "%+.1f%%", $0 * 100)
                             })

                if points.count > 4 {
                    Chart(points) { point in
                        LineMark(x: .value("Time", point.x), y: .value("Period", point.y))
                            .foregroundStyle(Theme.Palette.accent)
                            .interpolationMethod(.monotone)
                    }
                    .chartXAxisLabel("Seconds")
                    .chartYAxisLabel("Period (s)")
                    .frame(height: 160)
                }

                if let change = ridge.periodChange, change > 0.05 {
                    InlineNotice(
                        level: .warning,
                        title: "The period lengthened while it was being shaken",
                        message: String(format: "The building's period rose %.0f%% ",
                                        change * 100)
                            + "between the start of this record and the end of it. A "
                            + "before-and-after comparison would show the same total change "
                            + "but not *when* it happened — and the moment the line steps "
                            + "down is the moment the damage occurred.")
                } else {
                    Text("A wavelet uses a window that scales with the frequency it is "
                         + "examining, so it keeps a fixed number of cycles at every scale. "
                         + "That is what lets it time a change in period, which a spectrogram "
                         + "with one fixed window cannot: short enough to time the change and "
                         + "it cannot resolve the frequency, long enough to resolve the "
                         + "frequency and the change has been smeared away.")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .instrumentPanel()
        }
    }

    // MARK: Displacement

    @ViewBuilder
    private func displacementSection(_ analysis: Analysis) -> some View {
        if let displacement = analysis.displacement, !displacement.displacement.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Metrics.spacing) {
                SectionLabel("Displacement", systemImage: "arrow.left.and.right",
                             trailing: "Kalman, zero-velocity pinned")

                ReadoutGrid(readouts: [
                    Readout(label: "Came to rest",
                            value: String(format: "%.1f", displacement.residual * 1000),
                            unit: "mm",
                            tint: abs(displacement.residual) > 0.005
                                ? Theme.Palette.verdictAmber : Theme.Palette.accent,
                            size: .large),
                    Readout(label: "Sensor bias found",
                            value: String(format: "%.4f", displacement.estimatedBias),
                            unit: "m/s²", size: .small),
                ], columns: 2)

                Text("Integrating acceleration twice turns any constant bias into a parabola, "
                     + "so a plain integration reports metres of drift that never happened. "
                     + "The usual fix is a high-pass filter, which works and costs the very "
                     + "lowest frequencies — where a permanent offset lives. Instead the "
                     + "filter is told the sensor was genuinely still before the event and "
                     + "after it, and estimates the bias from that. The offset survives the "
                     + "processing, and residual displacement is one of the three things the "
                     + "verdict rests on.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .instrumentPanel()
        }
    }

    // MARK: Aftershocks

    @ViewBuilder
    private func aftershockSection(_ analysis: Analysis) -> some View {
        if !analysis.aftershocks.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Metrics.spacing) {
                SectionLabel("Aftershocks in this record", systemImage: "dot.radiowaves.up.forward",
                             trailing: "\(analysis.aftershocks.count)")

                ForEach(analysis.aftershocks.prefix(6)) { detection in
                    HStack(alignment: .firstTextBaseline) {
                        Text(String(format: "%.1f s", detection.time))
                            .font(Theme.Typography.numeric)
                            .foregroundStyle(Theme.Palette.textPrimary)
                            .frame(width: 72, alignment: .leading)
                        Text(String(format: "%.0f%% of the mainshock",
                                    detection.relativeAmplitude * 100))
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.textSecondary)
                        Spacer()
                        Text(String(format: "r = %.2f", detection.correlation))
                            .font(Theme.Typography.numericSmall)
                            .foregroundStyle(Theme.Palette.textTertiary)
                    }
                }

                Text("Found by correlating the record against its own strongest stretch, "
                     + "rather than by looking for energy. An aftershock on the same fault "
                     + "patch arrives at this sensor with very nearly the same shape as the "
                     + "mainshock, just smaller — so matching on shape finds ones far too "
                     + "small to trip the trigger. The threshold is set against the "
                     + "correlation trace's own scatter, because a buried event produces a "
                     + "small correlation that is nonetheless wildly improbable for noise.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .instrumentPanel()
        }
    }

    // MARK: Cross-check

    /// Three independent estimates of the same number.
    ///
    /// They are shown together because agreement between methods that fail in
    /// different ways is the only cheap evidence available that a period is
    /// real rather than an artefact of one of them.
    private func crossCheckSection(_ analysis: Analysis) -> some View {
        let check = analysis.crossChecked

        return VStack(alignment: .leading, spacing: Theme.Metrics.spacing) {
            SectionLabel("Cross-check", systemImage: "checkmark.circle.badge.questionmark",
                         trailing: "\(check.methodsAgreeing) of 3 agree")

            ReadoutGrid(readouts: [
                Readout(label: "Spectral",
                        value: check.spectral.map { String(format: "%.3f", $0) } ?? "—",
                        unit: "s", tint: Theme.Palette.accent),
                Readout(label: "Autocorrelation",
                        value: check.autocorrelation
                            .map { String(format: "%.3f", $0) } ?? "—", unit: "s"),
                Readout(label: "Zero crossing",
                        value: check.zeroCrossing
                            .map { String(format: "%.3f", $0) } ?? "—", unit: "s"),
                Readout(label: "Adopted",
                        value: check.consensus.map { String(format: "%.3f", $0) } ?? "—",
                        unit: "s",
                        tint: check.methodsAgreeing >= 2 ? Theme.Palette.verdictGreen
                                                         : Theme.Palette.verdictAmber,
                        size: .large,
                        caption: String(format: "agreement %.0f%%", check.agreement * 100)),
            ])

            Text(check.explanation)
                .font(Theme.Typography.callout)
                .foregroundStyle(Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .instrumentPanel()
    }

    // MARK: Damping

    private func dampingSection(_ analysis: Analysis) -> some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.spacing) {
            SectionLabel("Damping", systemImage: "chart.line.downtrend.xyaxis",
                         trailing: analysis.damping.method.label)

            Readout(label: "Damping ratio",
                    value: String(format: "%.2f", analysis.damping.ratio * 100), unit: "%",
                    tint: Theme.Palette.accent, size: .large,
                    caption: String(format: "confidence %.0f%% · %@",
                                    analysis.damping.confidence * 100,
                                    analysis.damping.detail))

            // The envelope is the thing the log-decrement fit is actually
            // fitted to, so it is drawn rather than described.
            let envelopePoints = Self.points(
                x: (0..<min(analysis.envelope.samples.count, 1200))
                    .map { Double($0) / analysis.envelope.sampleRate },
                y: Array(analysis.envelope.samples.prefix(1200)))

            Chart {
                ForEach(envelopePoints) { point in
                    LineMark(x: .value("Time", point.x),
                             y: .value("Envelope", point.y))
                        .foregroundStyle(Theme.Palette.verdictAmber)
                }
            }
            .chartXAxisLabel("Seconds")
            .frame(height: 130)

            Text("The envelope comes from the Hilbert transform — the analytic signal's "
                 + "magnitude — rather than from joining the peaks, which is why it is smooth "
                 + "between cycles. A straight line through its logarithm is the damping.")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if analysis.damping.confidence < 0.5 {
                InlineNotice(level: .warning,
                             title: "This fit is poor",
                             message: "Low confidence means the decay is not a clean "
                                    + "exponential, so this damping figure is not usable. It is "
                                    + "shown rather than hidden because a hidden bad fit is how "
                                    + "a wrong number ends up in a report.")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .instrumentPanel()
    }

    // MARK: Ambient

    private func ambientSection(_ analysis: Analysis) -> some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.spacing) {
            SectionLabel("Ambient measurement", systemImage: "wind")

            if let measurement = analysis.randomDecrement {
                ReadoutGrid(readouts: [
                    Readout(label: "Period",
                            value: String(format: "%.3f", measurement.period), unit: "s",
                            tint: Theme.Palette.accent),
                    Readout(label: "Damping",
                            value: measurement.damping
                                .map { String(format: "%.2f", $0.ratio * 100) } ?? "—",
                            unit: "%"),
                    Readout(label: "Segments averaged",
                            value: "\(measurement.segmentsAveraged)", unit: "",
                            caption: "more segments, less noise"),
                    Readout(label: "Confidence",
                            value: String(format: "%.0f", measurement.confidence * 100),
                            unit: "%",
                            tint: measurement.confidence > 0.5 ? Theme.Palette.verdictGreen
                                                               : Theme.Palette.verdictAmber),
                ])
            } else {
                Text("Not enough clean ambient motion in this record to average.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }

            Text("The random decrement technique averages hundreds of short segments that all "
                 + "start at the same amplitude. The random part of the motion averages away "
                 + "and what remains is the building's own free decay — a free-vibration test "
                 + "without anybody having to push the building.")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .instrumentPanel()
    }

    // MARK: History

    private var historySection: some View {
        let history = ModeTracking.history(of: 1, in: env.observations)

        return VStack(alignment: .leading, spacing: Theme.Metrics.spacing) {
            SectionLabel("Period history", systemImage: "chart.xyaxis.line",
                         trailing: "\(history.count) measurements")

            if history.count > 20 {
                TrendChart(points: history.map { .init(date: $0.at, value: $0.period) },
                           color: Theme.Palette.accent,
                           height: 160,
                           valueFormatter: { String(format: "%.3f s", $0) })

                let cusum = CUSUM.onPeriodHistory(history.map(\.period))
                HStack(spacing: 8) {
                    Image(systemName: cusum.changeDetected
                          ? "exclamationmark.triangle.fill" : "checkmark.circle")
                        .foregroundStyle(cusum.changeDetected ? Theme.Palette.verdictAmber
                                                              : Theme.Palette.verdictGreen)
                    Text(cusum.explanation)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text("Each measurement is matched to a mode by frequency, with hysteresis, so "
                     + "two modes that drift towards each other do not swap identities and "
                     + "produce a step change that never happened.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("A history builds up over weeks. There is not enough yet to draw one.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .instrumentPanel()
    }

    /// Is this measurement unusual *for this building*?
    ///
    /// A period of 0.94 s means nothing in the abstract. Against a year of this
    /// building's own measurements it means everything, and the Mahalanobis
    /// distance is the version of that question that accounts for the fact that
    /// period and temperature vary together rather than independently.
    @ViewBuilder
    private var anomalySection: some View {
        // Read from the cache rather than trained here: this is a covariance
        // fit over a year of measurements, and `body` runs far more often than
        // the measurements change.
        VStack(alignment: .leading, spacing: Theme.Metrics.spacing) {
            SectionLabel("Is this normal for this building?",
                         systemImage: "chart.dots.scatter",
                         trailing: (anomalyModel?.isTrained ?? false)
                            ? "\(anomalyModel?.sampleCount ?? 0) samples" : "Untrained")

            if let model = anomalyModel, let verdict = anomalyVerdict {
                HStack(spacing: 10) {
                    Image(systemName: verdict.isAnomalous
                          ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(verdict.isAnomalous ? Theme.Palette.verdictAmber
                                                             : Theme.Palette.verdictGreen)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(format: "Mahalanobis distance %.2f", verdict.distance))
                            .font(Theme.Typography.numeric)
                            .foregroundStyle(Theme.Palette.textPrimary)
                        Text(String(format: "threshold %.2f", model.threshold))
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.textTertiary)
                    }
                }

                Text(verdict.explanation)
                    .font(Theme.Typography.callout)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                // Which feature made it unusual matters more than the distance:
                // "the period is odd" and "it is unusually cold" are different
                // stories, and only one of them is about the building.
                ForEach(Array(verdict.featureContributions.prefix(3).enumerated()),
                        id: \.offset) { _, contribution in
                    HStack {
                        Text(contribution.name)
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.textSecondary)
                        Spacer()
                        Text(String(format: "%.0f%%", contribution.contribution * 100))
                            .font(Theme.Typography.numericSmall)
                            .foregroundStyle(Theme.Palette.textTertiary)
                    }
                }
            } else {
                Text("A year of measurements is needed before \"normal\" means anything for "
                     + "this building. Until then there is nothing to compare against.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .instrumentPanel()
    }

    // MARK: Response spectrum

    private func responseSpectrumSection(_ analysis: Analysis) -> some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.spacing) {
            SectionLabel("Response spectrum", systemImage: "chart.bar.xaxis")

            let points = Self.points(x: analysis.responseSpectrum.periods,
                                     y: analysis.responseSpectrum.sa)

            Chart {
                ForEach(points) { point in
                    LineMark(x: .value("Period", point.x),
                             y: .value("Sa", point.y))
                        .foregroundStyle(Theme.Palette.accent)
                        .interpolationMethod(.catmullRom)
                }
                if let building = env.selectedBuilding {
                    RuleMark(x: .value("This building", building.empiricalPeriod))
                        .foregroundStyle(Theme.Palette.verdictAmber)
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        .annotation(position: .top, alignment: .leading) {
                            Text("this building")
                                .font(.system(size: 9))
                                .foregroundStyle(Theme.Palette.verdictAmber)
                        }
                }
            }
            .chartXAxisLabel("Period (s)")
            .chartYAxisLabel("Spectral acceleration (m/s²)")
            .frame(height: 190)

            Text("What a single-storey building of each period would have felt, standing on "
                 + "this ground. The dashed line is where your building sits — the height of "
                 + "the curve there is the number that matters, and it is often nothing like "
                 + "the peak ground acceleration.")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            ReadoutGrid(readouts: [
                Readout(label: "Arias intensity",
                        value: String(format: "%.3f", analysis.energy.arias),
                        unit: "m/s"),
                Readout(label: "Significant duration",
                        value: String(format: "%.1f", analysis.energy.significantDuration),
                        unit: "s", caption: "5% to 95% of the energy"),
            ])
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .instrumentPanel()
    }

    // MARK: Spectrogram

    private func spectrogramSection(_ analysis: Analysis) -> some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.spacing) {
            SectionLabel("Spectrogram", systemImage: "square.grid.3x3.fill")

            SpectrogramView(spectrogram: analysis.spectrogram)
                .frame(height: 170)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadiusSmall))

            Text("Frequency against time. A building that softens during an earthquake shows "
                 + "it here as a bright band sliding downwards — which is the same thing the "
                 + "assessment measures, seen directly rather than as a before-and-after pair.")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .instrumentPanel()
    }

    // MARK: Detection

    private func detectionSection(_ analysis: Analysis) -> some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.spacing) {
            SectionLabel("Detection", systemImage: "bolt.horizontal")

            ReadoutGrid(readouts: [
                Readout(label: "Peak STA/LTA",
                        value: String(format: "%.2f", analysis.trigger.peakRatio), unit: "×",
                        tint: analysis.trigger.didTrigger ? Theme.Palette.verdictAmber
                                                          : Theme.Palette.textPrimary),
                Readout(label: "Triggered",
                        value: analysis.trigger.didTrigger ? "Yes" : "No", unit: ""),
            ])

            HStack(spacing: 8) {
                Image(systemName: analysis.falseTrigger.isEarthquake
                      ? "waveform.badge.exclamationmark" : "xmark.circle")
                    .foregroundStyle(analysis.falseTrigger.isEarthquake
                                     ? Theme.Palette.verdictAmber : Theme.Palette.textSecondary)
                Text(analysis.falseTrigger.reason)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let rectilinearity = analysis.rectilinearity, !rectilinearity.samples.isEmpty {
                Text(String(format: "Peak rectilinearity %.2f — how strongly the motion was "
                            + "polarised along one direction. A P wave is nearly linear; a "
                            + "door slamming nearby is not.",
                            rectilinearity.samples.max() ?? 0))
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Two pickers, and what their disagreement means. The second is
            // here because the first has a known blind spot on emergent onsets
            // — and an emergent onset is a distant earthquake, which is the
            // case where the extra seconds of warning matter most.
            if let pick = analysis.kurtosisPick {
                Divider().overlay(Theme.Palette.hairline)

                ReadoutGrid(readouts: [
                    Readout(label: "Kurtosis pick",
                            value: String(format: "%.2f", pick.time), unit: "s", size: .small),
                    Readout(label: "Sharpness",
                            value: String(format: "%.1f", pick.sharpness), unit: "×",
                            size: .small),
                ], columns: 2)

                if let comparison = analysis.pickComparison {
                    Text(comparison.interpretation)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(abs(comparison.differenceSeconds) > 0.15
                                         ? Theme.Palette.textSecondary
                                         : Theme.Palette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text("Kurtosis measures how heavy the tails of the distribution are rather "
                     + "than how much energy has arrived. Ambient noise is nearly Gaussian; "
                     + "the first few large samples of a transient are emphatically not, and "
                     + "the statistic jumps the moment they appear — before the energy has "
                     + "built enough for a variance-based picker to notice.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .instrumentPanel()
    }

    /// Pairs two parallel arrays into plottable points, optionally trimming the
    /// x range and flooring y so a log axis has nothing non-positive on it.
    static func points(x: [Double], y: [Double],
                       keepingX: (Double) -> Bool = { _ in true },
                       flooringY: Double? = nil) -> [Point] {
        var out: [Point] = []
        out.reserveCapacity(min(x.count, y.count))
        for index in 0..<min(x.count, y.count) where keepingX(x[index]) {
            let value = flooringY.map { Swift.max(y[index], $0) } ?? y[index]
            out.append(Point(id: index, x: x[index], y: value))
        }
        return out
    }

    /// Fits "what normal looks like for this building" once per change in the
    /// measurement history.
    private func trainAnomalyModel() {
        let history = ModeTracking.history(of: 1, in: env.observations)
        let features = history.map { [$0.period, $0.temperature ?? 15] }
        let model = AnomalyDetection.train(observations: features,
                                           featureNames: ["Period", "Temperature"])
        anomalyModel = model
        anomalyVerdict = AnomalyDetection.evaluate(features.last ?? [], model: model)
    }

    // MARK: Computing

    private func compute() async {
        isWorking = true
        defer { isWorking = false }

        // The node's buffer fills over the first few seconds after it connects,
        // so a screen opened immediately at launch would otherwise land on an
        // empty state and stay there until the user pressed a button. Wait for
        // it rather than making that the user's problem.
        var record = currentRecord()
        var waited = 0.0
        while record == nil, waited < 6 {
            try? await Task.sleep(nanoseconds: 400_000_000)
            waited += 0.4
            if Task.isCancelled { return }
            record = currentRecord()
        }

        guard let record else {
            analysis = nil
            return
        }

        await run(on: record)
    }

    /// Whichever record the source picker is asking for, if it is long enough
    /// to transform. Below a few hundred samples a spectrum is meaningless.
    private func currentRecord() -> TriaxialRecord? {
            switch recordSource {
        case .ambient:
            let buffered = env.session.bufferedRecord()
            return buffered.z.samples.count > 256 ? buffered : nil
        case .lastEvent:
            // This building's most recent event, not the app's. Analysing one
            // building's spectrum while its name is shown against another's
            // recording would be worse than showing nothing.
            let candidates = env.selectedBuilding.map { building in
                env.events.filter { $0.buildingID == building.id }
            } ?? env.events
            guard let event = candidates.first,
                  let stored = env.store.eventWithRecording(event.id)?.record else {
                return nil
            }
            return stored
        }
    }

    private func run(on record: TriaxialRecord) async {
        let selectedWindow = window
        let bandwidth = smoothingBandwidth
        let selectedEstimator = estimator
        let selectedSmoother = smoother
        let expectedPeriod = env.selectedBuilding?.empiricalPeriod ?? 1.0

        // All of it off the main thread: a Welch spectrum plus a hundred-period
        // response spectrum plus an STFT is far too much work for a frame.
        analysis = await Task.detached(priority: .userInitiated) { () -> Analysis? in
            let vertical = record.z
            let horizontal = PolarisationAnalysis.horizontalMagnitude(record)

            let spectrum = selectedEstimator == .welch
                ? Spectrum.welch(horizontal, window: selectedWindow)
                : Multitaper.spectrum(horizontal, tapers: 5)

            let smoothed: PowerSpectrum
            switch selectedSmoother {
            case .none: smoothed = spectrum
            case .konnoOhmachi: smoothed = Spectrum.konnoOhmachi(spectrum, bandwidth: bandwidth)
            case .savitzkyGolay: smoothed = SavitzkyGolay.smooth(spectrum)
            }

            let peaks = PeakPicking.peaks(in: smoothed)
            let crossChecked = PeriodEstimation.crossChecked(horizontal)
            let damping = Damping.best(horizontal, material: .reinforcedConcrete)
            let envelope = Hilbert.envelope(horizontal)
            let randomDecrement = RandomDecrement.measure(horizontal)
            let responseSpectrum = ResponseSpectrumAnalysis.compute(horizontal)
            let spectrogram = STFT.compute(horizontal)
            let rectilinearity = PolarisationAnalysis.rectilinearity(record)
            let energy = EnergyAnalysis.compute(horizontal)
            let trigger = STALTA.classic(vertical)
            let falseTrigger = FalseTriggerRejection.classify(record)

            // Operational modal analysis. The Prony fit runs on the random
            // decrement signature rather than on the raw record, because Prony
            // assumes a sum of *free decays* and random decrement is precisely
            // the operation that turns ambient response into one.
            let decomposition = FrequencyDomainDecomposition.run(record, segmentLength: 1024)
            let freeDecay = randomDecrement?.signature?.samples ?? []
            let poles = freeDecay.count > 64
                ? PronyAnalysis.poles(of: freeDecay, sampleRate: horizontal.sampleRate,
                                      order: 12)
                : []
            let stablePoles = freeDecay.count > 128
                ? StabilisationDiagram.run(freeDecay, sampleRate: horizontal.sampleRate)
                : []

            let lineTest = Multitaper.lineTest(horizontal, tapers: 5)

            // Intrinsic modes, summarised by frequency and energy — the mode
            // *shapes* are thousands of samples each and nothing on screen
            // draws them, so carrying them would be carrying a copy of the
            // record several times over.
            let decomposed = EmpiricalModeDecomposition.decompose(horizontal.samples,
                                                                  maximumModes: 5)
            let intrinsicModes = decomposed.modes.map { mode in
                (frequency: EmpiricalModeDecomposition.frequency(
                    of: mode, sampleRate: horizontal.sampleRate),
                 energy: mode.reduce(0) { $0 + $1 * $1 })
            }

            // The wavelet ridge, searched around the building's own band so it
            // cannot wander onto a harmonic.
            let ridge = WaveletRidge.run(
                horizontal,
                band: max(1 / (expectedPeriod * 3), 0.15)...min(1 / (expectedPeriod * 0.3),
                                                                horizontal.sampleRate / 3),
                voices: 10)

            // Displacement, with the sensor pinned still wherever it genuinely
            // was still.
            let quiet = ConstrainedDisplacement.detectQuietWindows(horizontal)
            let displacement = ConstrainedDisplacement.estimate(horizontal,
                                                                quietWindows: quiet)

            // Aftershocks, using the record's own strongest twenty seconds as
            // the template. Self-templating: whatever the mainshock looked like
            // at this station is exactly what its aftershocks will look like.
            let aftershocks = Self.selfTemplatedAftershocks(in: horizontal)

            let kurtosisPick = KurtosisPicker.pick(vertical, windowSeconds: 0.8)
            var pickComparison: (differenceSeconds: Double, interpretation: String)?
            if let kurtosisPick, let aic = ArrivalPicker.pickP(vertical) {
                pickComparison = KurtosisPicker.compare(kurtosisPick: kurtosisPick.time,
                                                        aicPick: aic.time)
            }

            return Analysis(spectrum: spectrum, smoothed: smoothed, peaks: peaks,
                            crossChecked: crossChecked, damping: damping, envelope: envelope,
                            randomDecrement: randomDecrement,
                            responseSpectrum: responseSpectrum, spectrogram: spectrogram,
                            rectilinearity: rectilinearity, energy: energy,
                            trigger: trigger, falseTrigger: falseTrigger,
                            decomposition: decomposition, poles: poles,
                            stablePoles: stablePoles, lineTest: lineTest,
                            intrinsicModes: intrinsicModes, ridge: ridge,
                            displacement: displacement, aftershocks: aftershocks,
                            kurtosisPick: kurtosisPick, pickComparison: pickComparison)
        }.value
    }

    /// Cuts the record's own most energetic stretch as a template and looks for
    /// repeats of it elsewhere in the same record.
    ///
    /// Self-templating rather than a library of generic wavelets, because the
    /// thing that makes a matched filter work is that an aftershock on the same
    /// fault patch produces very nearly the *same* waveform at the *same*
    /// station — same path, same site response. A generic template throws that
    /// away and becomes an expensive energy detector.
    /// `nonisolated` because it is pure arithmetic and is called from the
    /// background task that runs this whole analysis. A `@MainActor` view's
    /// statics are main-actor-isolated by default, which would drag a
    /// matched filter over the entire record onto the main thread — or,
    /// under Swift 6, refuse to compile.
    private nonisolated static func selfTemplatedAftershocks(
        in w: Waveform) -> [MatchedFilter.Detection] {
        let templateSamples = Int(min(20 * w.sampleRate, Double(w.count) / 4))
        guard templateSamples >= 200, w.count > templateSamples * 3 else { return [] }

        // The most energetic window is the mainshock.
        var best = 0
        var bestEnergy = 0.0
        var start = 0
        while start + templateSamples <= w.count {
            let energy = w.samples[start..<(start + templateSamples)]
                .reduce(0.0) { $0 + $1 * $1 }
            if energy > bestEnergy { bestEnergy = energy; best = start }
            start += templateSamples / 4
        }
        guard bestEnergy > 0 else { return [] }

        let template = Array(w.samples[best..<(best + templateSamples)])
        let found = MatchedFilter.detect(in: w, template: template,
                                         threshold: .medianAbsoluteDeviation(multiple: 5),
                                         minimumSeparation: Double(templateSamples)
                                                          / w.sampleRate)
        // The template matches itself perfectly; that is not an aftershock.
        return found.filter { abs($0.sampleIndex - best) > templateSamples / 2 }
    }
}

/// The spectrogram, drawn as a heat map.
///
/// Canvas rather than Chart: this is tens of thousands of cells, and a chart
/// mark per cell would take longer to lay out than the transform took to run.
struct SpectrogramView: View {
    let spectrogram: Spectrogram

    var body: some View {
        Canvas { context, size in
            let columns = spectrogram.times.count
            let rows = min(spectrogram.frequencies.count, 120)
            guard columns > 0, rows > 0 else { return }

            let cellWidth = size.width / CGFloat(columns)
            let cellHeight = size.height / CGFloat(rows)

            // Normalised in decibels, because a linear scale puts everything
            // except the fundamental at the bottom of the range.
            var maximum = 1e-16
            for column in spectrogram.magnitudes {
                for row in 0..<rows where row < column.count {
                    maximum = max(maximum, column[row])
                }
            }
            let floorDB = -60.0

            for (columnIndex, column) in spectrogram.magnitudes.enumerated() {
                for row in 0..<rows where row < column.count {
                    let normalised = 10 * log10(max(column[row], 1e-16) / maximum)
                    let level = max(0, min(1, (normalised - floorDB) / -floorDB))
                    guard level > 0.02 else { continue }

                    let rect = CGRect(
                        x: CGFloat(columnIndex) * cellWidth,
                        y: size.height - CGFloat(row + 1) * cellHeight,
                        width: cellWidth + 0.5, height: cellHeight + 0.5)
                    context.fill(Path(rect), with: .color(Self.colour(level)))
                }
            }
        }
        .background(Theme.Palette.surface)
    }

    /// Dark blue through cyan to amber. Perceptually monotonic, and it stays
    /// legible in greyscale because lightness increases with level.
    static func colour(_ level: Double) -> Color {
        let clamped = max(0, min(1, level))
        if clamped < 0.5 {
            let t = clamped / 0.5
            return Color(red: 0.05 + 0.12 * t, green: 0.10 + 0.55 * t, blue: 0.25 + 0.60 * t)
        }
        let t = (clamped - 0.5) / 0.5
        return Color(red: 0.17 + 0.80 * t, green: 0.65 + 0.05 * t, blue: 0.85 - 0.65 * t)
    }
}

#Preview {
    NavigationStack {
        AnalysisScreen()
            .seismicBackground()
            .navigationTitle("Analysis")
    }
    .previewEnvironment()
}
