import SwiftUI
import SeismicCore
import SeismicSignal

/// The seismograph.
///
/// Drawn with Canvas rather than SwiftUI shapes or the Charts framework, for one
/// reason: this view renders three channels of up to 12,000 samples at 60 fps
/// while the phone is also running a structural simulation. A per-sample `Path`
/// in a `ForEach` cannot do that. Canvas draws the whole thing in one pass, and
/// the decimation runs first so the number of points drawn is bounded by the
/// pixel width rather than by the sample rate.
///
/// Min/max decimation is used rather than subsampling because the peaks are the
/// only part anybody cares about, and subsampling drops them.
struct WaveformChart: View {

    struct Channel: Identifiable {
        let id: String
        let waveform: Waveform
        let color: Color
        let label: String
        var dashed = false

        init(id: String, waveform: Waveform, color: Color, label: String, dashed: Bool = false) {
            self.id = id; self.waveform = waveform; self.color = color
            self.label = label; self.dashed = dashed
        }
    }

    let channels: [Channel]
    var showsGrid = true
    var showsAxisLabels = true
    var fixedScale: Double?
    /// Marks drawn on the time axis: arrivals, actuator firings, trigger points.
    var markers: [TimeMarker] = []
    /// A vertical line following the user's finger, or the playhead.
    var playheadTime: Double?
    var height: CGFloat = 180
    var unitLabel: String = "m/s²"

    struct TimeMarker: Identifiable {
        let id = UUID()
        let time: Double
        let label: String
        let color: Color
        var dashed = true
    }

    @State private var inspectedTime: Double?
    @State private var frozen = false

    private var duration: Double {
        channels.map(\.waveform.duration).max() ?? 1
    }

    private var scale: Double {
        if let fixedScale { return max(fixedScale, 1e-9) }
        let peak = channels.map(\.waveform.peakAbsolute).max() ?? 1
        // A little headroom so the trace never touches the frame, and a floor so
        // a perfectly quiet trace does not amplify its own noise to full scale.
        return max(peak * 1.25, 1e-4)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showsAxisLabels {
                header
            }

            GeometryReader { geometry in
                Canvas { context, size in
                    if showsGrid { drawGrid(context: context, size: size) }
                    drawZeroLine(context: context, size: size)

                    for channel in channels {
                        draw(channel: channel, context: context, size: size)
                    }

                    drawMarkers(context: context, size: size)

                    if let time = inspectedTime ?? playheadTime {
                        drawPlayhead(at: time, context: context, size: size)
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let fraction = min(max(value.location.x / geometry.size.width, 0), 1)
                            inspectedTime = fraction * duration
                        }
                        .onEnded { _ in
                            // The value stays on screen after the finger lifts:
                            // reading a number and then having it vanish is
                            // maddening.
                        }
                )
            }
            .frame(height: height)
            .background(
                RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadiusSmall, style: .continuous)
                    .fill(Theme.Palette.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadiusSmall, style: .continuous)
                    .strokeBorder(Theme.Palette.hairline, lineWidth: 1)
            )

