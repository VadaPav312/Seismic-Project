import Foundation
import SeismicCore

// Algorithms 23–28. Measuring the building itself rather than the earthquake:
// how fast it sways, how quickly it settles, and how to tell a real change from
// a cold morning.

// MARK: - 23. Hilbert transform envelope

public enum Hilbert {

    /// Algorithm 23 — analytic signal and envelope via the Hilbert transform.
    ///
    /// A decaying oscillation's amplitude is not something you can read off the
    /// samples: between peaks the signal passes through zero. The Hilbert
    /// transform builds the analytic signal, whose magnitude is the smooth
    /// envelope — and it is the slope of that envelope that damping is measured
    /// from.
    public static func analyticSignal(_ x: [Double]) -> [Complex] {
        guard x.count > 1 else { return x.map { Complex($0) } }
        let n = FFT.nextPowerOfTwo(x.count)
        var buffer = [Complex](repeating: Complex(0), count: n)
        for (i, v) in x.enumerated() { buffer[i] = Complex(v) }
        FFT.forward(&buffer)

        // Zero the negative frequencies and double the positive ones — this is
        // the frequency-domain definition of the analytic signal.
        let half = n / 2
        for i in 1..<half { buffer[i] = Complex(buffer[i].re * 2, buffer[i].im * 2) }
        for i in (half + 1)..<n { buffer[i] = Complex(0, 0) }

        FFT.inverse(&buffer)
        return Array(buffer[0..<x.count])
    }

    public static func envelope(_ x: [Double]) -> [Double] {
        analyticSignal(x).map(\.magnitude)
    }

    public static func envelope(_ w: Waveform) -> Waveform {
        w.mapped { envelope($0) }
    }

    /// Instantaneous frequency, in Hz, from the derivative of the phase.
    ///
    /// This is the other way to watch a building soften during an event: its
    /// instantaneous frequency drops as it yields, sample by sample.
    public static func instantaneousFrequency(_ x: [Double], sampleRate: Double) -> [Double] {
        let analytic = analyticSignal(x)
        guard analytic.count > 2 else { return [] }
        var phases = analytic.map(\.phase)

        // Unwrap: raw atan2 output jumps by 2π, which would differentiate into
        // enormous spikes.
        for i in 1..<phases.count {
            var delta = phases[i] - phases[i - 1]
            while delta > Double.pi { delta -= 2 * Double.pi; phases[i] -= 2 * Double.pi }
            while delta < -Double.pi { delta += 2 * Double.pi; phases[i] += 2 * Double.pi }
        }

        var out = [Double](repeating: 0, count: phases.count)
        for i in 1..<(phases.count - 1) {
            out[i] = (phases[i + 1] - phases[i - 1]) * sampleRate / (4 * Double.pi)
        }
        if out.count > 2 { out[0] = out[1]; out[out.count - 1] = out[out.count - 2] }
        return out
    }
}

// MARK: - Damping

public struct DampingEstimate: Sendable, Equatable {
    /// Fraction of critical damping.
    public var ratio: Double
    public var method: Method
    public var confidence: Double
    public var detail: String

    public enum Method: String, Sendable, Codable {
        case logarithmicDecrement, halfPowerBandwidth, randomDecrement, assumed
        public var label: String {
            switch self {
            case .logarithmicDecrement: "Logarithmic decrement"
            case .halfPowerBandwidth: "Half-power bandwidth"
            case .randomDecrement: "Random decrement"
            case .assumed: "Assumed from material"
            }
        }
    }

    public init(ratio: Double, method: Method, confidence: Double, detail: String) {
        self.ratio = ratio; self.method = method
        self.confidence = confidence; self.detail = detail
    }

    /// As a percentage, which is how engineers quote it.
    public var percent: Double { ratio * 100 }
}

public enum Damping {

