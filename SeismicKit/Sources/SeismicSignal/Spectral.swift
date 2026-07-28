import Foundation
import SeismicCore

// Algorithms 15–22. Everything that answers "at what frequency?", which is the
// question the whole product turns on: a building's period is its signature, and
// a change in it is damage.

// MARK: - 15. FFT

public struct Complex: Sendable, Equatable {
    public var re: Double
    public var im: Double
    public init(_ re: Double, _ im: Double = 0) { self.re = re; self.im = im }

    public var magnitude: Double { (re * re + im * im).squareRoot() }
    public var phase: Double { atan2(im, re) }
    public var magnitudeSquared: Double { re * re + im * im }

    public static func + (a: Complex, b: Complex) -> Complex { Complex(a.re + b.re, a.im + b.im) }
    public static func - (a: Complex, b: Complex) -> Complex { Complex(a.re - b.re, a.im - b.im) }
    public static func * (a: Complex, b: Complex) -> Complex {
        Complex(a.re * b.re - a.im * b.im, a.re * b.im + a.im * b.re)
    }
}

/// Algorithm 15 — iterative radix-2 Cooley-Tukey FFT.
///
/// Written out rather than taken from Accelerate for two reasons: it must run
/// identically in tests on any machine, and the whole point of this app is that
/// the maths is inspectable rather than a black box.
public enum FFT {

    public static func nextPowerOfTwo(_ n: Int) -> Int {
        guard n > 1 else { return 1 }
        return 1 << (Int.bitWidth - (n - 1).leadingZeroBitCount)
    }

    public static func isPowerOfTwo(_ n: Int) -> Bool { n > 0 && (n & (n - 1)) == 0 }

    /// In-place forward transform. `buffer.count` must be a power of two.
    public static func forward(_ buffer: inout [Complex]) {
        let n = buffer.count
        guard n > 1, isPowerOfTwo(n) else { return }

        // Bit-reversal permutation.
        var j = 0
        for i in 1..<n {
            var bit = n >> 1
            while j & bit != 0 {
                j ^= bit
                bit >>= 1
            }
            j |= bit
            if i < j { buffer.swapAt(i, j) }
        }

        // Butterflies, doubling the transform length each stage.
        var len = 2
        while len <= n {
            let angle = -2 * Double.pi / Double(len)
            let wlen = Complex(cos(angle), sin(angle))
            var i = 0
            while i < n {
                var w = Complex(1, 0)
                for k in 0..<(len / 2) {
                    let u = buffer[i + k]
                    let v = buffer[i + k + len / 2] * w
                    buffer[i + k] = u + v
                    buffer[i + k + len / 2] = u - v
                    w = w * wlen
                }
                i += len
            }
            len <<= 1
        }
    }

    public static func inverse(_ buffer: inout [Complex]) {
        let n = buffer.count
        guard n > 1, isPowerOfTwo(n) else { return }
        // Conjugate, forward transform, conjugate, scale.
        for i in 0..<n { buffer[i].im = -buffer[i].im }
        forward(&buffer)
        let scale = 1 / Double(n)
        for i in 0..<n {
            buffer[i].im = -buffer[i].im
            buffer[i].re *= scale
            buffer[i].im *= scale
        }
    }

    /// Real-input transform, zero-padded to the next power of two. Returns only
    /// the non-redundant half, which is all a real signal carries.
    public static func realForward(_ x: [Double]) -> [Complex] {
        guard !x.isEmpty else { return [] }
        let n = nextPowerOfTwo(x.count)
        var buffer = [Complex](repeating: Complex(0), count: n)
        for (i, v) in x.enumerated() { buffer[i] = Complex(v) }
        forward(&buffer)
        return Array(buffer[0...(n / 2)])
    }

