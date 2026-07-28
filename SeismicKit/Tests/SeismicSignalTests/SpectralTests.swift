import XCTest
@testable import SeismicSignal
import SeismicCore

// Algorithms 15–22.

final class FFTTests: XCTestCase {

    func testPowerOfTwoHelpers() {
        XCTAssertEqual(FFT.nextPowerOfTwo(1), 1)
        XCTAssertEqual(FFT.nextPowerOfTwo(5), 8)
        XCTAssertEqual(FFT.nextPowerOfTwo(1024), 1024)
        XCTAssertEqual(FFT.nextPowerOfTwo(1025), 2048)
        XCTAssertTrue(FFT.isPowerOfTwo(256))
        XCTAssertFalse(FFT.isPowerOfTwo(255))
    }

    func testForwardTransformOfADeltaIsFlat() {
        var buffer = [Complex](repeating: Complex(0), count: 64)
        buffer[0] = Complex(1)
        FFT.forward(&buffer)
        for bin in buffer { XCTAssertEqual(bin.magnitude, 1, accuracy: 1e-12) }
    }

    func testForwardTransformOfAConstantIsADeltaAtDC() {
        var buffer = [Complex](repeating: Complex(1), count: 64)
        FFT.forward(&buffer)
        XCTAssertEqual(buffer[0].magnitude, 64, accuracy: 1e-9)
        for i in 1..<64 { XCTAssertEqual(buffer[i].magnitude, 0, accuracy: 1e-9) }
    }

    func testInverseUndoesForward() {
        var rng = SeededRandom(seed: 8)
        let original = (0..<128).map { _ in Complex(rng.gaussian(), rng.gaussian()) }
        var buffer = original
        FFT.forward(&buffer)
        FFT.inverse(&buffer)
        for i in 0..<128 {
            XCTAssertEqual(buffer[i].re, original[i].re, accuracy: 1e-10)
            XCTAssertEqual(buffer[i].im, original[i].im, accuracy: 1e-10)
        }
    }

    func testParsevalEnergyIsConserved() {
        var rng = SeededRandom(seed: 21)
        let x = (0..<256).map { _ in rng.gaussian() }
        var buffer = x.map { Complex($0) }
        FFT.forward(&buffer)
        let timeEnergy = x.reduce(0) { $0 + $1 * $1 }
        let freqEnergy = buffer.reduce(0) { $0 + $1.magnitudeSquared } / Double(x.count)
        XCTAssertEqual(timeEnergy, freqEnergy, accuracy: timeEnergy * 1e-9)
    }

    func testAmplitudeSpectrumRecoversAKnownSineAmplitude() {
        // 128 Hz for 16 s gives 2048 samples and 0.0625 Hz bins, so 5 Hz lands
        // exactly on bin 80. A sine of amplitude 2 must then read 2 — not 1
        // (forgetting the mirrored half) and not 1024 (forgetting to normalise).
        let w = SyntheticMotion.sine(frequency: 5, seconds: 16, sampleRate: 128, amplitude: 2)
        let (frequencies, amplitudes) = FFT.amplitudeSpectrum(w.samples, sampleRate: 128)
        let peakIndex = amplitudes.indices.max { amplitudes[$0] < amplitudes[$1] }!
        XCTAssertEqual(frequencies[peakIndex], 5, accuracy: 0.05)
        XCTAssertEqual(amplitudes[peakIndex], 2, accuracy: 0.02)
    }

    func testScallopingLossIsBoundedForAnOffBinTone() {
        // A tone halfway between two bins loses amplitude to its neighbours.
        // With a Hann window that loss is about 15% at worst — worth knowing
        // about, and the reason peak *frequencies* get parabolic interpolation
        // while peak *amplitudes* are read from an integrated band.
        let binWidth = 128.0 / 2048
        let offBin = 5 + binWidth / 2
        let w = SyntheticMotion.sine(frequency: offBin, seconds: 16, sampleRate: 128, amplitude: 2)
        let (_, amplitudes) = FFT.amplitudeSpectrum(w.samples, sampleRate: 128)
        let peak = amplitudes.max()!
        XCTAssertGreaterThan(peak, 2 * 0.8)
        XCTAssertLessThanOrEqual(peak, 2 * 1.02)
    }

    func testNonPowerOfTwoInputIsHandled() {
        let spectrum = FFT.realForward((0..<100).map { sin(Double($0) * 0.1) })
        XCTAssertEqual(spectrum.count, 65)      // padded to 128, half-spectrum + 1
    }

    func testEmptyInputDoesNotCrash() {
        XCTAssertTrue(FFT.realForward([]).isEmpty)
        var empty: [Complex] = []
        FFT.forward(&empty)
        XCTAssertTrue(empty.isEmpty)
    }
}