            if showsAxisLabels { footer }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
    }

    // MARK: Chrome

    private var header: some View {
        HStack(spacing: 10) {
            ForEach(channels) { channel in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(channel.color)
                        .frame(width: 10, height: 2)
                    Text(channel.label)
                        .font(Theme.Typography.label)
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
            }
            Spacer(minLength: 0)
            Text(String(format: "±%.3f %@", scale, unitLabel))
                .font(Theme.Typography.numericSmall)
                .foregroundStyle(Theme.Palette.textTertiary)
        }
    }

    private var footer: some View {
        HStack {
            Text("0 s")
            Spacer()
            if let time = inspectedTime {
                // Tapping anywhere reads out the value at that instant on every
                // channel at once, which is what an engineer actually wants.
                HStack(spacing: 8) {
                    Text(String(format: "%.2f s", time))
                        .foregroundStyle(Theme.Palette.accent)
                    ForEach(channels) { channel in
                        Text(String(format: "%@ %.4f", channel.label.prefix(1).uppercased(),
                                    valueAt(time: time, in: channel.waveform)))
                            .foregroundStyle(channel.color)
                    }
                }
            }
            Spacer()
            Text(String(format: "%.0f s", duration))
        }
        .font(Theme.Typography.numericSmall)
        .foregroundStyle(Theme.Palette.textTertiary)
    }

    private func valueAt(time: Double, in waveform: Waveform) -> Double {
        guard !waveform.isEmpty else { return 0 }
        return waveform.samples[waveform.index(atTime: time)]
    }

    // MARK: Drawing

    private func drawGrid(context: GraphicsContext, size: CGSize) {
        // Time gridlines every fifth of the width; amplitude at quarter scale.
        var path = Path()
        for i in 1..<5 {
            let x = size.width * CGFloat(i) / 5
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: size.height))
        }
        for i in 1..<4 where i != 2 {
            let y = size.height * CGFloat(i) / 4
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
        }
        context.stroke(path, with: .color(Theme.Palette.gridLine), lineWidth: 0.5)
    }

    private func drawZeroLine(context: GraphicsContext, size: CGSize) {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: size.height / 2))
        path.addLine(to: CGPoint(x: size.width, y: size.height / 2))
        context.stroke(path, with: .color(Theme.Palette.gridLineMajor), lineWidth: 0.75)
    }

    private func draw(channel: Channel, context: GraphicsContext, size: CGSize) {
        let waveform = channel.waveform
        guard waveform.count > 1, size.width > 1 else { return }

        let columns = Int(size.width)
        let midY = size.height / 2
        let amplitudeScale = size.height / 2 / scale

        var path = Path()

        if waveform.count > columns * 2 {
            // Dense: draw the true envelope, so no peak is ever lost to
            // decimation. This is what makes a 20-minute record legible.
            let bands = Decimation.minMax(waveform, columns: columns)
            for (index, band) in bands.enumerated() {
                let x = size.width * CGFloat(index) / CGFloat(max(bands.count - 1, 1))
                let top = midY - CGFloat(band.max) * amplitudeScale
                let bottom = midY - CGFloat(band.min) * amplitudeScale
                path.move(to: CGPoint(x: x, y: top))
                path.addLine(to: CGPoint(x: x, y: max(bottom, top + 0.5)))
            }
        } else {
            // Sparse enough to draw as a genuine line.
            let points = Decimation.forDisplay(waveform, targetPoints: columns * 2)
            for (index, point) in points.enumerated() {
                let x = size.width * CGFloat(point.x / max(duration, 1e-9))
                let y = midY - CGFloat(point.y) * amplitudeScale
                if index == 0 { path.move(to: CGPoint(x: x, y: y)) }
                else { path.addLine(to: CGPoint(x: x, y: y)) }
            }
        }

        let style = StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round,
                                dash: channel.dashed ? [3, 3] : [])
        context.stroke(path, with: .color(channel.color), style: style)
    }

    private func drawMarkers(context: GraphicsContext, size: CGSize) {
        for marker in markers {
            let x = size.width * CGFloat(marker.time / max(duration, 1e-9))
            guard x.isFinite, x >= 0, x <= size.width else { continue }

            var path = Path()
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(path, with: .color(marker.color.opacity(0.85)),
                           style: StrokeStyle(lineWidth: 1,
                                              dash: marker.dashed ? [4, 3] : []))

            let text = Text(marker.label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(marker.color)
            context.draw(text, at: CGPoint(x: x + 3, y: 9), anchor: .leading)
        }
    }

    private func drawPlayhead(at time: Double, context: GraphicsContext, size: CGSize) {
        let x = size.width * CGFloat(time / max(duration, 1e-9))
        guard x.isFinite else { return }
        var path = Path()
        path.move(to: CGPoint(x: x, y: 0))
        path.addLine(to: CGPoint(x: x, y: size.height))
        context.stroke(path, with: .color(Theme.Palette.accent), lineWidth: 1)
    }

    /// VoiceOver gets a genuine description of the trace rather than "chart".
    private var accessibilityDescription: String {
        guard let first = channels.first, !first.waveform.isEmpty else {
            return "Waveform chart, no data yet."
        }
        let peak = first.waveform.peakAbsolute
        let rms = first.waveform.rms
        return "Waveform chart of \(channels.count) channels over "
            + "\(Int(duration)) seconds. Peak \(String(format: "%.3f", peak)) \(unitLabel), "
            + "typical level \(String(format: "%.4f", rms)) \(unitLabel)."
    }
}

// MARK: - Trigger ratio strip

/// The STA/LTA ratio, drawn beneath the seismograph.
///
/// Shown as its own strip rather than overlaid, because it is dimensionless and
/// would need a second axis. The threshold line is the important part: it makes
/// the trigger decision visible instead of mysterious.
struct TriggerRatioStrip: View {
    let ratio: Waveform
    let threshold: Double
    var height: CGFloat = 54