    /// Single-sided amplitude spectrum, correctly scaled: a pure sine of
    /// amplitude A reads A at its bin, not A/2 and not A·N/2.
    public static func amplitudeSpectrum(_ x: [Double], sampleRate: Double,
                                         window: Window = .hann)
        -> (frequencies: [Double], amplitudes: [Double])
    {
        guard x.count > 1 else { return ([], []) }
        let windowed = window.apply(x)
        let gain = window.coherentGain(x.count)
        let n = nextPowerOfTwo(x.count)
        let spectrum = realForward(windowed)

        var amplitudes = [Double](repeating: 0, count: spectrum.count)
        var frequencies = [Double](repeating: 0, count: spectrum.count)
        for i in 0..<spectrum.count {
            frequencies[i] = Double(i) * sampleRate / Double(n)
            // Double everything but DC and Nyquist, which are not mirrored.
            let mirrorFactor = (i == 0 || i == spectrum.count - 1) ? 1.0 : 2.0
            amplitudes[i] = spectrum[i].magnitude * mirrorFactor
                / (Double(x.count) * Swift.max(gain, 1e-12))
        }
        return (frequencies, amplitudes)
    }
}

// MARK: - A spectrum, as a value

public struct PowerSpectrum: Sendable, Equatable {
    public var frequencies: [Double]
    public var power: [Double]
    public var sampleRate: Double
    /// Frequency spacing between bins — the resolution limit before
    /// interpolation.
    public var binWidth: Double { frequencies.count > 1 ? frequencies[1] - frequencies[0] : 0 }

    public init(frequencies: [Double], power: [Double], sampleRate: Double) {
        self.frequencies = frequencies
        self.power = power
        self.sampleRate = sampleRate
    }

    public var isEmpty: Bool { frequencies.isEmpty }

    /// Frequency of the largest bin, without interpolation.
    public var peakFrequency: Double {
        guard let idx = power.indices.max(by: { power[$0] < power[$1] }) else { return 0 }
        return frequencies[idx]
    }

    public func power(at frequency: Double) -> Double {
        Stats.interpolate(x: frequency, xs: frequencies, ys: power)
    }

    /// Restricts to a band — used everywhere, because the building's first mode
    /// is the only part of the spectrum most screens care about.
    public func band(_ range: ClosedRange<Double>) -> PowerSpectrum {
        var f: [Double] = [], p: [Double] = []
        for (i, freq) in frequencies.enumerated() where range.contains(freq) {
            f.append(freq); p.append(power[i])
        }
        return PowerSpectrum(frequencies: f, power: p, sampleRate: sampleRate)
    }
}

public enum Spectrum {

    /// Algorithm 16 — Welch's method.
    ///
    /// A single FFT of a noisy record gives a spectrum so ragged that a peak is
    /// hard to locate. Welch splits the record into overlapping segments,
    /// transforms each, and averages the powers. The variance falls with the
    /// number of segments, and the building's mode rises cleanly out of it.
    public static func welch(_ w: Waveform,
                             segmentSeconds: Double = 20,
                             overlap: Double = 0.5,
                             window: Window = .hann) -> PowerSpectrum {
        guard w.count > 8 else { return PowerSpectrum(frequencies: [], power: [], sampleRate: w.sampleRate) }

        var segmentLength = Int(segmentSeconds * w.sampleRate)
        segmentLength = Swift.min(Swift.max(segmentLength, 16), w.count)
        segmentLength = FFT.nextPowerOfTwo(segmentLength)
        if segmentLength > w.count { segmentLength = FFT.nextPowerOfTwo(w.count) / 2 }
        segmentLength = Swift.max(segmentLength, 16)

        let detrended = Detrend.linear(w.samples)
        var segments = Framing.frames(detrended, length: segmentLength, overlap: overlap)
        if segments.isEmpty {
            // Record shorter than one segment: pad it out rather than return
            // nothing. A short record still deserves an answer, just a blurrier one.
            var padded = detrended
            padded.append(contentsOf: [Double](repeating: 0, count: segmentLength - detrended.count))
            segments = [padded]
        }

        let coefficients = window.coefficients(segmentLength)
        // Scaling to a true one-sided power spectral density, in units²/Hz.
        let windowPower = coefficients.reduce(0) { $0 + $1 * $1 }
        let scale = 1 / (w.sampleRate * windowPower)

        let bins = segmentLength / 2 + 1
        var accumulator = [Double](repeating: 0, count: bins)

        for segment in segments {
            let detrendedSegment = Detrend.linear(segment)
            var buffer = [Complex](repeating: Complex(0), count: segmentLength)
            for i in 0..<segmentLength { buffer[i] = Complex(detrendedSegment[i] * coefficients[i]) }
            FFT.forward(&buffer)
            for k in 0..<bins {
                let mirror = (k == 0 || k == bins - 1) ? 1.0 : 2.0
                accumulator[k] += buffer[k].magnitudeSquared * scale * mirror
            }
        }

        let count = Double(segments.count)
        let power = accumulator.map { $0 / count }
        let frequencies = (0..<bins).map { Double($0) * w.sampleRate / Double(segmentLength) }
        return PowerSpectrum(frequencies: frequencies, power: power, sampleRate: w.sampleRate)
    }

