import Foundation
import SeismicCore

// MARK: - 68. Sine multitaper spectral estimate

/// Algorithm 68 — the sine multitaper spectral estimate.
///
/// Welch trades resolution for variance by cutting the record into segments and
/// averaging them: eight segments give a spectrum eight times smoother and a
/// frequency resolution eight times worse. For this app that trade is painful
/// in both directions. The signal being tracked is a period shift of a few per
/// cent, so resolution cannot be given away; and the peak has to be found in
/// ambient noise, so variance cannot be either.
///
/// Multitaper refuses the trade. It applies several *orthogonal* tapers to the
/// **whole** record rather than one taper to each of several pieces. Each taper
/// produces an estimate that is nearly independent of the others — that is what
/// orthogonality buys — so averaging them reduces variance in the same way
/// segmenting does, while every estimate still sees the full record and keeps
/// the full frequency resolution.
///
/// The tapers here are the sine tapers of Riedel and Sidorenko rather than the
/// Slepian sequences of Thomson's original. Slepians are optimal but require
/// solving an eigenproblem for a matrix the length of the record; the sine
/// tapers have a closed form, come within a fraction of a decibel of optimal
/// for the small taper counts used here, and cost one `sin` per sample.
public enum Multitaper {

    /// The k-th sine taper: √(2/(N+1))·sin(π(k+1)(i+1)/(N+1)).
    public static func taper(_ k: Int, length n: Int) -> [Double] {
        guard n > 0 else { return [] }
        let scale = (2 / Double(n + 1)).squareRoot()
        return (0..<n).map { i in
            scale * sin(Double.pi * Double(k + 1) * Double(i + 1) / Double(n + 1))
        }
    }

    /// - Parameter tapers: how many to average. More tapers means less variance
    ///   and a slightly wider effective bandwidth; three to five is the usual
    ///   range and five is a good default for a modal peak.
    public static func spectrum(_ w: Waveform, tapers: Int = 5) -> PowerSpectrum {
        let count = min(max(tapers, 1), 12)
        let size = FFT.nextPowerOfTwo(w.samples.count)
        guard w.samples.count >= 8 else {
            return PowerSpectrum(frequencies: [], power: [], sampleRate: w.sampleRate)
        }

        let bins = size / 2
        var accumulated = [Double](repeating: 0, count: bins)

        for k in 0..<count {
            let taper = Self.taper(k, length: w.samples.count)
            var block = [Double](repeating: 0, count: size)
            for i in 0..<w.samples.count { block[i] = w.samples[i] * taper[i] }
            let transform = FFT.realForward(block)
            for bin in 0..<bins {
                let value = transform[bin]
                accumulated[bin] += value.re * value.re + value.im * value.im
            }
        }

        // The tapers are already unit-energy, so the only normalisation left is
        // the average over tapers and the conversion to a density.
        let scale = 1 / (Double(count) * w.sampleRate)
        let frequencies = (0..<bins).map { Double($0) * w.sampleRate / Double(size) }
        return PowerSpectrum(frequencies: frequencies,
                             power: accumulated.map { $0 * scale },
                             sampleRate: w.sampleRate)
    }