final class WelchTests: XCTestCase {

    func testPeakLandsAtTheDrivingFrequency() {
        let w = SyntheticMotion.sine(frequency: 3.2, seconds: 120, sampleRate: 100, amplitude: 1)
        let spectrum = Spectrum.welch(w, segmentSeconds: 20)
        XCTAssertEqual(spectrum.peakFrequency, 3.2, accuracy: 0.1)
    }

    func testAveragingReducesVarianceComparedToASinglePeriodogram() {
        var rng = SeededRandom(seed: 1234)
        let noise = Waveform(samples: (0..<24_000).map { _ in rng.gaussian() }, sampleRate: 100)

        let single = Spectrum.periodogram(noise)
        let averaged = Spectrum.welch(noise, segmentSeconds: 10, overlap: 0.5)

        // White noise has a flat expected spectrum; the averaged estimate should
        // be visibly less ragged.
        let singleCV = Stats.stdDev(single.power) / Swift.max(Stats.mean(single.power), 1e-30)
        let averagedCV = Stats.stdDev(averaged.power) / Swift.max(Stats.mean(averaged.power), 1e-30)
        XCTAssertLessThan(averagedCV, singleCV)
    }

    func testTwoTonesAreBothResolved() {
        let a = SyntheticMotion.sine(frequency: 2.0, seconds: 100, sampleRate: 100, amplitude: 1)
        let b = SyntheticMotion.sine(frequency: 6.0, seconds: 100, sampleRate: 100, amplitude: 0.6)
        let mixed = Waveform(samples: zip(a.samples, b.samples).map(+), sampleRate: 100)

        let spectrum = Spectrum.welch(mixed, segmentSeconds: 25)
        let peaks = PeakPicking.peaks(in: spectrum, minimumProminence: 0.02, limit: 5)
        let frequencies = peaks.map(\.frequency)
        XCTAssertTrue(frequencies.contains { abs($0 - 2.0) < 0.15 }, "2 Hz tone missing")
        XCTAssertTrue(frequencies.contains { abs($0 - 6.0) < 0.15 }, "6 Hz tone missing")
    }

    func testShortRecordStillProducesASpectrum() {
        let w = SyntheticMotion.sine(frequency: 5, seconds: 1, sampleRate: 100)
        XCTAssertFalse(Spectrum.welch(w, segmentSeconds: 20).isEmpty)
    }

    func testEmptyRecordProducesEmptySpectrumRatherThanCrashing() {
        XCTAssertTrue(Spectrum.welch(Waveform(samples: [], sampleRate: 100)).isEmpty)
    }

    func testBandRestrictionKeepsOnlyTheRequestedRange() {
        let w = SyntheticMotion.sine(frequency: 5, seconds: 60, sampleRate: 100)
        let band = Spectrum.welch(w).band(1...10)
        XCTAssertTrue(band.frequencies.allSatisfy { $0 >= 1 && $0 <= 10 })
    }
}

final class KonnoOhmachiTests: XCTestCase {

    func testSmoothingPreservesThePeakLocation() {
        let w = SyntheticMotion.sine(frequency: 4, seconds: 100, sampleRate: 100)
        let raw = Spectrum.welch(w, segmentSeconds: 20)
        let smoothed = Spectrum.konnoOhmachi(raw, bandwidth: 40)
        XCTAssertEqual(smoothed.peakFrequency, raw.peakFrequency, accuracy: 0.2)
    }

    func testSmoothingReducesRaggedness() {
        var rng = SeededRandom(seed: 55)
        let noise = Waveform(samples: (0..<12_000).map { _ in rng.gaussian() }, sampleRate: 100)
        let raw = Spectrum.welch(noise, segmentSeconds: 5)
        let smoothed = Spectrum.konnoOhmachi(raw, bandwidth: 20)

        func roughness(_ p: [Double]) -> Double {
            guard p.count > 2 else { return 0 }
            var total = 0.0
            for i in 1..<p.count { total += abs(p[i] - p[i - 1]) }
            return total / Double(p.count)
        }
        XCTAssertLessThan(roughness(smoothed.power), roughness(raw.power))
    }