    /// A single periodogram — the un-averaged case, for short transient records
    /// where splitting into segments would leave nothing.
    public static func periodogram(_ w: Waveform, window: Window = .hann) -> PowerSpectrum {
        welch(w, segmentSeconds: w.duration, overlap: 0, window: window)
    }

    /// Algorithm 17 — Konno-Ohmachi smoothing.
    ///
    /// Ordinary moving-average smoothing is wrong for a spectrum: it smears a
    /// 0.5 Hz peak and a 20 Hz peak by the same absolute amount, which destroys
    /// the low end and barely touches the high. Konno-Ohmachi smooths with a
    /// window of constant width in log-frequency, which is how spectra are
    /// actually read.
    ///
    /// - Parameter bandwidth: `b` in the standard formulation. 40 is the
    ///   conventional value; lower is smoother.
    public static func konnoOhmachi(_ spectrum: PowerSpectrum,
                                    bandwidth: Double = 40) -> PowerSpectrum {
        guard spectrum.frequencies.count > 2, bandwidth > 0 else { return spectrum }
        let f = spectrum.frequencies
        let p = spectrum.power
        var out = [Double](repeating: 0, count: p.count)

        for i in 0..<f.count {
            let fc = f[i]
            guard fc > 0 else { out[i] = p[i]; continue }

            var numerator = 0.0, denominator = 0.0
            for j in 0..<f.count {
                guard f[j] > 0 else { continue }
                let ratio = f[j] / fc
                // The window falls away fast; skipping the far tail is a large
                // speedup and changes nothing visible.
                guard ratio > 0.1, ratio < 10 else { continue }
                let x = bandwidth * log10(ratio)
                let weight: Double
                if abs(x) < 1e-9 {
                    weight = 1
                } else {
                    let s = sin(x) / x
                    weight = s * s * s * s
                }
                numerator += p[j] * weight
                denominator += weight
            }
            out[i] = denominator > 0 ? numerator / denominator : p[i]
        }
        return PowerSpectrum(frequencies: f, power: out, sampleRate: spectrum.sampleRate)
    }

    /// Spectral centroid, in Hz. Used by the false-trigger classifier as a
    /// one-number summary of "how high-pitched was this?".
    public static func centroid(_ w: Waveform) -> Double {
        let spectrum = welch(w, segmentSeconds: Swift.min(w.duration, 4), overlap: 0.5)
        guard !spectrum.isEmpty else { return 0 }
        var num = 0.0, den = 0.0
        for (i, f) in spectrum.frequencies.enumerated() {
            num += f * spectrum.power[i]
            den += spectrum.power[i]
        }
        return den > 1e-30 ? num / den : 0
    }
}

// MARK: - 18 & 19. Peak picking and sub-bin interpolation

public struct SpectralPeak: Sendable, Equatable, Identifiable, Comparable {
    public var id: Int { binIndex }
    public var binIndex: Int
    /// Interpolated frequency, finer than the bin spacing.
    public var frequency: Double
    public var power: Double
    /// How far this peak rises above the surrounding valleys.
    public var prominence: Double
    /// Estimated width at half power, for the damping calculation.
    public var halfPowerBandwidth: Double