    /// Algorithm 69 — Thomson's harmonic F-test for a pure line component.
    ///
    /// This is the diagnostic that only multitaper can offer, and it earns its
    /// place here for a specific reason. A building's resonance is *narrowband
    /// but random* — it is the structure filtering broadband noise, so it has a
    /// finite bandwidth set by its damping. Mains hum, a lift motor and a
    /// vibrating transformer are *pure lines*: deterministic sinusoids with no
    /// bandwidth at all. On a spectrum they look alike, and this app has to
    /// tell them apart, because a fifty-hertz line picked up as a mode would
    /// be tracked for months as a building whose period never changes.
    ///
    /// The test works because the several tapers give several nearly
    /// independent looks at the same frequency. It fits a single complex
    /// amplitude to those looks and asks how much of the variance that one
    /// number explains. A deterministic sinusoid explains nearly all of it and
    /// F is large; a random narrowband process explains little and F sits near
    /// its null distribution.
    ///
    /// - Returns: the F statistic per bin. Values above roughly ten are strong
    ///   evidence of a deterministic line at five tapers.
    public static func lineTest(_ w: Waveform, tapers: Int = 5) -> [Double] {
        let count = min(max(tapers, 3), 12)
        let n = w.samples.count
        let size = FFT.nextPowerOfTwo(n)
        guard n >= 16 else { return [] }
        let bins = size / 2

        // The eigencoefficients, and each taper's DC sum — the weight with
        // which it sees a constant amplitude.
        var coefficients: [[Complex]] = []
        var dcSums = [Double](repeating: 0, count: count)
        for k in 0..<count {
            let taper = Self.taper(k, length: n)
            dcSums[k] = taper.reduce(0, +)
            var block = [Double](repeating: 0, count: size)
            for i in 0..<n { block[i] = w.samples[i] * taper[i] }
            coefficients.append(FFT.realForward(block))
        }

        // Odd sine tapers are antisymmetric, so their DC sum vanishes and they
        // carry no information about a constant amplitude. That is a property
        // of the tapers rather than a problem: the even ones do the estimating
        // and the odd ones supply the residual the test is measured against.
        let weightEnergy = dcSums.reduce(0) { $0 + $1 * $1 }
        guard weightEnergy > 1e-18 else { return [Double](repeating: 0, count: bins) }

        return (0..<bins).map { bin in
            // Least-squares complex amplitude of a line at this frequency.
            var muRe = 0.0, muIm = 0.0
            for k in 0..<count {
                muRe += dcSums[k] * coefficients[k][bin].re
                muIm += dcSums[k] * coefficients[k][bin].im
            }
            muRe /= weightEnergy
            muIm /= weightEnergy

            // Residual after removing that line from every taper.
            var residual = 0.0
            for k in 0..<count {
                let re = coefficients[k][bin].re - muRe * dcSums[k]
                let im = coefficients[k][bin].im - muIm * dcSums[k]
                residual += re * re + im * im
            }
            guard residual > 1e-300 else { return 0 }

            let explained = (muRe * muRe + muIm * muIm) * weightEnergy
            return Double(count - 1) * explained / residual
        }
    }
}

// MARK: - 70. Morlet wavelet ridge

/// Algorithm 70 — continuous Morlet wavelet transform with ridge extraction.
///
/// The spectrogram this app already draws answers "what frequencies were
/// present, roughly when". It cannot answer "what was the building's period at
/// 4.2 seconds into the shaking", because a spectrogram has one window length
/// and therefore one resolution: short enough to time the change and it cannot
/// resolve the frequency, long enough to resolve the frequency and it has
/// smeared the change away.
///
/// A wavelet transform uses a window whose length scales with the frequency it
/// is examining — many cycles of a slow oscillation, few of a fast one — so it
/// keeps a constant number of cycles at every scale. Following the ridge of
/// maximum energy through the resulting time-scale plane gives the building's
/// instantaneous period, sample by sample, through the event.
///
/// That is the measurement the whole product is about, made *during* the
/// earthquake rather than before and after it. A building that softens as it is
/// damaged shows the ridge sliding downwards mid-record, and the moment it
/// slides is the moment the damage happened.
public enum WaveletRidge {

    public struct Result: Sendable, Equatable {
        /// Seconds from the start of the record.
        public var times: [Double]
        /// The instantaneous frequency at each time, Hz.
        public var frequencies: [Double]
        /// Energy on the ridge, used to mask the parts where there is nothing
        /// to follow.
        public var amplitudes: [Double]

        public init(times: [Double], frequencies: [Double], amplitudes: [Double]) {
            self.times = times
            self.frequencies = frequencies
            self.amplitudes = amplitudes
        }

        /// Fractional change in period from the first tenth of the record to
        /// the last, over the samples where the ridge was actually strong.
        ///
        /// Positive means the period lengthened — the building softened. Nil
        /// when there was never a ridge worth following, which is the honest
        /// answer for a record that is all noise.
        public var periodChange: Double? {
            let threshold = (amplitudes.max() ?? 0) * 0.25
            let strong = zip(frequencies, amplitudes)
                .enumerated()
                .filter { $0.element.1 >= threshold && $0.element.0 > 0 }
            guard strong.count >= 8 else { return nil }
            let take = max(strong.count / 10, 3)
            let early = Stats.mean(strong.prefix(take).map { 1 / $0.element.0 })
            let late = Stats.mean(strong.suffix(take).map { 1 / $0.element.0 })
            guard early > 0 else { return nil }
            return (late - early) / early
        }
    }