    private var scale: Double {
        max(ratio.samples.max() ?? threshold, threshold * 1.4)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("STA / LTA RATIO")
                    .font(Theme.Typography.label)
                    .tracking(1.0)
                    .foregroundStyle(Theme.Palette.textTertiary)
                Spacer()
                Text(String(format: "now %.2f · trigger at %.1f",
                            ratio.samples.last ?? 1, threshold))
                    .font(Theme.Typography.numericSmall)
                    .foregroundStyle(ratioColor)
            }

            Canvas { context, size in
                guard ratio.count > 1, size.width > 1 else { return }
                let columns = Int(size.width)
                let bands = Decimation.minMax(ratio, columns: columns)

                // Filled area, which reads better than a line for a quantity
                // that is always positive.
                var area = Path()
                area.move(to: CGPoint(x: 0, y: size.height))
                for (index, band) in bands.enumerated() {
                    let x = size.width * CGFloat(index) / CGFloat(max(bands.count - 1, 1))
                    let y = size.height * (1 - CGFloat(min(band.max / scale, 1)))
                    area.addLine(to: CGPoint(x: x, y: y))
                }
                area.addLine(to: CGPoint(x: size.width, y: size.height))
                area.closeSubpath()
                context.fill(area, with: .linearGradient(
                    Gradient(colors: [Theme.Palette.accent.opacity(0.45),
                                      Theme.Palette.accent.opacity(0.04)]),
                    startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))

                // The threshold: the line that decides whether this is an event.
                let thresholdY = size.height * (1 - CGFloat(min(threshold / scale, 1)))
                var line = Path()
                line.move(to: CGPoint(x: 0, y: thresholdY))
                line.addLine(to: CGPoint(x: size.width, y: thresholdY))
                context.stroke(line, with: .color(Theme.Palette.verdictAmber.opacity(0.9)),
                               style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            }
            .frame(height: height)
            .background(
                RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadiusSmall, style: .continuous)
                    .fill(Theme.Palette.surface))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadiusSmall, style: .continuous)
                    .strokeBorder(Theme.Palette.hairline, lineWidth: 1))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Trigger ratio")
        .accessibilityValue(String(format: "%.2f, threshold %.1f", ratio.samples.last ?? 1, threshold))
    }

    private var ratioColor: Color {
        let current = ratio.samples.last ?? 1
        if current >= threshold { return Theme.Palette.verdictAmber }
        if current >= threshold * 0.6 { return Theme.Palette.textPrimary }
        return Theme.Palette.textTertiary
    }
}

// MARK: - Spectrum

struct SpectrumChart: View {
    let spectrum: PowerSpectrum
    var peaks: [SpectralPeak] = []
    var band: ClosedRange<Double>?
    var height: CGFloat = 170
    var logFrequency = true

    private var visible: PowerSpectrum {
        band.map { spectrum.band($0) } ?? spectrum
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Canvas { context, size in
                let data = visible
                guard data.frequencies.count > 2, size.width > 1 else { return }

                let maximum = data.power.max() ?? 1
                guard maximum > 0 else { return }

                let minFrequency = max(data.frequencies.first ?? 0.1, 0.05)
                let maxFrequency = max(data.frequencies.last ?? 10, minFrequency * 1.1)

                func xPosition(_ frequency: Double) -> CGFloat {
                    guard logFrequency else {
                        return size.width * CGFloat((frequency - minFrequency)
                                                    / (maxFrequency - minFrequency))
                    }
                    let value = (log10(max(frequency, minFrequency)) - log10(minFrequency))
                        / (log10(maxFrequency) - log10(minFrequency))
                    return size.width * CGFloat(value)
                }

                // Decibel scale: a linear power axis shows one spike and nothing
                // else, which hides every mode but the first.
                func yPosition(_ power: Double) -> CGFloat {
                    let db = 10 * log10(max(power, maximum * 1e-6) / maximum)
                    let normalised = (db + 60) / 60
                    return size.height * (1 - CGFloat(min(max(normalised, 0), 1)))
                }

                var path = Path()
                for (index, frequency) in data.frequencies.enumerated() {
                    let point = CGPoint(x: xPosition(frequency), y: yPosition(data.power[index]))
                    if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
                context.stroke(path, with: .color(Theme.Palette.accent),
                               style: StrokeStyle(lineWidth: 1.4, lineJoin: .round))

                var fill = path
                fill.addLine(to: CGPoint(x: size.width, y: size.height))
                fill.addLine(to: CGPoint(x: 0, y: size.height))
                fill.closeSubpath()
                context.fill(fill, with: .linearGradient(
                    Gradient(colors: [Theme.Palette.accent.opacity(0.28), .clear]),
                    startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))

                // Identified modes, labelled with their period — which is the
                // number the rest of the app talks in.
                for peak in peaks {
                    let x = xPosition(peak.frequency)
                    guard x.isFinite, x >= 0, x <= size.width else { continue }
                    var marker = Path()
                    marker.move(to: CGPoint(x: x, y: 0))
                    marker.addLine(to: CGPoint(x: x, y: size.height))
                    context.stroke(marker, with: .color(Theme.Palette.verdictAmber.opacity(0.7)),
                                   style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    context.draw(
                        Text(String(format: "%.2f s", peak.period))
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(Theme.Palette.verdictAmber),
                        at: CGPoint(x: x + 3, y: 10), anchor: .leading)
                }
            }
            .frame(height: height)
            .background(
                RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadiusSmall, style: .continuous)
                    .fill(Theme.Palette.surface))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadiusSmall, style: .continuous)
                    .strokeBorder(Theme.Palette.hairline, lineWidth: 1))