    func testSmoothingIsConstantWidthInLogFrequency() {
        // A tone at 1 Hz and a tone at 10 Hz should be broadened by the same
        // *fractional* amount, which is the whole point of Konno-Ohmachi.
        let low = Spectrum.konnoOhmachi(
            Spectrum.welch(SyntheticMotion.sine(frequency: 1, seconds: 200, sampleRate: 100),
                           segmentSeconds: 50), bandwidth: 20)
        let high = Spectrum.konnoOhmachi(
            Spectrum.welch(SyntheticMotion.sine(frequency: 10, seconds: 200, sampleRate: 100),
                           segmentSeconds: 50), bandwidth: 20)

        func fractionalWidth(_ s: PowerSpectrum) -> Double {
            guard let peakIdx = s.power.indices.max(by: { s.power[$0] < s.power[$1] }) else { return 0 }
            let half = s.power[peakIdx] / 2
            var lo = peakIdx, hi = peakIdx
            while lo > 0, s.power[lo] > half { lo -= 1 }
            while hi < s.power.count - 1, s.power[hi] > half { hi += 1 }
            return (s.frequencies[hi] - s.frequencies[lo]) / Swift.max(s.frequencies[peakIdx], 1e-9)
        }
        XCTAssertEqual(fractionalWidth(low), fractionalWidth(high), accuracy: 0.35)
    }

    func testEmptySpectrumPassesThrough() {
        let empty = PowerSpectrum(frequencies: [], power: [], sampleRate: 100)
        XCTAssertTrue(Spectrum.konnoOhmachi(empty).isEmpty)
    }
}

final class PeakPickingTests: XCTestCase {

    func testProminenceRejectsRipplesOnAShoulder() {
        // One tall peak with a small bump on its side. Only the peak survives.
        var power = [Double](repeating: 0.01, count: 100)
        for i in 40..<60 { power[i] = 1 - abs(Double(i - 50)) * 0.08 }
        power[57] += 0.02                       // a ripple, not a mode
        let frequencies = (0..<100).map { Double($0) * 0.1 }
        let spectrum = PowerSpectrum(frequencies: frequencies, power: power, sampleRate: 20)

        let peaks = PeakPicking.peaks(in: spectrum, minimumProminence: 0.1)
        XCTAssertEqual(peaks.count, 1)
        XCTAssertEqual(peaks[0].frequency, 5.0, accuracy: 0.2)
    }

    func testMinimumSeparationKeepsOnlyTheStrongestOfACluster() {
        var power = [Double](repeating: 0.01, count: 200)
        power[100] = 1.0; power[101] = 0.9; power[103] = 0.8
        let frequencies = (0..<200).map { Double($0) * 0.01 }
        let spectrum = PowerSpectrum(frequencies: frequencies, power: power, sampleRate: 4)

        let peaks = PeakPicking.peaks(in: spectrum, minimumProminence: 0.05,
                                      minimumSeparationHz: 0.1)
        XCTAssertEqual(peaks.count, 1)
    }

    func testParabolicInterpolationFindsTheTrueVertex() {
        // Symmetric: vertex exactly at the centre bin.
        XCTAssertEqual(PeakPicking.parabolicRefine(1, 2, 1).offset, 0, accuracy: 1e-12)
        // Skewed right: vertex moves right, by less than one bin.
        let right = PeakPicking.parabolicRefine(1, 2, 1.5).offset
        XCTAssertGreaterThan(right, 0)
        XCTAssertLessThan(right, 0.5)
        // Skewed left: mirror image.
        XCTAssertEqual(PeakPicking.parabolicRefine(1.5, 2, 1).offset, -right, accuracy: 1e-12)
    }

    func testInterpolationBeatsBinResolution() {
        // Deliberately place a tone between two bins and check the interpolated
        // frequency is closer than the nearest bin centre.
        let sampleRate = 100.0, seconds = 20.48
        let trueFrequency = 3.087
        let w = SyntheticMotion.sine(frequency: trueFrequency, seconds: seconds,
                                     sampleRate: sampleRate)
        let spectrum = Spectrum.welch(w, segmentSeconds: seconds, overlap: 0)
        guard let peak = PeakPicking.peaks(in: spectrum, minimumProminence: 0.01)
            .max(by: { $0.power < $1.power }) else { return XCTFail("no peak found") }

        let nearestBin = spectrum.frequencies.min { abs($0 - trueFrequency) < abs($1 - trueFrequency) }!
        XCTAssertLessThanOrEqual(abs(peak.frequency - trueFrequency),
                                 abs(nearestBin - trueFrequency) + 1e-9)
    }

    func testFlatSpectrumYieldsNoPeaks() {
        let flat = PowerSpectrum(frequencies: (0..<50).map(Double.init),
                                 power: [Double](repeating: 1, count: 50), sampleRate: 10)
        XCTAssertTrue(PeakPicking.peaks(in: flat, minimumProminence: 0.1).isEmpty)
    }