    /// Algorithm 24 — logarithmic decrement.
    ///
    /// Once the shaking stops, the building rings down. The ratio between
    /// successive peak amplitudes is fixed by the damping, so fitting a line to
    /// the log of the envelope gives the damping ratio directly. This is the
    /// most trustworthy method when there is clean free decay to work with.
    public static func logarithmicDecrement(_ w: Waveform,
                                            skipInitialFraction: Double = 0.05)
        -> DampingEstimate?
    {
        guard w.count > 32 else { return nil }
        let envelope = Hilbert.envelope(Detrend.linear(w.samples))
        guard let peak = envelope.max(), peak > 1e-12 else { return nil }

        // Fit only over the decaying portion, and only while the envelope is
        // well above the noise floor — the tail is all noise and would flatten
        // the fit towards zero damping.
        let peakIndex = envelope.firstIndex(where: { $0 >= peak * 0.999 }) ?? 0
        let start = peakIndex + Int(Double(envelope.count) * skipInitialFraction)
        let floorLevel = peak * 0.05
        var end = envelope.count - 1
        for i in start..<envelope.count where envelope[i] < floorLevel { end = i; break }
        guard end > start + 16 else { return nil }

        var times: [Double] = [], logs: [Double] = []
        for i in start...end where envelope[i] > 1e-15 {
            times.append(w.time(at: i))
            logs.append(log(envelope[i]))
        }
        guard times.count > 8 else { return nil }

        let fit = Stats.linearRegression(x: times, y: logs)
        // envelope ∝ exp(−ζ·ω_n·t), so slope = −ζ·ω_n.
        guard fit.slope < 0 else { return nil }

        // A weak fit means this was not free decay at all — a steady vibration,
        // or noise. Reporting a damping ratio from it would be inventing a
        // number, so refuse instead.
        guard fit.r2 >= 0.5 else { return nil }

        // Measure the period over the *same* window that was fitted. Estimating
        // it from the whole record lets the noise-dominated tail — where the
        // signal has already decayed away — set a zero-crossing rate of tens of
        // hertz, which would divide the damping down to nothing.
        let fitted = Waveform(samples: Array(w.samples[start...end]),
                              sampleRate: w.sampleRate, unit: w.unit)
        let periodEstimate = PeriodEstimation.autocorrelation(fitted)?.period
            ?? PeriodEstimation.zeroCrossing(fitted)?.period
        guard let periodEstimate, periodEstimate > 0 else { return nil }

        let omega = 2 * Double.pi / periodEstimate
        let zeta = -fit.slope / omega

        guard zeta > 0.0005, zeta < 0.5 else { return nil }
        return DampingEstimate(
            ratio: zeta, method: .logarithmicDecrement,
            confidence: Swift.min(fit.r2, 1),
            detail: "Fitted to \(times.count) samples of free decay; "
                + "envelope fit R² = \(String(format: "%.3f", fit.r2)).")
    }

    /// Algorithm 25 — half-power bandwidth.
    ///
    /// A lightly damped building has a tall narrow spectral peak; a heavily
    /// damped one has a short wide one. The width where power halves gives the
    /// damping straight away. Works on ambient data with no free decay at all,
    /// which is its whole advantage — but it over-reads badly if two modes are
    /// close together, so it is always presented as a cross-check.
    public static func halfPowerBandwidth(_ peak: SpectralPeak) -> DampingEstimate? {
        guard peak.frequency > 0, peak.halfPowerBandwidth > 0 else { return nil }
        let zeta = peak.halfPowerBandwidth / (2 * peak.frequency)
        guard zeta > 0.0005, zeta < 0.5 else { return nil }

        // Confidence falls when the peak is not sharply defined.
        let sharpness = Swift.min(peak.prominence * 2, 1)
        return DampingEstimate(
            ratio: zeta, method: .halfPowerBandwidth,
            confidence: sharpness,
            detail: "Peak at \(String(format: "%.3f", peak.frequency)) Hz is "
                + "\(String(format: "%.4f", peak.halfPowerBandwidth)) Hz wide at half power.")
    }

    public static func halfPowerBandwidth(_ w: Waveform,
                                          band: ClosedRange<Double> = 0.1...10)
        -> DampingEstimate?
    {
        let spectrum = Spectrum.konnoOhmachi(Spectrum.welch(w), bandwidth: 40)
        guard let peak = PeakPicking.peaks(in: spectrum, minimumProminence: 0.25, band: band)
            .max(by: { $0.power < $1.power }) else { return nil }

        // Broadband noise always has *a* tallest bin. Requiring the peak to
        // stand well clear of the typical level in its band is what separates a
        // resonance from the loudest patch of hiss.
        let inBand = spectrum.band(band).power
        let typical = Stats.median(inBand)
        guard typical > 0, peak.power > typical * 8 else { return nil }

        return halfPowerBandwidth(peak)
    }

