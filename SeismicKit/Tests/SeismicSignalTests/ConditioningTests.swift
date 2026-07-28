import XCTest
@testable import SeismicSignal
import SeismicCore

// Algorithms 1–8.

final class DetrendTests: XCTestCase {
    func testDCOffsetRemovalLeavesZeroMean() {
        let x = (0..<100).map { _ in 5.0 }
        XCTAssertEqual(Stats.mean(Detrend.removeDCOffset(x)), 0, accuracy: 1e-12)
    }

    func testLinearDetrendRemovesAKnownRamp() {
        let x = (0..<200).map { 3.0 + 0.25 * Double($0) }
        let out = Detrend.linear(x)
        XCTAssertEqual(Stats.peakAbs(out), 0, accuracy: 1e-9)
    }

    func testLinearDetrendPreservesOscillation() {
        let sine = SyntheticMotion.sine(frequency: 2, seconds: 10, amplitude: 1)
        let ramped = sine.samples.enumerated().map { $1 + 0.01 * Double($0) }
        let out = Detrend.linear(ramped)
        // The sine survives; the ramp does not.
        XCTAssertEqual(Stats.peakAbs(out), 1.0, accuracy: 0.05)
        XCTAssertEqual(Stats.mean(out), 0, accuracy: 1e-9)
    }

    func testPolynomialDetrendRemovesQuadratic() {
        let x = (0..<300).map { i -> Double in
            let t = Double(i)
            return 2 + 0.1 * t + 0.003 * t * t
        }
        let out = Detrend.polynomial(x, order: 2)
        XCTAssertLessThan(Stats.peakAbs(out), 1e-6)
    }

    func testDegenerateInputsDoNotCrash() {
        XCTAssertTrue(Detrend.linear([]).isEmpty)
        XCTAssertEqual(Detrend.linear([7]).count, 1)
        XCTAssertEqual(Detrend.polynomial([1, 2], order: 5).count, 2)
    }
}

final class LinearAlgebraTests: XCTestCase {
    func testSolvesKnownSystem() {
        // 2x +  y = 5 ; x + 3y = 10  →  x = 1, y = 3
        let a = [[2.0, 1.0], [1.0, 3.0]]
        let solution = LinearAlgebra.solve(a, [5, 10])
        XCTAssertNotNil(solution)
        XCTAssertEqual(solution![0], 1, accuracy: 1e-12)
        XCTAssertEqual(solution![1], 3, accuracy: 1e-12)
    }

    func testSingularSystemReturnsNilRatherThanNonsense() {
        XCTAssertNil(LinearAlgebra.solve([[1, 2], [2, 4]], [3, 6]))
    }

    func testSymmetricEigenvaluesOfDiagonalMatrix() {
        let e = LinearAlgebra.symmetricEigenvalues3x3([[3, 0, 0], [0, 1, 0], [0, 0, 2]])
        XCTAssertEqual(e[0], 3, accuracy: 1e-9)
        XCTAssertEqual(e[1], 2, accuracy: 1e-9)
        XCTAssertEqual(e[2], 1, accuracy: 1e-9)
    }

    func testSymmetricEigenvaluesSumToTrace() {
        let m = [[4.0, 1.0, 0.5], [1.0, 3.0, 0.2], [0.5, 0.2, 2.0]]
        let e = LinearAlgebra.symmetricEigenvalues3x3(m)
        XCTAssertEqual(e.reduce(0, +), 9.0, accuracy: 1e-9)
        XCTAssertTrue(e[0] >= e[1] && e[1] >= e[2])
    }
}

final class ButterworthTests: XCTestCase {
    func testPassbandIsFlatAndStopbandIsAttenuated() {
        let sampleRate = 100.0
        let filter = ButterworthFilter(kind: .bandpass, order: 4, sampleRate: sampleRate,
                                       lowCutoff: 1, highCutoff: 10)

        // In band: survives.
        let inBand = SyntheticMotion.sine(frequency: 4, seconds: 20, sampleRate: sampleRate)
        let passed = filter.applyZeroPhase(inBand.samples)
        let steady = Array(passed[Int(sampleRate * 5)..<Int(sampleRate * 15)])
        XCTAssertEqual(Stats.peakAbs(steady), 1.0, accuracy: 0.08)

        // Well below band: crushed.
        let tooLow = SyntheticMotion.sine(frequency: 0.1, seconds: 20, sampleRate: sampleRate)
        let blockedLow = filter.applyZeroPhase(tooLow.samples)
        XCTAssertLessThan(Stats.peakAbs(Array(blockedLow[500..<1500])), 0.05)

        // Well above band: crushed.
        let tooHigh = SyntheticMotion.sine(frequency: 40, seconds: 20, sampleRate: sampleRate)
        let blockedHigh = filter.applyZeroPhase(tooHigh.samples)
        XCTAssertLessThan(Stats.peakAbs(Array(blockedHigh[500..<1500])), 0.05)
    }