    func testHalfPowerWidthIsWiderForABroaderPeak() {
        func spectrumWithWidth(_ width: Double) -> PowerSpectrum {
            let frequencies = (0..<400).map { Double($0) * 0.01 }
            let power = frequencies.map { f -> Double in
                let d = (f - 2.0) / width
                return 1 / (1 + d * d)
            }
            return PowerSpectrum(frequencies: frequencies, power: power, sampleRate: 8)
        }
        let narrow = spectrumWithWidth(0.05)
        let broad = spectrumWithWidth(0.25)
        let narrowPeak = PeakPicking.peaks(in: narrow, minimumProminence: 0.1).first!
        let broadPeak = PeakPicking.peaks(in: broad, minimumProminence: 0.1).first!
        XCTAssertLessThan(narrowPeak.halfPowerBandwidth, broadPeak.halfPowerBandwidth)
    }
}

final class PeriodEstimationTests: XCTestCase {

    func testAutocorrelationRecoversAKnownPeriod() {
        let period = 1.6
        let w = SyntheticMotion.sine(frequency: 1 / period, seconds: 60, sampleRate: 100)
        let result = PeriodEstimation.autocorrelation(w)
        XCTAssertNotNil(result)
        XCTAssertEqual(result!.period, period, accuracy: 0.05)
        XCTAssertGreaterThan(result!.confidence, 0.8)
    }

    func testZeroCrossingRecoversAKnownPeriod() {
        let period = 0.8
        let w = SyntheticMotion.sine(frequency: 1 / period, seconds: 40, sampleRate: 200)
        let result = PeriodEstimation.zeroCrossing(w)
        XCTAssertNotNil(result)
        XCTAssertEqual(result!.period, period, accuracy: 0.02)
        XCTAssertGreaterThan(result!.confidence, 0.9)
    }

    func testZeroCrossingConfidenceCollapsesOnBroadbandNoise() {
        var rng = SeededRandom(seed: 909)
        let noise = Waveform(samples: (0..<8000).map { _ in rng.gaussian() }, sampleRate: 100)
        if let result = PeriodEstimation.zeroCrossing(noise) {
            XCTAssertLessThan(result.confidence, 0.75,
                              "broadband noise must not look like a clean period")
        }
    }

    func testCrossCheckAgreesOnACleanSignal() {
        let period = 1.25
        let w = SyntheticMotion.freeDecay(period: period, damping: 0.02, seconds: 80,
                                          sampleRate: 100, noise: 0.001)
        let result = PeriodEstimation.crossChecked(w, band: 0.2...5)
        XCTAssertNotNil(result.consensus)
        XCTAssertEqual(result.consensus!, period, accuracy: 0.08)
        XCTAssertGreaterThan(result.agreement, 0.7)
        XCTAssertFalse(result.explanation.isEmpty)
    }

    func testCrossCheckReportsHonestlyWhenNothingIsMeasurable() {
        let w = Waveform(samples: [Double](repeating: 0, count: 500), sampleRate: 100)
        let result = PeriodEstimation.crossChecked(w)
        XCTAssertNil(result.consensus)
        XCTAssertEqual(result.agreement, 0)
        XCTAssertFalse(result.explanation.isEmpty)
    }
}

final class STFTTests: XCTestCase {

    func testSpectrogramHasExpectedShape() {
        let w = SyntheticMotion.sine(frequency: 5, seconds: 60, sampleRate: 100)
        let s = STFT.compute(w, windowSeconds: 4, overlap: 0.5)
        XCTAssertFalse(s.isEmpty)
        XCTAssertEqual(s.magnitudes.count, s.times.count)
        XCTAssertTrue(s.magnitudes.allSatisfy { $0.count == s.frequencies.count })
    }

    func testRidgeTracksASweepingFrequency() {
        // A chirp from 1 Hz to 8 Hz: the ridge must rise monotonically.
        let sampleRate = 100.0, seconds = 60.0
        let n = Int(seconds * sampleRate)
        var phase = 0.0
        var samples = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let t = Double(i) / sampleRate
            let f = 1 + 7 * (t / seconds)
            phase += 2 * .pi * f / sampleRate
            samples[i] = sin(phase)
        }
        let s = STFT.compute(Waveform(samples: samples, sampleRate: sampleRate),
                             windowSeconds: 4, overlap: 0.75, maximumFrequency: 20)
        let ridge = s.dominantFrequencyRidge
        XCTAssertGreaterThan(ridge.count, 10)
        XCTAssertLessThan(ridge.first!.frequency, 3)
        XCTAssertGreaterThan(ridge.last!.frequency, 6)
    }

    func testNormalisedDecibelsAreBounded() {
        let w = SyntheticMotion.sine(frequency: 5, seconds: 30, sampleRate: 100)
        let db = STFT.compute(w).normalisedDecibels()
        for row in db { for v in row { XCTAssertTrue(v >= 0 && v <= 1) } }
    }

    func testShortRecordProducesEmptySpectrogramRatherThanCrashing() {
        XCTAssertTrue(STFT.compute(Waveform(samples: [1, 2, 3], sampleRate: 100)).isEmpty)
    }
}