    /// Both methods plus a fallback, so damping is never simply missing.
    ///
    /// The bar for accepting a measurement is deliberately high. An assumed
    /// value that is honestly labelled as assumed is far more useful than a
    /// measured-looking number extracted from a record that had nothing in it.
    public static func best(_ w: Waveform, material: ConstructionMaterial) -> DampingEstimate {
        let plausible = 0.002...0.25
        let candidates = [logarithmicDecrement(w), halfPowerBandwidth(w)]
            .compactMap { $0 }
            .filter { plausible.contains($0.ratio) }
        if let best = candidates.max(by: { $0.confidence < $1.confidence }), best.confidence > 0.5 {
            return best
        }
        return DampingEstimate(
            ratio: material.typicalDamping, method: .assumed, confidence: 0.35,
            detail: "Could not measure damping from this record. "
                + "Using the standard value for \(material.label.lowercased()).")
    }
}

// MARK: - 26. Random decrement technique

public enum RandomDecrement {

    /// Algorithm 26 — extract a free-decay signature from ambient vibration.
    ///
    /// This is the quiet miracle of the whole system. A building is always
    /// moving slightly — wind, traffic, people. That motion looks like noise,
    /// but if you take every moment the response crosses a fixed level and
    /// average the segments that follow, the random part averages to nothing and
    /// what remains is the building's own free-decay response. It means the
    /// period and damping can be measured any day of the week, with no
    /// earthquake and no shaker — which is what makes a *baseline* possible.
    public static func signature(_ w: Waveform,
                                 triggerLevel: Double? = nil,
                                 segmentSeconds: Double = 20,
                                 minimumSegments: Int = 20) -> Waveform? {
        guard w.count > 64 else { return nil }
        let x = Detrend.linear(w.samples)
        let sigma = Stats.stdDev(x)
        guard sigma > 1e-12 else { return nil }

        // The conventional trigger level is one standard deviation: high enough
        // to be a real excursion, low enough to happen often.
        let level = triggerLevel ?? sigma
        let segmentN = Swift.max(Int(segmentSeconds * w.sampleRate), 16)
        guard x.count > segmentN * 2 else { return nil }

        var accumulator = [Double](repeating: 0, count: segmentN)
        var count = 0

        var i = 1
        while i < x.count - segmentN {
            // Positive-going crossings of the level only. Mixing directions
            // would cancel the very signal we are trying to recover.
            if x[i - 1] < level, x[i] >= level {
                for j in 0..<segmentN { accumulator[j] += x[i + j] }
                count += 1
                i += Swift.max(segmentN / 8, 1)   // avoid over-counting one excursion
            } else {
                i += 1
            }
        }

        guard count >= minimumSegments else { return nil }
        let averaged = accumulator.map { $0 / Double(count) }
        return Waveform(samples: averaged, sampleRate: w.sampleRate,
                        startTime: w.startTime, unit: w.unit)
    }

    /// The full ambient measurement: period and damping from ordinary background
    /// vibration. This is what runs nightly to build the baseline history.
    public struct AmbientMeasurement: Sendable, Equatable {
        public var period: Double
        public var damping: DampingEstimate?
        public var segmentsAveraged: Int
        public var confidence: Double
        public var signature: Waveform?
    }

    public static func measure(_ w: Waveform,
                               band: ClosedRange<Double> = 0.1...10) -> AmbientMeasurement? {
        guard let sig = signature(w) else {
            // No usable free-decay signature — fall back to the spectrum, which
            // still works, just with less confidence.
            let crossChecked = PeriodEstimation.crossChecked(w, band: band)
            guard let period = crossChecked.consensus else { return nil }
            return AmbientMeasurement(period: period, damping: nil, segmentsAveraged: 0,
                                      confidence: crossChecked.agreement * 0.6, signature: nil)
        }

        let crossChecked = PeriodEstimation.crossChecked(sig, band: band)
        guard let period = crossChecked.consensus else { return nil }
        let damping = Damping.logarithmicDecrement(sig)

        return AmbientMeasurement(
            period: period,
            damping: damping,
            segmentsAveraged: 0,
            confidence: Swift.min(crossChecked.agreement * 0.9 + 0.1, 1),
            signature: sig)
    }
}

// MARK: - 27. Mode tracking