    public var period: Double { frequency > 0 ? 1 / frequency : 0 }

    public static func < (a: Self, b: Self) -> Bool { a.power < b.power }

    public init(binIndex: Int, frequency: Double, power: Double,
                prominence: Double, halfPowerBandwidth: Double) {
        self.binIndex = binIndex; self.frequency = frequency; self.power = power
        self.prominence = prominence; self.halfPowerBandwidth = halfPowerBandwidth
    }
}

public enum PeakPicking {

    /// Algorithm 18 — peak picking with prominence and minimum separation.
    ///
    /// Every local maximum is not a mode. Prominence — how far a peak stands
    /// above the highest valley connecting it to a taller peak — separates a
    /// genuine resonance from a ripple on the shoulder of one.
    public static func peaks(in spectrum: PowerSpectrum,
                             minimumProminence: Double = 0.1,
                             minimumSeparationHz: Double = 0.15,
                             band: ClosedRange<Double>? = nil,
                             limit: Int = 8) -> [SpectralPeak] {
        let s = band.map { spectrum.band($0) } ?? spectrum
        let p = s.power
        guard p.count > 4 else { return [] }

        let maxPower = p.max() ?? 0
        guard maxPower > 0 else { return [] }

        var candidates: [SpectralPeak] = []
        for i in 1..<(p.count - 1) where p[i] > p[i - 1] && p[i] >= p[i + 1] {
            let prominence = self.prominence(of: i, in: p) / maxPower
            guard prominence >= minimumProminence else { continue }

            // Algorithm 19 — parabolic interpolation through the three points
            // around the peak. The FFT bin spacing is often 0.05 Hz while the
            // shift being measured is 0.02 Hz, so without this the whole
            // measurement is quantised into uselessness.
            let refined = parabolicRefine(p[i - 1], p[i], p[i + 1])
            let frequency = s.frequencies[i] + refined.offset * s.binWidth
            let power = refined.value * p[i]

            candidates.append(SpectralPeak(
                binIndex: i, frequency: frequency, power: power,
                prominence: prominence,
                halfPowerBandwidth: halfPowerWidth(around: i, in: s)))
        }

        // Enforce separation, keeping the strongest of any cluster.
        let sorted = candidates.sorted { $0.power > $1.power }
        var kept: [SpectralPeak] = []
        for c in sorted {
            if kept.allSatisfy({ abs($0.frequency - c.frequency) >= minimumSeparationHz }) {
                kept.append(c)
            }
            if kept.count >= limit { break }
        }
        return kept.sorted { $0.frequency < $1.frequency }
    }

    /// Algorithm 19 — parabolic sub-bin interpolation.
    ///
    /// Fits a parabola through the peak bin and its two neighbours and returns
    /// the vertex. Accurate to a small fraction of a bin for a windowed peak.
    public static func parabolicRefine(_ left: Double, _ centre: Double, _ right: Double)
        -> (offset: Double, value: Double)
    {
        let denom = left - 2 * centre + right
        guard abs(denom) > 1e-30 else { return (0, 1) }
        let offset = 0.5 * (left - right) / denom
        // Reject a fit that lands outside the neighbouring bins — that means the
        // three points were not a peak at all.
        guard abs(offset) <= 1 else { return (0, 1) }
        let value = 1 - 0.25 * (left - right) * offset / Swift.max(centre, 1e-30)
        return (offset, Swift.max(value, 0.5))
    }

    /// Topographic prominence, computed by walking outwards until the signal
    /// rises above the peak on each side.
    public static func prominence(of index: Int, in p: [Double]) -> Double {
        guard index > 0, index < p.count - 1 else { return 0 }
        let height = p[index]

        var leftMin = height
        var i = index - 1
        while i >= 0 {
            if p[i] > height { break }
            leftMin = Swift.min(leftMin, p[i])
            i -= 1
        }

        var rightMin = height
        var j = index + 1
        while j < p.count {
            if p[j] > height { break }
            rightMin = Swift.min(rightMin, p[j])
            j += 1
        }

        return height - Swift.max(leftMin, rightMin)
    }