    func testZeroPhaseFilteringDoesNotShiftAPulseInTime() {
        var samples = [Double](repeating: 0, count: 1000)
        // A smooth pulse centred at sample 500, comfortably inside the passband.
        for i in 0..<1000 {
            let t = Double(i - 500) / 100.0
            samples[i] = exp(-t * t * 30) * cos(2 * .pi * 5 * t)
        }
        let filter = ButterworthFilter(kind: .bandpass, order: 4, sampleRate: 100,
                                       lowCutoff: 1, highCutoff: 20)
        let out = filter.applyZeroPhase(samples)
        let peakIn = samples.indices.max { abs(samples[$0]) < abs(samples[$1]) }!
        let peakOut = out.indices.max { abs(out[$0]) < abs(out[$1]) }!
        // Zero phase means the peak stays put. A single-pass filter would move it.
        XCTAssertLessThanOrEqual(abs(peakIn - peakOut), 2)
    }

    func testFilterDoesNotRingAtTheStartOfARecordWithAnOffset() {
        // A constant offset must not produce a startup transient that looks like
        // an arrival — this is what priming the delay line is for.
        let samples = [Double](repeating: 2.5, count: 500)
        let filter = ButterworthFilter(kind: .lowpass, order: 4, sampleRate: 100, highCutoff: 10)
        let out = filter.apply(samples)
        XCTAssertLessThan(Stats.peakAbs(Array(out[0..<20]).map { $0 - 2.5 }), 0.05)
    }

    func testFrequencyResponseIsMonotonicOutsideTheBand() {
        let filter = ButterworthFilter(kind: .lowpass, order: 4, sampleRate: 100, highCutoff: 10)
        let response = filter.frequencyResponse(points: 128)
        XCTAssertEqual(response.count, 128)
        let dc = response.first!.gain
        let nyquist = response.last!.gain
        XCTAssertEqual(dc, 1.0, accuracy: 0.02)
        XCTAssertLessThan(nyquist, 0.01)
    }
}

final class WindowTests: XCTestCase {
    func testWindowsStartAndEndAtExpectedValues() {
        XCTAssertEqual(Window.hann.coefficients(64).first!, 0, accuracy: 1e-12)
        XCTAssertEqual(Window.hann.coefficients(64).last!, 0, accuracy: 1e-12)
        XCTAssertEqual(Window.hamming.coefficients(64).first!, 0.08, accuracy: 1e-12)
        XCTAssertEqual(Window.rectangular.coefficients(64).allSatisfy { $0 == 1 }, true)
    }

    func testWindowsPeakAtTheCentre() {
        for w in Window.allCases {
            let c = w.coefficients(101)
            XCTAssertEqual(c.max()!, c[50], accuracy: 1e-9, "\(w) does not peak at centre")
        }
    }

    func testCoherentGainOfHannIsAHalf() {
        XCTAssertEqual(Window.hann.coherentGain(1024), 0.5, accuracy: 0.001)
        XCTAssertEqual(Window.rectangular.coherentGain(1024), 1.0, accuracy: 1e-12)
    }

    func testFramingProducesExpectedCountAndOverlap() {
        let x = (0..<100).map(Double.init)
        let frames = Framing.frames(x, length: 20, overlap: 0.5)
        XCTAssertEqual(frames.count, 9)         // hop 10, last full frame starts at 80
        XCTAssertEqual(frames[0][0], 0)
        XCTAssertEqual(frames[1][0], 10)
        XCTAssertTrue(frames.allSatisfy { $0.count == 20 })
    }

    func testFramingRefusesToPadAShortSignal() {
        XCTAssertTrue(Framing.frames([1, 2, 3], length: 10, overlap: 0.5).isEmpty)
    }
}

final class IntegrationTests: XCTestCase {
    func testTrapezoidalIntegratesAConstantToARamp() {
        let x = [Double](repeating: 2, count: 101)
        let out = Integration.trapezoidal(x, dt: 0.01)
        XCTAssertEqual(out.last!, 2.0, accuracy: 1e-9)   // 2 × 1 second
    }

    func testIntegratingASineGivesTheAnalyticAmplitude() {
        // ∫ A sin(ωt) dt = −(A/ω) cos(ωt), so amplitude divides by ω.
        let f = 1.0, amplitude = 1.0
        let w = SyntheticMotion.sine(frequency: f, seconds: 20, sampleRate: 200, amplitude: amplitude)
        let integrated = Integration.trapezoidal(w.samples, dt: w.dt)
        let expected = amplitude / (2 * Double.pi * f)
        // ∫₀ᵗ sin(ωτ)dτ = (1 − cos ωt)/ω, which oscillates about a constant of
        // integration of A/ω. Removing that offset leaves the true amplitude.
        let steady = Detrend.removeDCOffset(Array(integrated[400..<3600]))
        XCTAssertEqual(Stats.peakAbs(steady), expected, accuracy: expected * 0.05)
    }

    func testDifferentiationInvertsIntegration() {
        let w = SyntheticMotion.sine(frequency: 2, seconds: 10, sampleRate: 200)
        let integrated = Integration.trapezoidal(w.samples, dt: w.dt)
        let restored = Integration.differentiate(integrated, dt: w.dt)
        let a = Array(w.samples[100..<1900]), b = Array(restored[100..<1900])
        for i in a.indices { XCTAssertEqual(a[i], b[i], accuracy: 0.02) }
    }