    /// - Parameters:
    ///   - band: the frequency range to search. Narrow it to the building's own
    ///     band and the ridge cannot wander off onto a harmonic.
    ///   - voices: scales per octave. More is smoother and slower.
    ///   - cycles: the Morlet's central parameter, in cycles. Six is the
    ///     conventional value and balances time against frequency resolution.
    public static func run(_ w: Waveform, band: ClosedRange<Double>,
                           voices: Int = 12, cycles: Double = 6,
                           timeStep: Int = 8) -> Result? {
        let n = w.samples.count
        guard n >= 64, band.lowerBound > 0, band.upperBound > band.lowerBound,
              band.upperBound < w.sampleRate / 2 else { return nil }

        // Logarithmically spaced scales, which is how a wavelet transform is
        // meant to be sampled — the transform is scale-invariant, so linear
        // spacing wastes most of its resolution at the top.
        let octaves = Foundation.log2(band.upperBound / band.lowerBound)
        let scaleCount = max(Int(octaves * Double(voices)), 4)
        let frequencies = (0..<scaleCount).map { i in
            band.lowerBound * Foundation.pow(2, octaves * Double(i) / Double(scaleCount - 1))
        }

        let step = max(timeStep, 1)
        let sampleTimes = stride(from: 0, to: n, by: step).map { $0 }

        var ridgeFrequency = [Double](repeating: 0, count: sampleTimes.count)
        var ridgeAmplitude = [Double](repeating: 0, count: sampleTimes.count)

        // Convolve directly rather than through the FFT. The kernels are short
        // — a few hundred samples at the lowest frequency of a building band —
        // and doing it here keeps the code readable at a cost that does not
        // matter for a measurement taken once per event.
        for frequency in frequencies {
            let sigma = cycles / (2 * Double.pi * frequency)
            let half = Int((3 * sigma * w.sampleRate).rounded())
            guard half >= 2, half < n else { continue }

            // The Morlet kernel, pre-computed once per scale.
            var kernelReal = [Double](repeating: 0, count: 2 * half + 1)
            var kernelImaginary = [Double](repeating: 0, count: 2 * half + 1)
            let normalisation = 1 / (sigma * (2 * Double.pi).squareRoot())
            for k in -half...half {
                let t = Double(k) / w.sampleRate
                let envelope = normalisation * exp(-t * t / (2 * sigma * sigma))
                kernelReal[k + half] = envelope * cos(2 * Double.pi * frequency * t)
                kernelImaginary[k + half] = envelope * sin(2 * Double.pi * frequency * t)
            }

            for (index, centre) in sampleTimes.enumerated() {
                var real = 0.0, imaginary = 0.0
                let from = max(centre - half, 0)
                let to = min(centre + half, n - 1)
                guard to > from else { continue }
                for i in from...to {
                    let k = i - centre + half
                    real += w.samples[i] * kernelReal[k]
                    imaginary += w.samples[i] * kernelImaginary[k]
                }
                // Scale normalisation, so a slow oscillation is not favoured
                // simply for occupying a longer kernel.
                let magnitude = (real * real + imaginary * imaginary).squareRoot()
                             / frequency.squareRoot()
                if magnitude > ridgeAmplitude[index] {
                    ridgeAmplitude[index] = magnitude
                    ridgeFrequency[index] = frequency
                }
            }
        }

        return Result(times: sampleTimes.map { Double($0) / w.sampleRate },
                      frequencies: ridgeFrequency,
                      amplitudes: ridgeAmplitude)
    }
}

// MARK: - 71. Empirical mode decomposition