    /// Width of the peak where power falls to half. Feeds the half-power
    /// bandwidth damping estimate.
    public static func halfPowerWidth(around index: Int, in s: PowerSpectrum) -> Double {
        let p = s.power
        guard index > 0, index < p.count - 1 else { return 0 }
        let half = p[index] / 2

        var lower = s.frequencies[index]
        var i = index
        while i > 0 {
            if p[i] <= half {
                // Interpolate between the straddling bins for a smooth answer.
                let t = (half - p[i]) / Swift.max(p[i + 1] - p[i], 1e-30)
                lower = s.frequencies[i] + t * s.binWidth
                break
            }
            i -= 1
        }

        var upper = s.frequencies[index]
        var j = index
        while j < p.count - 1 {
            if p[j] <= half {
                let t = (half - p[j]) / Swift.max(p[j - 1] - p[j], 1e-30)
                upper = s.frequencies[j] - t * s.binWidth
                break
            }
            j += 1
        }

        return Swift.max(upper - lower, 0)
    }
}

// MARK: - 20 & 21. Independent period cross-checks

public enum PeriodEstimation {

    /// Algorithm 20 — autocorrelation period estimate.
    ///
    /// Completely independent of the FFT: it asks "how far do I have to shift
    /// this signal before it looks like itself again?". When it agrees with the
    /// spectral estimate, the measurement is trustworthy. When it does not, the
    /// building is being driven by something with more than one frequency in it
    /// and the user is told so rather than shown a confident wrong number.
    public static func autocorrelation(_ w: Waveform,
                                       searchBand: ClosedRange<Double> = 0.05...10)
        -> (period: Double, confidence: Double)?
    {
        guard w.count > 32 else { return nil }
        let x = Detrend.linear(w.samples)

        // Autocorrelation via FFT: O(n log n) instead of O(n²), which matters
        // when this runs on a 60-second record at 200 Hz.
        let n = FFT.nextPowerOfTwo(x.count * 2)
        var buffer = [Complex](repeating: Complex(0), count: n)
        for (i, v) in x.enumerated() { buffer[i] = Complex(v) }
        FFT.forward(&buffer)
        for i in 0..<n { buffer[i] = Complex(buffer[i].magnitudeSquared, 0) }
        FFT.inverse(&buffer)

        let zeroLag = buffer[0].re
        guard zeroLag > 1e-30 else { return nil }
        let correlation = (0..<Swift.min(x.count, n / 2)).map { buffer[$0].re / zeroLag }

        let minLag = Swift.max(Int(searchBand.lowerBound * w.sampleRate), 2)
        let maxLag = Swift.min(Int(searchBand.upperBound * w.sampleRate), correlation.count - 2)
        guard maxLag > minLag + 2 else { return nil }

        // First significant maximum after the zero-lag spike.
        var bestLag = minLag
        var bestValue = -Double.infinity
        for lag in minLag...maxLag
        where correlation[lag] > correlation[lag - 1] && correlation[lag] >= correlation[lag + 1] {
            if correlation[lag] > bestValue { bestValue = correlation[lag]; bestLag = lag }
        }
        guard bestValue > 0.1 else { return nil }

        let refined = PeakPicking.parabolicRefine(correlation[bestLag - 1],
                                                  correlation[bestLag],
                                                  correlation[bestLag + 1])
        let period = (Double(bestLag) + refined.offset) / w.sampleRate
        return (period, Swift.min(Swift.max(bestValue, 0), 1))
    }

