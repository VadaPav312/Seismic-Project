import XCTest
import SeismicCore
@testable import SeismicSignal

final class AdvancedSpectralTests: XCTestCase {

    private func tone(_ frequency: Double, sampleRate: Double, seconds: Double,
                      amplitude: Double = 1) -> [Double] {
        let count = Int(sampleRate * seconds)
        return (0..<count).map {
            amplitude * sin(2 * Double.pi * frequency * Double($0) / sampleRate)
        }
    }

    private func noise(count: Int, sigma: Double, seed: UInt64) -> [Double] {
        var rng = SeededRandom(seed: seed)
        return (0..<count).map { _ in rng.gaussian(mean: 0, sd: sigma) }
    }

    // MARK: 68 — Multitaper

    /// Orthogonality is the whole basis of the method: if the tapers were not
    /// orthogonal, averaging their estimates would not reduce variance and the
    /// algorithm would be an expensive way to compute one periodogram.
    func testSineTapersAreOrthonormal() {
        let n = 256
        for k in 0..<5 {
            let a = Multitaper.taper(k, length: n)
            XCTAssertEqual(a.reduce(0) { $0 + $1 * $1 }, 1, accuracy: 0.02,
                           "Taper \(k) is not unit energy.")
            for j in 0..<5 where j != k {
                let b = Multitaper.taper(j, length: n)
                let dot = zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
                XCTAssertEqual(dot, 0, accuracy: 1e-9,
                               "Tapers \(k) and \(j) are not orthogonal.")
            }
        }
    }

    func testMultitaperPutsItsPeakAtTheToneFrequency() {
        let w = Waveform(samples: tone(5, sampleRate: 200, seconds: 8), sampleRate: 200)
        let spectrum = Multitaper.spectrum(w, tapers: 5)
        guard let peak = spectrum.power.indices
            .max(by: { spectrum.power[$0] < spectrum.power[$1] }) else {
            return XCTFail("Empty spectrum.")
        }
        XCTAssertEqual(spectrum.frequencies[peak], 5, accuracy: 0.4)
    }

    /// The claim that justifies the algorithm: less variance than a single
    /// tapered periodogram at the same resolution. Measured on white noise,
    /// where the true spectrum is flat and every wiggle is variance.
    func testMultitaperIsSmootherThanAPeriodogramOnWhiteNoise() {
        let w = Waveform(samples: noise(count: 4_096, sigma: 1, seed: 5), sampleRate: 100)
        let single = Spectrum.periodogram(w)
        let multi = Multitaper.spectrum(w, tapers: 6)

        func roughness(_ values: [Double]) -> Double {
            guard values.count > 2 else { return 0 }
            let mean = Stats.mean(values)
            guard mean > 0 else { return 0 }
            var sum = 0.0
            for i in 1..<values.count { sum += abs(values[i] - values[i - 1]) }
            return sum / (Double(values.count - 1) * mean)
        }
        XCTAssertLessThan(roughness(multi.power), roughness(single.power) * 0.8)
    }

    /// The F-test has to fire hard on a deterministic sinusoid — a mains
    /// harmonic, a lift motor, a transformer — because that is the thing this
    /// app must never track as a building mode.
    func testLineTestFiresOnAPureSinusoid() {
        let signal = zip(tone(5, sampleRate: 200, seconds: 8, amplitude: 1),
                         noise(count: 1_600, sigma: 0.2, seed: 11)).map(+)
        let w = Waveform(samples: signal, sampleRate: 200)
        let f = Multitaper.lineTest(w, tapers: 5)
        let spectrum = Multitaper.spectrum(w, tapers: 5)

        // The bin nearest 5 Hz, and its immediate neighbours — the line will
        // not sit exactly on a bin centre.
        let near = spectrum.frequencies.indices.filter { abs(spectrum.frequencies[$0] - 5) < 0.4 }
        XCTAssertFalse(near.isEmpty)
        let peakF = near.map { f[$0] }.max() ?? 0
        XCTAssertGreaterThan(peakF, 10, "F at the line was only \(peakF).")
    }

    /// And it must stay quiet on noise, or it would reject everything.
    func testLineTestStaysQuietOnBroadbandNoise() {
        let w = Waveform(samples: noise(count: 2_048, sigma: 1, seed: 23), sampleRate: 200)
        let f = Multitaper.lineTest(w, tapers: 5)
        XCTAssertFalse(f.isEmpty)
        // Under the null the statistic has a median near one; a handful of high
        // values across a thousand bins is expected, a high median is not.
        XCTAssertLessThan(Stats.median(f), 4)
    }