/// One identified mode at one moment in time.
public struct ModeObservation: Sendable, Equatable, Identifiable, Codable {
    public var id: UUID
    public var modeNumber: Int
    public var frequency: Double
    public var damping: Double?
    public var amplitude: Double
    public var at: Date
    public var temperature: Double?

    public var period: Double { frequency > 0 ? 1 / frequency : 0 }

    public init(id: UUID = UUID(), modeNumber: Int, frequency: Double, damping: Double? = nil,
                amplitude: Double, at: Date = Date(), temperature: Double? = nil) {
        self.id = id; self.modeNumber = modeNumber; self.frequency = frequency
        self.damping = damping; self.amplitude = amplitude
        self.at = at; self.temperature = temperature
    }
}

public enum ModeTracking {

    /// Algorithm 27 — track modes across scans with hysteresis.
    ///
    /// Modes swap places. If the second mode's amplitude briefly exceeds the
    /// first's, a naive "sort by power" scheme silently starts comparing mode
    /// two against mode one's history — and reports a 300% period change that
    /// never happened. Matching each new peak to the nearest existing track,
    /// within a tolerance, prevents exactly that.
    ///
    /// - Parameter tolerance: fractional frequency distance that still counts as
    ///   the same mode. 0.15 means a peak within 15% of a track's last frequency.
    public static func assign(peaks: [SpectralPeak],
                              to previous: [ModeObservation],
                              tolerance: Double = 0.15,
                              at time: Date = Date(),
                              temperature: Double? = nil) -> [ModeObservation] {
        guard !peaks.isEmpty else { return [] }

        // Nothing to match against: number them by frequency, lowest first.
        guard !previous.isEmpty else {
            return peaks.sorted { $0.frequency < $1.frequency }
                .enumerated()
                .map { ModeObservation(modeNumber: $0.offset + 1, frequency: $0.element.frequency,
                                       amplitude: $0.element.power, at: time,
                                       temperature: temperature) }
        }

        var available = peaks
        var out: [ModeObservation] = []
        var claimed = Set<Int>()

        // Greedy nearest match, strongest existing track first.
        for track in previous.sorted(by: { $0.modeNumber < $1.modeNumber }) {
            guard track.frequency > 0 else { continue }
            var bestIndex: Int?
            var bestDistance = Double.infinity
            for (i, peak) in available.enumerated() where !claimed.contains(i) {
                let distance = abs(peak.frequency - track.frequency) / track.frequency
                if distance < bestDistance, distance <= tolerance {
                    bestDistance = distance; bestIndex = i
                }
            }
            if let idx = bestIndex {
                claimed.insert(idx)
                out.append(ModeObservation(modeNumber: track.modeNumber,
                                           frequency: available[idx].frequency,
                                           amplitude: available[idx].power,
                                           at: time, temperature: temperature))
            }
        }

        // Peaks that matched nothing are new modes, numbered after the existing ones.
        var nextNumber = (previous.map(\.modeNumber).max() ?? 0) + 1
        for (i, peak) in available.enumerated() where !claimed.contains(i) {
            out.append(ModeObservation(modeNumber: nextNumber, frequency: peak.frequency,
                                       amplitude: peak.power, at: time, temperature: temperature))
            nextNumber += 1
        }
        available = []

        return out.sorted { $0.modeNumber < $1.modeNumber }
    }

    /// The history of one mode, in chronological order.
    public static func history(of modeNumber: Int,
                               in observations: [ModeObservation]) -> [ModeObservation] {
        observations.filter { $0.modeNumber == modeNumber }.sorted { $0.at < $1.at }
    }
}

// MARK: - 28. Temperature normalisation

/// Algorithm 28 — temperature-frequency regression with outlier rejection.
///
/// This is the algorithm that makes the whole product defensible. A building's
/// stiffness genuinely changes with temperature — concrete expands, connections
/// tighten, and the measured frequency can move a few per cent between a cold
/// dawn and a hot afternoon. That is the same order as the change caused by real
/// damage. Without this correction the system would cry wolf every winter, and
/// after two false alarms nobody would believe the true one.
public struct TemperatureModel: Sendable, Equatable, Codable {
    /// Frequency change per °C.
    public var slope: Double
    public var intercept: Double
    public var r2: Double
    public var sampleCount: Int
    public var outliersRejected: Int
    public var temperatureRange: ClosedRange<Double>