/// Algorithm 71 — empirical mode decomposition.
///
/// Every other decomposition in this app assumes a basis before it looks at the
/// data: the Fourier transform assumes sinusoids, the wavelet transform assumes
/// scaled copies of one mother wavelet. Both are fine for a building swaying
/// steadily and both distort a building that is changing, because a signal
/// whose frequency moves has to be represented as a sum of things whose
/// frequencies do not.
///
/// EMD assumes nothing. It sifts the signal into intrinsic mode functions
/// derived from the data's own extrema: find every maximum, find every minimum,
/// draw an envelope through each, subtract the mean of the two, and repeat
/// until what is left oscillates about zero. What comes out is the fastest
/// oscillation present, whatever that turns out to be; subtract it and repeat
/// for the next.
///
/// For this app it separates the building's sway from the traffic rumble
/// underneath it and the electrical hash on top, without anyone having to say
/// in advance what frequency any of them is at — which matters because the
/// answer changes from building to building and is the thing being measured.
public enum EmpiricalModeDecomposition {

    /// - Parameters:
    ///   - maximumModes: how many intrinsic modes to extract before stopping.
    ///   - siftLimit: iterations of the sifting loop per mode. The standard
    ///     stopping rule is a small change between sifts; a hard cap on top of
    ///     it guarantees termination on pathological input, which real sensor
    ///     data occasionally is.
    public static func decompose(_ signal: [Double], maximumModes: Int = 6,
                                 siftLimit: Int = 40) -> (modes: [[Double]],
                                                          residual: [Double]) {
        var residual = signal
        var modes: [[Double]] = []
        guard signal.count >= 8 else { return ([], signal) }

        for _ in 0..<maximumModes {
            // Fewer than three extrema either way means what is left is a trend,
            // not an oscillation, and there is nothing more to extract.
            guard countExtrema(residual).maxima >= 3,
                  countExtrema(residual).minima >= 3 else { break }

            var candidate = residual
            for _ in 0..<siftLimit {
                guard let upper = envelope(candidate, maxima: true),
                      let lower = envelope(candidate, maxima: false) else { break }
                let mean = zip(upper, lower).map { ($0 + $1) / 2 }
                let next = zip(candidate, mean).map(-)

                // Cauchy-type stopping criterion: stop when sifting stops
                // changing the candidate.
                let change = zip(candidate, next).reduce(0.0) { $0 + ($1.0 - $1.1) * ($1.0 - $1.1) }
                let energy = candidate.reduce(0.0) { $0 + $1 * $1 }
                candidate = next
                if energy > 0, change / energy < 1e-4 { break }
            }

            modes.append(candidate)
            residual = zip(residual, candidate).map(-)
        }
        return (modes, residual)
    }

    /// A cubic-free envelope through the extrema.
    ///
    /// Linear interpolation between extrema rather than the cubic spline of the
    /// original formulation. A spline overshoots between widely spaced extrema
    /// and the overshoot is indistinguishable from signal, which in a method
    /// that then *subtracts* the envelope means inventing oscillation. Linear
    /// under-fits slightly and never invents.
    static func envelope(_ signal: [Double], maxima: Bool) -> [Double]? {
        var indices: [Int] = []
        for i in 1..<(signal.count - 1) {
            let isExtreme = maxima
                ? (signal[i] >= signal[i - 1] && signal[i] > signal[i + 1])
                : (signal[i] <= signal[i - 1] && signal[i] < signal[i + 1])
            if isExtreme { indices.append(i) }
        }
        guard indices.count >= 2 else { return nil }

        // Clamp the ends to the nearest extremum, so the envelope does not
        // sweep off towards zero at the edges and produce a spurious trend.
        if indices.first != 0 { indices.insert(0, at: 0) }
        if indices.last != signal.count - 1 { indices.append(signal.count - 1) }

        var out = [Double](repeating: 0, count: signal.count)
        for k in 0..<(indices.count - 1) {
            let a = indices[k], b = indices[k + 1]
            let ya = signal[a], yb = signal[b]
            guard b > a else { continue }
            for i in a...b {
                let t = Double(i - a) / Double(b - a)
                out[i] = ya + (yb - ya) * t
            }
        }
        return out
    }

    static func countExtrema(_ signal: [Double]) -> (maxima: Int, minima: Int) {
        guard signal.count >= 3 else { return (0, 0) }
        var maxima = 0, minima = 0
        for i in 1..<(signal.count - 1) {
            if signal[i] >= signal[i - 1] && signal[i] > signal[i + 1] { maxima += 1 }
            if signal[i] <= signal[i - 1] && signal[i] < signal[i + 1] { minima += 1 }
        }
        return (maxima, minima)
    }