            HStack {
                Text(String(format: "%.2f Hz", visible.frequencies.first ?? 0))
                Spacer()
                Text(logFrequency ? "frequency (log)" : "frequency")
                Spacer()
                Text(String(format: "%.1f Hz", visible.frequencies.last ?? 0))
            }
            .font(Theme.Typography.numericSmall)
            .foregroundStyle(Theme.Palette.textTertiary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Frequency spectrum")
        .accessibilityValue(peaks.isEmpty ? "No modes identified"
            : "Strongest mode at \(String(format: "%.2f", peaks.max { $0.power < $1.power }?.period ?? 0)) seconds")
    }
}

// MARK: - Trend chart

/// A time series with an optional band, used for period history, temperature,
/// and CUSUM.
struct TrendChart: View {
    struct Point: Identifiable {
        let id = UUID()
        let date: Date
        let value: Double
    }

    let points: [Point]
    var color: Color = Theme.Palette.accent
    var baseline: Double?
    var band: ClosedRange<Double>?
    var height: CGFloat = 160
    var valueFormatter: (Double) -> String = { String(format: "%.3f", $0) }
    /// A vertical marker, e.g. where a change was detected.
    var eventDate: Date?

    private var range: (min: Double, max: Double) {
        let values = points.map(\.value)
        guard let low = values.min(), let high = values.max() else { return (0, 1) }
        let padding = max((high - low) * 0.15, abs(high) * 0.01 + 1e-9)
        return (low - padding, high + padding)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Canvas { context, size in
                guard points.count > 1, size.width > 1 else { return }
                let (low, high) = range
                let span = max(high - low, 1e-12)

                guard let firstDate = points.first?.date,
                      let lastDate = points.last?.date else { return }
                let timeSpan = max(lastDate.timeIntervalSince(firstDate), 1)

                func position(_ point: Point) -> CGPoint {
                    CGPoint(x: size.width * CGFloat(point.date.timeIntervalSince(firstDate) / timeSpan),
                            y: size.height * CGFloat(1 - (point.value - low) / span))
                }

                if let band {
                    let topY = size.height * CGFloat(1 - (band.upperBound - low) / span)
                    let bottomY = size.height * CGFloat(1 - (band.lowerBound - low) / span)
                    context.fill(
                        Path(CGRect(x: 0, y: topY, width: size.width,
                                    height: max(bottomY - topY, 1))),
                        with: .color(color.opacity(0.10)))
                }

                if let baseline {
                    let y = size.height * CGFloat(1 - (baseline - low) / span)
                    var line = Path()
                    line.move(to: CGPoint(x: 0, y: y))
                    line.addLine(to: CGPoint(x: size.width, y: y))
                    context.stroke(line, with: .color(Theme.Palette.textTertiary.opacity(0.6)),
                                   style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                }

                if let eventDate {
                    let x = size.width * CGFloat(eventDate.timeIntervalSince(firstDate) / timeSpan)
                    if x.isFinite, x >= 0, x <= size.width {
                        var line = Path()
                        line.move(to: CGPoint(x: x, y: 0))
                        line.addLine(to: CGPoint(x: x, y: size.height))
                        context.stroke(line, with: .color(Theme.Palette.verdictAmber),
                                       style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                    }
                }

                // Long histories are decimated so a year of four-hourly scans
                // still draws in one frame.
                let stride = max(points.count / Int(size.width * 2), 1)
                var path = Path()
                var started = false
                for index in Swift.stride(from: 0, to: points.count, by: stride) {
                    let point = position(points[index])
                    if !started { path.move(to: point); started = true }
                    else { path.addLine(to: point) }
                }
                context.stroke(path, with: .color(color),
                               style: StrokeStyle(lineWidth: 1.3, lineJoin: .round))
            }
            .frame(height: height)
            .background(
                RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadiusSmall, style: .continuous)
                    .fill(Theme.Palette.surface))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadiusSmall, style: .continuous)
                    .strokeBorder(Theme.Palette.hairline, lineWidth: 1))