    /// The distinction the test exists for: a deterministic line and a
    /// narrowband random resonance look alike on a spectrum, and this separates
    /// them.
    ///
    /// The claim asserted is directional — the line scores higher — and that is
    /// deliberately all it claims. Measured across several realisations the
    /// margin is real but modest, typically well under a factor of two at five
    /// tapers with a lightly damped resonance. That is a genuine limitation:
    /// a narrow enough resonance really does start to resemble a line, and the
    /// statistic should be read alongside the peak's bandwidth rather than as a
    /// verdict on its own. Averaging over seeds rather than trusting one keeps
    /// this from passing by luck.
    func testLineTestScoresADeterministicLineAboveARandomResonance() {
        let rate = 200.0

        func resonance(seed: UInt64) -> [Double] {
            var rng = SeededRandom(seed: seed)
            let omega = 2 * Double.pi * 5.0, damping = 0.03, dt = 1 / rate
            var x = 0.0, v = 0.0
            return (0..<3_200).map { _ in
                let acceleration = rng.gaussian(mean: 0, sd: 1)
                                 - 2 * damping * omega * v - omega * omega * x
                v += acceleration * dt
                x += v * dt
                return x
            }
        }

        let frequencies = Multitaper.spectrum(
            Waveform(samples: tone(5, sampleRate: rate, seconds: 16), sampleRate: rate),
            tapers: 5).frequencies
        let near = frequencies.indices.filter { abs(frequencies[$0] - 5) < 0.4 }
        XCTAssertFalse(near.isEmpty)

        func peakF(_ samples: [Double]) -> Double {
            let f = Multitaper.lineTest(Waveform(samples: samples, sampleRate: rate), tapers: 5)
            return near.map { f[$0] }.max() ?? 0
        }

        let lineScores = [1, 2, 3].map { seed -> Double in
            let signal = zip(tone(5, sampleRate: rate, seconds: 16, amplitude: 0.02),
                             noise(count: 3_200, sigma: 0.002, seed: UInt64(seed))).map(+)
            return peakF(signal)
        }
        let resonanceScores = [11, 12, 13].map { peakF(resonance(seed: UInt64($0))) }

        XCTAssertGreaterThan(Stats.mean(lineScores), Stats.mean(resonanceScores),
                             "Lines averaged \(Stats.mean(lineScores)), resonances "
                             + "\(Stats.mean(resonanceScores)).")
    }

    // MARK: 70 — Wavelet ridge

    func testRidgeFollowsAConstantFrequency() {
        let w = Waveform(samples: tone(2, sampleRate: 100, seconds: 12), sampleRate: 100)
        guard let result = WaveletRidge.run(w, band: 0.5...6, voices: 10) else {
            return XCTFail("No ridge.")
        }
        // Ignore the edges, where the kernel runs off the record.
        let from = result.frequencies.count / 4
        let to = 3 * result.frequencies.count / 4
        for frequency in result.frequencies[from...to] {
            XCTAssertEqual(frequency, 2, accuracy: 0.3)
        }
    }

    /// The measurement the product exists to make, taken mid-record: a building
    /// that softens during the shaking.
    func testRidgeDetectsAFrequencyDroppingPartWayThrough() {
        let rate = 100.0
        var samples: [Double] = []
        var phase = 0.0
        let count = Int(rate * 20)
        for i in 0..<count {
            // 2.0 Hz for the first half, 1.5 Hz for the second — a 33% period
            // lengthening, which is severe damage.
            let frequency = i < count / 2 ? 2.0 : 1.5
            phase += 2 * Double.pi * frequency / rate
            samples.append(sin(phase))
        }

        let w = Waveform(samples: samples, sampleRate: rate)
        guard let result = WaveletRidge.run(w, band: 0.8...4, voices: 14) else {
            return XCTFail("No ridge.")
        }
        let quarter = result.frequencies.count / 4
        let early = Stats.mean(Array(result.frequencies[quarter..<(2 * quarter)]))
        let late = Stats.mean(Array(result.frequencies[(2 * quarter + quarter / 2)...]))

        XCTAssertEqual(early, 2.0, accuracy: 0.25)
        XCTAssertEqual(late, 1.5, accuracy: 0.25)
        XCTAssertGreaterThan(result.periodChange ?? 0, 0.15)
    }

    func testRidgeReportsNoPeriodChangeForASteadyBuilding() {
        let w = Waveform(samples: tone(2, sampleRate: 100, seconds: 15), sampleRate: 100)
        guard let result = WaveletRidge.run(w, band: 0.8...5) else { return XCTFail() }
        XCTAssertEqual(result.periodChange ?? 0, 0, accuracy: 0.08)
    }

    func testRidgeRefusesAnImpossibleBand() {
        let w = Waveform(samples: tone(2, sampleRate: 100, seconds: 5), sampleRate: 100)
        XCTAssertNil(WaveletRidge.run(w, band: 60...80))     // above Nyquist
        XCTAssertNil(WaveletRidge.run(w, band: 0...5))       // zero is not a frequency
        // An inverted band is not tested: `5...1` traps at construction, so
        // Swift's own type system already makes it unreachable.
        let short = Waveform(samples: tone(2, sampleRate: 100, seconds: 0.2), sampleRate: 100)
        XCTAssertNil(WaveletRidge.run(short, band: 1...5))
    }

    // MARK: 71 — EMD