    /// The dominant frequency of an intrinsic mode, from its zero crossings.
    ///
    /// Legitimate here in a way it is not for a general signal: an intrinsic
    /// mode function has, by construction, exactly one zero crossing between
    /// consecutive extrema — that is what makes it "intrinsic" — so counting
    /// them measures its frequency exactly rather than approximately.
    public static func frequency(of mode: [Double], sampleRate: Double) -> Double {
        guard mode.count > 2 else { return 0 }
        var crossings = 0
        for i in 1..<mode.count where (mode[i - 1] < 0) != (mode[i] < 0) { crossings += 1 }
        let seconds = Double(mode.count) / sampleRate
        guard seconds > 0 else { return 0 }
        return Double(crossings) / (2 * seconds)
    }
}

// MARK: - 72. Savitzky–Golay

/// Algorithm 72 — the Savitzky–Golay filter.
///
/// Every smoother in this app so far is a moving average of some shape, and
/// every moving average does the same damage: it flattens peaks. That is
/// tolerable on a trace being drawn and intolerable on a spectrum whose peak
/// *height* and *width* are what damping is read from — smooth a resonance and
/// you have manufactured damping that is not there.
///
/// Savitzky–Golay smooths by fitting a low-order polynomial to a sliding window
/// by least squares and taking the fitted value at the centre. A parabola can
/// follow a peak, so the peak survives; noise cannot be followed by a parabola,
/// so it does not. The coefficients turn out to be fixed for a given window and
/// order, which is why a method that sounds like a least-squares fit per sample
/// is in fact one convolution.
public enum SavitzkyGolay {

    /// Convolution coefficients for smoothing.
    ///
    /// Computed from the pseudo-inverse of the Vandermonde matrix rather than
    /// looked up in a table, so any window and order work rather than the
    /// handful somebody typed in.
    public static func coefficients(windowLength: Int, order: Int) -> [Double]? {
        let half = windowLength / 2
        guard windowLength % 2 == 1, windowLength >= 3,
              order >= 1, order < windowLength else { return nil }

        // A = Vandermonde over the window offsets. We need the first row of
        // (AᵀA)⁻¹Aᵀ, which gives the fitted value at the centre.
        let degree = order + 1
        var ata = [[Double]](repeating: [Double](repeating: 0, count: degree), count: degree)
        for i in 0..<degree {
            for j in 0..<degree {
                var sum = 0.0
                for k in -half...half {
                    sum += Foundation.pow(Double(k), Double(i)) * Foundation.pow(Double(k), Double(j))
                }
                ata[i][j] = sum
            }
        }

        // Solve (AᵀA)x = e₀ — the centre value is the constant term of the fit.
        var rhs = [Double](repeating: 0, count: degree)
        rhs[0] = 1
        guard let x = PronyAnalysis.solve(ata, rhs) else { return nil }

        return (-half...half).map { k in
            var value = 0.0
            for i in 0..<degree { value += x[i] * Foundation.pow(Double(k), Double(i)) }
            return value
        }
    }

    public static func smooth(_ signal: [Double], windowLength: Int = 11,
                              order: Int = 3) -> [Double] {
        guard let kernel = coefficients(windowLength: windowLength, order: order),
              signal.count >= windowLength else { return signal }
        let half = windowLength / 2

        var out = [Double](repeating: 0, count: signal.count)
        for i in signal.indices {
            var sum = 0.0
            for (k, weight) in kernel.enumerated() {
                // Reflect at the edges. Zero-padding would pull the first and
                // last few samples towards zero, which on a spectrum is a fake
                // roll-off at exactly the low-frequency end a long-period
                // building lives at.
                var index = i + k - half
                if index < 0 { index = -index }
                if index >= signal.count { index = 2 * (signal.count - 1) - index }
                sum += signal[max(min(index, signal.count - 1), 0)] * weight
            }
            out[i] = sum
        }
        return out
    }

    /// Smooths a spectrum without touching its frequency axis.
    public static func smooth(_ spectrum: PowerSpectrum, windowLength: Int = 9,
                              order: Int = 3) -> PowerSpectrum {
        PowerSpectrum(frequencies: spectrum.frequencies,
                      power: smooth(spectrum.power, windowLength: windowLength, order: order),
                      sampleRate: spectrum.sampleRate)
    }
}