            HStack {
                Text(points.first?.date.formatted(date: .abbreviated, time: .omitted) ?? "")
                Spacer()
                Text(valueFormatter(range.min) + " – " + valueFormatter(range.max))
                Spacer()
                Text(points.last?.date.formatted(date: .abbreviated, time: .omitted) ?? "")
            }
            .font(Theme.Typography.numericSmall)
            .foregroundStyle(Theme.Palette.textTertiary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Trend over time")
        .accessibilityValue("\(points.count) measurements, "
            + "from \(valueFormatter(range.min)) to \(valueFormatter(range.max))")
    }
}

// MARK: - Storey drift profile

/// Drift per floor, drawn as a vertical profile — the way engineers read it,
/// with the building's height running up the page.
struct DriftProfileChart: View {
    struct Storey: Identifiable {
        let id: Int
        let drift: Double
        let damageStateIndex: Int
        let label: String
    }

    let storeys: [Storey]
    let thresholds: [Double]
    var height: CGFloat = 260

    private var maximumDrift: Double {
        max(storeys.map(\.drift).max() ?? 0.01, thresholds.first ?? 0.005) * 1.2
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom, spacing: 2) {
                // Floor numbers up the left.
                VStack(spacing: 1) {
                    ForEach(storeys.reversed()) { storey in
                        Text("\(storey.id)")
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundStyle(Theme.Palette.textTertiary)
                            .frame(height: max(height / CGFloat(storeys.count) - 1, 4))
                    }
                }
                .frame(width: 16)

                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        // Threshold lines, so a bar's colour has a visible reason.
                        ForEach(Array(thresholds.enumerated()), id: \.offset) { index, threshold in
                            let x = geometry.size.width * CGFloat(threshold / maximumDrift)
                            if x.isFinite, x < geometry.size.width {
                                Rectangle()
                                    .fill(DamageStateColors.color(for: index + 1).opacity(0.35))
                                    .frame(width: 1)
                                    .offset(x: x)
                            }
                        }

                        VStack(spacing: 1) {
                            ForEach(storeys.reversed()) { storey in
                                HStack(spacing: 0) {
                                    RoundedRectangle(cornerRadius: 1.5)
                                        .fill(DamageStateColors.color(for: storey.damageStateIndex))
                                        .frame(width: max(geometry.size.width
                                                          * CGFloat(storey.drift / maximumDrift), 1))
                                    Spacer(minLength: 0)
                                }
                                .frame(height: max(height / CGFloat(storeys.count) - 1, 4))
                            }
                        }
                    }
                }
            }
            .frame(height: height)

            HStack {
                Text("0%")
                Spacer()
                Text("interstorey drift")
                Spacer()
                Text(String(format: "%.1f%%", maximumDrift * 100))
            }
            .font(Theme.Typography.numericSmall)
            .foregroundStyle(Theme.Palette.textTertiary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Storey drift profile")
        .accessibilityValue({
            guard let worst = storeys.max(by: { $0.drift < $1.drift }) else {
                return "No data"
            }
            return "Worst drift \(String(format: "%.2f", worst.drift * 100)) per cent "
                + "at storey \(worst.id)"
        }())
    }
}

#Preview("Charts") {
    ScrollView {
        VStack(spacing: 20) {
            WaveformChart(channels: [
                .init(id: "x", waveform: SyntheticMotion.generate(.init(magnitude: 6.2,
                                                                        distanceKm: 25,
                                                                        seed: 4)).x,
                      color: Theme.Palette.axisX, label: "N–S"),
            ], markers: [
                .init(time: 12, label: "P", color: Theme.Palette.accent),
                .init(time: 17, label: "S", color: Theme.Palette.verdictAmber),
            ])

            TriggerRatioStrip(
                ratio: STALTA.classic(SyntheticMotion.generate(.init(magnitude: 6.2,
                                                                     distanceKm: 25,
                                                                     seed: 4)).magnitude).ratio,
                threshold: 4)
        }
        .padding()
    }
    .seismicBackground()
    .preferredColorScheme(.dark)
}