    /// Algorithm 21 — zero-crossing rate estimate.
    ///
    /// The cheapest possible frequency estimate: count sign changes. Useless on
    /// a broadband signal, but on a narrowband one — which a building in free
    /// decay very much is — it is a genuinely independent third opinion, and it
    /// costs one comparison per sample so the node can run it continuously.
    public static func zeroCrossing(_ w: Waveform) -> (period: Double, confidence: Double)? {
        guard w.count > 8 else { return nil }
        let x = Detrend.linear(w.samples)

        var crossings: [Double] = []
        for i in 1..<x.count where (x[i - 1] < 0) != (x[i] < 0) {
            // Linear interpolation to the sub-sample crossing time.
            let t = abs(x[i - 1]) / Swift.max(abs(x[i - 1]) + abs(x[i]), 1e-30)
            crossings.append((Double(i - 1) + t) / w.sampleRate)
        }
        guard crossings.count >= 3 else { return nil }

        // Two crossings per cycle.
        var intervals: [Double] = []
        for i in 1..<crossings.count { intervals.append((crossings[i] - crossings[i - 1]) * 2) }
        guard !intervals.isEmpty else { return nil }

        let period = Stats.median(intervals)
        // Confidence from consistency: a narrowband signal gives near-identical
        // intervals, a broadband one gives scatter.
        let spread = Stats.mad(intervals)
        let confidence = period > 0 ? Swift.max(0, 1 - spread / period) : 0
        return (period, Swift.min(confidence, 1))
    }

    /// The consolidated answer: three independent estimates, cross-checked.
    ///
    /// This is the number the whole assessment rests on, so it is never produced
    /// by one method alone.
    public struct CrossCheckedPeriod: Sendable, Equatable {
        public var spectral: Double?
        public var autocorrelation: Double?
        public var zeroCrossing: Double?
        public var consensus: Double?
        public var agreement: Double          // 0…1
        public var explanation: String

        public var methodsAgreeing: Int {
            [spectral, autocorrelation, zeroCrossing].compactMap { $0 }.count
        }

        public init(spectral: Double?, autocorrelation: Double?, zeroCrossing: Double?,
                    consensus: Double?, agreement: Double, explanation: String) {
            self.spectral = spectral
            self.autocorrelation = autocorrelation
            self.zeroCrossing = zeroCrossing
            self.consensus = consensus
            self.agreement = agreement
            self.explanation = explanation
        }
    }

    public static func crossChecked(_ w: Waveform,
                                    band: ClosedRange<Double> = 0.1...10) -> CrossCheckedPeriod {
        var spectralPeriod: Double?
        let spectrum = Spectrum.konnoOhmachi(
            Spectrum.welch(w, segmentSeconds: Swift.min(w.duration / 2, 30)), bandwidth: 40)
        let frequencyBand = (1 / band.upperBound)...(1 / band.lowerBound)
        if let top = PeakPicking.peaks(in: spectrum, minimumProminence: 0.05,
                                       band: frequencyBand).max(by: { $0.power < $1.power }),
           top.frequency > 0 {
            spectralPeriod = 1 / top.frequency
        }

        let auto = autocorrelation(w, searchBand: band)
        let zero = zeroCrossing(w)

        let estimates = [spectralPeriod, auto?.period, zero?.period].compactMap { $0 }
            .filter { band.contains($0) }
        guard !estimates.isEmpty else {
            return CrossCheckedPeriod(spectral: spectralPeriod,
                                      autocorrelation: auto?.period,
                                      zeroCrossing: zero?.period,
                                      consensus: nil, agreement: 0,
                                      explanation: "No method found a period in the expected band. "
                                        + "The record may be too short or too quiet to measure.")
        }

        // The median is robust to one method being fooled; the spread tells us
        // how much to trust the result.
        let consensus = Stats.median(estimates)
        let spread = estimates.count > 1
            ? (estimates.max()! - estimates.min()!) / consensus : 0
        let agreement = Swift.max(0, 1 - spread * 2)

        let explanation: String
        switch (estimates.count, agreement) {
        case (1, _):
            explanation = "Only one method could measure a period, so this figure is unconfirmed."
        case (_, 0.85...):
            explanation = "All methods agree to within \(String(format: "%.1f", spread * 100))%. "
                + "This measurement is solid."
        case (_, 0.5..<0.85):
            explanation = "Methods differ by \(String(format: "%.1f", spread * 100))%. "
                + "Usable, but treat small changes with caution."
        default:
            explanation = "Methods disagree substantially. The building is probably being driven "
                + "by more than one frequency, or the record is too noisy."
        }

        return CrossCheckedPeriod(spectral: spectralPeriod,
                                  autocorrelation: auto?.period,
                                  zeroCrossing: zero?.period,
                                  consensus: consensus, agreement: agreement,
                                  explanation: explanation)
    }
}

