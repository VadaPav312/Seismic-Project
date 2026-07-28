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
    @State private var isSmoothed = true
    @State private var analysis: Analysis?
    @State private var isWorking = false

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
                    crossCheckSection(analysis)
                    dampingSection(analysis)
                    ambientSection(analysis)
                    historySection
                    anomalySection
                    responseSpectrumSection(analysis)
                    spectrogramSection(analysis)
                    detectionSection(analysis)
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
        }
        .task(id: recordSource) { await compute() }
        .onChange(of: window) { _, _ in Task { await compute() } }
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
        let shown = isSmoothed ? analysis.smoothed : analysis.spectrum

        return VStack(alignment: .leading, spacing: Theme.Metrics.spacing) {
            SectionLabel("Spectrum", systemImage: "waveform.path",
                         trailing: "Welch, \(window.label)")

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

            // Smoothing is a control rather than a default, because the
            // unsmoothed spectrum is noisier but honest, and a user should be
            // able to see what the smoothing did.
            Toggle(isOn: $isSmoothed) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Konno-Ohmachi smoothing")
                        .font(Theme.Typography.callout)
                        .foregroundStyle(Theme.Palette.textPrimary)
                    Text("Constant width on a log axis, so a peak at 8 Hz is smoothed as much "
                         + "as one at 1 Hz — which linear smoothing gets wrong.")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(Theme.Palette.accent)

            Picker("Window", selection: $window) {
                ForEach(Window.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)

            Text("A window is applied before the transform because a finite record has hard "
                 + "ends, and hard ends smear energy across every frequency.")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .instrumentPanel()
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
    private var anomalySection: some View {
        let history = ModeTracking.history(of: 1, in: env.observations)
        let features = history.map { [$0.period, $0.temperature ?? 15] }
        let model = AnomalyDetection.train(observations: features,
                                           featureNames: ["Period", "Temperature"])
        let latest = features.last ?? []
        let verdict = AnomalyDetection.evaluate(latest, model: model)

        return VStack(alignment: .leading, spacing: Theme.Metrics.spacing) {
            SectionLabel("Is this normal for this building?",
                         systemImage: "chart.dots.scatter",
                         trailing: model.isTrained ? "\(model.sampleCount) samples" : "Untrained")

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
            guard let event = env.events.first,
                  let stored = env.store.eventWithRecording(event.id)?.record else {
                return nil
            }
            return stored
        }
    }

    private func run(on record: TriaxialRecord) async {
        let selectedWindow = window
        let bandwidth = smoothingBandwidth

        // All of it off the main thread: a Welch spectrum plus a hundred-period
        // response spectrum plus an STFT is far too much work for a frame.
        analysis = await Task.detached(priority: .userInitiated) { () -> Analysis? in
            let vertical = record.z
            let horizontal = PolarisationAnalysis.horizontalMagnitude(record)

            let spectrum = Spectrum.welch(horizontal, window: selectedWindow)
            let smoothed = Spectrum.konnoOhmachi(spectrum, bandwidth: bandwidth)
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

            return Analysis(spectrum: spectrum, smoothed: smoothed, peaks: peaks,
                            crossChecked: crossChecked, damping: damping, envelope: envelope,
                            randomDecrement: randomDecrement,
                            responseSpectrum: responseSpectrum, spectrogram: spectrogram,
                            rectilinearity: rectilinearity, energy: energy,
                            trigger: trigger, falseTrigger: falseTrigger)
        }.value
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