    func testDriftRemovalKillsTheRunawayFromADoubleIntegration() {
        // A tiny constant bias integrates twice into a huge parabola.
        var biased = SyntheticMotion.sine(frequency: 1.5, seconds: 30, sampleRate: 100).samples
        for i in biased.indices { biased[i] += 0.02 }
        let w = Waveform(samples: biased, sampleRate: 100)

        let (_, displacement) = Integration.toVelocityAndDisplacement(acceleration: w)
        // Without correction the displacement would reach ~9 m. It must not.
        XCTAssertLessThan(displacement.peakAbsolute, 0.1)
    }

    func testSimpsonMatchesTrapezoidalOnASmoothIntegrand() {
        let x = (0..<200).map { sin(Double($0) * 0.05) * sin(Double($0) * 0.05) }
        let t = Integration.trapezoidal(x, dt: 0.01).last!
        let s = Integration.simpson(x, dt: 0.01).last!
        XCTAssertEqual(t, s, accuracy: abs(t) * 0.02 + 1e-9)
    }
}

final class BaselineCorrectionTests: XCTestCase {
    func testCorrectionDrivesFinalVelocityTowardsZero() {
        var samples = SyntheticMotion.sine(frequency: 1, seconds: 20, sampleRate: 100).samples
        for i in samples.indices { samples[i] += 0.05 }     // a bias the ground cannot have

        let corrected = BaselineCorrection.iterative(samples, sampleRate: 100, iterations: 4)
        let velocity = Integration.trapezoidal(corrected, dt: 0.01)
        let uncorrectedVelocity = Integration.trapezoidal(samples, dt: 0.01)

        XCTAssertLessThan(abs(velocity.last!), abs(uncorrectedVelocity.last!) * 0.1)
    }
}

final class ReservoirSamplingTests: XCTestCase {
    func testKeepsEverythingWhileUnderCapacity() {
        var sampler = ReservoirSampler<Int>(capacity: 10)
        sampler.add(contentsOf: Array(0..<7))
        XCTAssertEqual(sampler.reservoir.count, 7)
        XCTAssertFalse(sampler.isSaturated)
        XCTAssertEqual(sampler.retentionFraction, 1.0, accuracy: 1e-12)
    }

    func testStaysBoundedOverALongStream() {
        var sampler = ReservoirSampler<Int>(capacity: 100)
        sampler.add(contentsOf: Array(0..<1_000_000))
        XCTAssertEqual(sampler.reservoir.count, 100)
        XCTAssertEqual(sampler.seen, 1_000_000)
        XCTAssertLessThan(sampler.retentionFraction, 0.001)
    }

    func testSampleIsSpreadAcrossTheWholeStreamNotJustTheStart() {
        var sampler = ReservoirSampler<Int>(capacity: 200, seed: 12345)
        sampler.add(contentsOf: Array(0..<100_000))
        let late = sampler.reservoir.filter { $0 > 50_000 }.count
        // A biased implementation would keep only the first 200 items.
        XCTAssertGreaterThan(late, 60)
        XCTAssertLessThan(late, 140)
    }
}

final class DecimationTests: XCTestCase {
    func testDouglasPeuckerKeepsEndpointsAndReducesCount() {
        let points = (0..<1000).map { (x: Double($0), y: sin(Double($0) * 0.01)) }
        let out = Decimation.douglasPeucker(points, tolerance: 0.01)
        XCTAssertLessThan(out.count, points.count)
        XCTAssertEqual(out.first!.x, 0)
        XCTAssertEqual(out.last!.x, 999)
    }

    func testDouglasPeuckerNeverLosesThePeak() {
        // A single spike buried in a flat trace — exactly the case naive
        // subsampling destroys, and exactly the case that matters most here.
        var points = (0..<2000).map { (x: Double($0), y: 0.0) }
        points[1234] = (x: 1234, y: 9.81)
        let out = Decimation.forDisplay(
            Waveform(samples: points.map(\.y), sampleRate: 100), targetPoints: 200)
        XCTAssertTrue(out.contains { abs($0.y - 9.81) < 1e-9 },
                      "the peak was decimated away")
    }

    func testForDisplayIsANoOpWhenAlreadyShortEnough() {
        let w = Waveform(samples: [1, 2, 3, 4], sampleRate: 10)
        XCTAssertEqual(Decimation.forDisplay(w, targetPoints: 100).count, 4)
    }

    func testMinMaxPreservesTheTrueEnvelope() {
        let w = SyntheticMotion.sine(frequency: 10, seconds: 10, sampleRate: 1000, amplitude: 3)
        let columns = Decimation.minMax(w, columns: 100)
        XCTAssertEqual(columns.count, 100, accuracy: 1)
        XCTAssertEqual(columns.map(\.max).max()!, 3, accuracy: 0.02)
        XCTAssertEqual(columns.map(\.min).min()!, -3, accuracy: 0.02)
    }
}

private func XCTAssertEqual(_ a: Int, _ b: Int, accuracy: Int,
                            file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertLessThanOrEqual(abs(a - b), accuracy, file: file, line: line)
}