// MARK: - 22. Short-time Fourier transform

/// A time-frequency surface. The waterfall view renders this directly.
public struct Spectrogram: Sendable, Equatable {
    public var times: [Double]
    public var frequencies: [Double]
    /// `magnitudes[timeIndex][frequencyIndex]`
    public var magnitudes: [[Double]]
    public var maximum: Double

    public init(times: [Double], frequencies: [Double], magnitudes: [[Double]]) {
        self.times = times
        self.frequencies = frequencies
        self.magnitudes = magnitudes
        self.maximum = magnitudes.flatMap { $0 }.max() ?? 0
    }

    public var isEmpty: Bool { times.isEmpty || frequencies.isEmpty }

    /// Normalised to 0…1 in decibels, which is how it should be coloured — a
    /// linear colour map hides everything but the single loudest instant.
    public func normalisedDecibels(floor: Double = -60) -> [[Double]] {
        guard maximum > 0 else { return magnitudes }
        return magnitudes.map { row in
            row.map { v in
                let db = 20 * log10(Swift.max(v, 1e-12) / maximum)
                return Swift.min(Swift.max((db - floor) / -floor, 0), 1)
            }
        }
    }

    /// The frequency ridge — the dominant frequency at each instant. This is how
    /// the app shows a building's period lengthening *during* an event, which is
    /// the most striking single visualisation in the product.
    public var dominantFrequencyRidge: [(time: Double, frequency: Double)] {
        zip(times, magnitudes).map { time, row in
            guard let idx = row.indices.max(by: { row[$0] < row[$1] }) else { return (time, 0) }
            return (time, frequencies[idx])
        }
    }
}

public enum STFT {

    /// Algorithm 22 — short-time Fourier transform.
    ///
    /// The building's period is not one number during an earthquake; it changes
    /// as the structure yields. A single spectrum averages that away. The STFT
    /// keeps it, and the ridge it produces is direct visual evidence of damage
    /// happening in real time.
    public static func compute(_ w: Waveform,
                               windowSeconds: Double = 4,
                               overlap: Double = 0.75,
                               window: Window = .hann,
                               maximumFrequency: Double? = nil) -> Spectrogram {
        guard w.count > 16 else { return Spectrogram(times: [], frequencies: [], magnitudes: []) }

        var length = FFT.nextPowerOfTwo(Int(windowSeconds * w.sampleRate))
        length = Swift.min(Swift.max(length, 32), FFT.nextPowerOfTwo(w.count))
        if length > w.count { length = Swift.max(FFT.nextPowerOfTwo(w.count) / 2, 32) }
        guard w.count >= length else { return Spectrogram(times: [], frequencies: [], magnitudes: []) }

        let hop = Swift.max(Int(Double(length) * (1 - Swift.min(Swift.max(overlap, 0), 0.95))), 1)
        let coefficients = window.coefficients(length)
        let detrended = Detrend.linear(w.samples)

        let maxF = maximumFrequency ?? (w.sampleRate / 2)
        let allBins = length / 2 + 1
        let binCount = Swift.max(Swift.min(Int(maxF / (w.sampleRate / Double(length))) + 1, allBins), 2)

        var times: [Double] = []
        var rows: [[Double]] = []
        var start = 0
        while start + length <= detrended.count {
            var buffer = [Complex](repeating: Complex(0), count: length)
            for i in 0..<length { buffer[i] = Complex(detrended[start + i] * coefficients[i]) }
            FFT.forward(&buffer)
            rows.append((0..<binCount).map { buffer[$0].magnitude / Double(length) })
            times.append(Double(start + length / 2) / w.sampleRate)   // window centre
            start += hop
        }

        let frequencies = (0..<binCount).map { Double($0) * w.sampleRate / Double(length) }
        return Spectrogram(times: times, frequencies: frequencies, magnitudes: rows)
    }
}