    public init(slope: Double, intercept: Double, r2: Double, sampleCount: Int,
                outliersRejected: Int, temperatureRange: ClosedRange<Double>) {
        self.slope = slope; self.intercept = intercept; self.r2 = r2
        self.sampleCount = sampleCount; self.outliersRejected = outliersRejected
        self.temperatureRange = temperatureRange
    }

    /// Whether the fit is good enough to correct with. A weak fit is worse than
    /// no correction, because it adds noise while claiming to remove it.
    public var isReliable: Bool { sampleCount >= 12 && r2 >= 0.3 }

    /// Corrects a measured frequency to what it would have been at the reference
    /// temperature.
    public func normalise(frequency: Double, measuredAt temperature: Double,
                          referenceTemperature: Double) -> Double {
        guard isReliable else { return frequency }
        // Refuse to extrapolate far outside the observed range — the
        // relationship is only approximately linear.
        let clamped = Swift.min(Swift.max(temperature, temperatureRange.lowerBound - 5),
                                temperatureRange.upperBound + 5)
        return frequency - slope * (clamped - referenceTemperature)
    }

    public func normalise(period: Double, measuredAt temperature: Double,
                          referenceTemperature: Double) -> Double {
        guard period > 0 else { return period }
        let f = 1 / period
        let corrected = normalise(frequency: f, measuredAt: temperature,
                                  referenceTemperature: referenceTemperature)
        return corrected > 0 ? 1 / corrected : period
    }

    /// Plain-language summary for the assessment screen.
    public var explanation: String {
        guard isReliable else {
            return "Not enough matched temperature and frequency observations yet to build a "
                + "reliable correction (\(sampleCount) so far, \(outliersRejected) rejected). "
                + "Measurements are reported uncorrected."
        }
        let perDegree = abs(slope) * 1000
        let direction = slope < 0 ? "falls" : "rises"
        return "This building's frequency \(direction) by about "
            + "\(String(format: "%.1f", perDegree)) mHz per °C, fitted across "
            + "\(sampleCount) observations from "
            + "\(String(format: "%.0f", temperatureRange.lowerBound))°C to "
            + "\(String(format: "%.0f", temperatureRange.upperBound))°C "
            + "(R² = \(String(format: "%.2f", r2)); \(outliersRejected) outliers rejected)."
    }
}

public enum TemperatureNormalisation {

    /// Fits the model, rejecting outliers by a robust criterion.
    ///
    /// Ordinary least squares would let one bad scan — taken while a lift was
    /// running, or during an aftershock — tilt the whole relationship. Iterating
    /// with rejection at 2.5 median absolute deviations removes those without
    /// hand-tuning a threshold per building.
    public static func fit(_ observations: [ModeObservation],
                           rejectionSigmas: Double = 2.5,
                           iterations: Int = 3) -> TemperatureModel {
        let usable = observations.compactMap { obs -> (Double, Double)? in
            guard let t = obs.temperature, obs.frequency > 0 else { return nil }
            return (t, obs.frequency)
        }

        guard usable.count >= 4 else {
            return TemperatureModel(slope: 0, intercept: Stats.mean(usable.map(\.1)),
                                    r2: 0, sampleCount: usable.count, outliersRejected: 0,
                                    temperatureRange: 0...0)
        }

        var kept = usable
        var rejected = 0

        for _ in 0..<Swift.max(iterations, 1) {
            let fit = Stats.linearRegression(x: kept.map(\.0), y: kept.map(\.1))
            let residuals = kept.map { $0.1 - (fit.slope * $0.0 + fit.intercept) }
            let scale = Stats.mad(residuals)
            guard scale > 1e-12 else { break }

            let survivors = zip(kept, residuals).filter { abs($0.1) <= rejectionSigmas * scale }
                .map(\.0)
            let removed = kept.count - survivors.count
            guard removed > 0, survivors.count >= 4 else { break }
            rejected += removed
            kept = survivors
        }

        let final = Stats.linearRegression(x: kept.map(\.0), y: kept.map(\.1))
        let temps = kept.map(\.0)
        let range = (temps.min() ?? 0)...(Swift.max(temps.max() ?? 0, temps.min() ?? 0))

        return TemperatureModel(slope: final.slope, intercept: final.intercept,
                                r2: final.r2, sampleCount: kept.count,
                                outliersRejected: rejected, temperatureRange: range)
    }
}