    func testEMDSeparatesAFastToneFromASlowOne() {
        let rate = 100.0
        let fast = tone(10, sampleRate: rate, seconds: 10, amplitude: 1)
        let slow = tone(1, sampleRate: rate, seconds: 10, amplitude: 3)
        let mixed = zip(fast, slow).map(+)

        let result = EmpiricalModeDecomposition.decompose(mixed, maximumModes: 4)
        XCTAssertGreaterThanOrEqual(result.modes.count, 2)

        // The first mode out is always the fastest oscillation present.
        let first = EmpiricalModeDecomposition.frequency(of: result.modes[0], sampleRate: rate)
        XCTAssertEqual(first, 10, accuracy: 2.0)

        // And a later one carries the slow component.
        let frequencies = result.modes.map {
            EmpiricalModeDecomposition.frequency(of: $0, sampleRate: rate)
        }
        XCTAssertTrue(frequencies.dropFirst().contains { abs($0 - 1) < 0.7 },
                      "No slow mode recovered. Got \(frequencies)")
    }

    /// The decomposition has to be lossless: modes plus residual must rebuild
    /// the original exactly, or something has been quietly thrown away.
    func testModesAndResidualReconstructTheOriginal() {
        let signal = zip(tone(7, sampleRate: 100, seconds: 8),
                         tone(1.5, sampleRate: 100, seconds: 8, amplitude: 2)).map(+)
        let result = EmpiricalModeDecomposition.decompose(signal, maximumModes: 5)

        var rebuilt = result.residual
        for mode in result.modes {
            rebuilt = zip(rebuilt, mode).map(+)
        }
        for (original, reconstructed) in zip(signal, rebuilt) {
            XCTAssertEqual(original, reconstructed, accuracy: 1e-9)
        }
    }

    func testEMDStopsOnAPureTrendRatherThanInventingModes() {
        // A straight ramp has no extrema, so there is nothing to extract.
        let ramp = (0..<500).map { Double($0) * 0.01 }
        let result = EmpiricalModeDecomposition.decompose(ramp)
        XCTAssertTrue(result.modes.isEmpty)
        XCTAssertEqual(result.residual.count, ramp.count)
    }

    func testEMDHandlesAShortSignalWithoutCrashing() {
        let result = EmpiricalModeDecomposition.decompose([1, 2, 3])
        XCTAssertTrue(result.modes.isEmpty)
    }

    // MARK: 72 — Savitzky–Golay

    /// The defining property, and the reason it exists here: a polynomial
    /// smoother reproduces any polynomial up to its order exactly. A moving
    /// average does not, and that failure is what flattens peaks.
    func testItReproducesAQuadraticExactly() {
        let quadratic = (0..<200).map { i -> Double in
            let x = Double(i) - 100
            return 3 * x * x - 2 * x + 7
        }
        let smoothed = SavitzkyGolay.smooth(quadratic, windowLength: 11, order: 3)
        // Away from the reflected edges.
        for i in 20..<180 {
            XCTAssertEqual(smoothed[i], quadratic[i], accuracy: 1e-6)
        }
    }

    func testItPreservesPeakHeightFarBetterThanAMovingAverage() {
        // A narrow Gaussian peak on a flat floor, the shape of a modal
        // resonance in a spectrum.
        let peak = (0..<201).map { i -> Double in
            let x = Double(i) - 100
            return exp(-x * x / (2 * 6 * 6))
        }
        let smoothed = SavitzkyGolay.smooth(peak, windowLength: 11, order: 3)

        let window = 11
        let movingAverage = peak.indices.map { i -> Double in
            let from = max(i - window / 2, 0), to = min(i + window / 2, peak.count - 1)
            return Stats.mean(Array(peak[from...to]))
        }

        let trueHeight = peak[100]
        XCTAssertEqual(smoothed[100], trueHeight, accuracy: 0.02)
        XCTAssertLessThan(movingAverage[100], trueHeight - 0.04,
                          "The moving average was supposed to flatten the peak.")
    }

    func testItActuallyReducesNoise() {
        let clean = tone(2, sampleRate: 100, seconds: 10)
        let noisy = zip(clean, noise(count: clean.count, sigma: 0.3, seed: 3)).map(+)
        let smoothed = SavitzkyGolay.smooth(noisy, windowLength: 15, order: 3)

        func error(_ values: [Double]) -> Double {
            Stats.rms(zip(values, clean).map(-))
        }
        XCTAssertLessThan(error(smoothed), error(noisy) * 0.7)
    }

    func testCoefficientsSumToOneSoTheLevelIsPreserved() {
        guard let kernel = SavitzkyGolay.coefficients(windowLength: 9, order: 2) else {
            return XCTFail("No coefficients.")
        }
        XCTAssertEqual(kernel.reduce(0, +), 1, accuracy: 1e-9)
    }

    func testInvalidWindowsAreRefusedRatherThanFudged() {
        XCTAssertNil(SavitzkyGolay.coefficients(windowLength: 10, order: 3))  // even
        XCTAssertNil(SavitzkyGolay.coefficients(windowLength: 5, order: 5))   // order ≥ window
        XCTAssertNil(SavitzkyGolay.coefficients(windowLength: 1, order: 1))   // too short
    }
}
