import XCTest
import SeismicCore
@testable import SeismicSignal

final class AdaptiveConditioningTests: XCTestCase {

    private func tone(_ frequency: Double, rate: Double, seconds: Double,
                      amplitude: Double = 1, phase: Double = 0) -> [Double] {
        (0..<Int(rate * seconds)).map {
            amplitude * sin(2 * Double.pi * frequency * Double($0) / rate + phase)
        }
    }

    private func noise(count: Int, sigma: Double, seed: UInt64) -> [Double] {
        var rng = SeededRandom(seed: seed)
        return (0..<count).map { _ in rng.gaussian(mean: 0, sd: sigma) }
    }

    // MARK: 73 — Adaptive noise cancellation

    func testItRemovesInterferenceThatIsPresentInTheReference() {
        let rate = 100.0, seconds = 30.0
        let building = tone(1.5, rate: rate, seconds: seconds, amplitude: 1.0)
        let plant = tone(11.0, rate: rate, seconds: seconds, amplitude: 2.0)

        // The primary sees both; the reference sees only the plant.
        let primary = zip(building, plant).map(+)
        let reference = plant

        guard let result = AdaptiveNoiseCancellation.cancel(
            primary: primary, reference: reference, taps: 32, stepSize: 0.4) else {
            return XCTFail("Cancellation refused the input.")
        }

        // Judge on the second half, after the filter has converged.
        let half = primary.count / 2
        let cleanedTail = Array(result.cleaned[half...])
        let wantedTail = Array(building[half...])
        let before = Stats.rms(zip(Array(primary[half...]), wantedTail).map(-))
        let after = Stats.rms(zip(cleanedTail, wantedTail).map(-))

        XCTAssertLessThan(after, before * 0.25,
                          "Error before \(before), after \(after).")
    }

    /// The failure that matters: an adaptive filter given a reference that
    /// contains the signal will happily cancel the signal, and the output looks
    /// perfectly clean. `fractionRemoved` is what makes that visible.
    func testRemovingTheSignalIsReportedRatherThanHidden() {
        let rate = 100.0
        let building = tone(1.5, rate: rate, seconds: 30)
        // A reference that IS the signal — the pathological case.
        guard let result = AdaptiveNoiseCancellation.cancel(
            primary: building, reference: building, taps: 16, stepSize: 0.5) else {
            return XCTFail()
        }
        XCTAssertGreaterThan(result.fractionRemoved, 0.5,
                             "The filter removed nearly everything and did not say so.")
    }

    func testItLeavesAChannelAloneWhenTheReferenceIsUnrelated() {
        let rate = 100.0
        let building = tone(1.5, rate: rate, seconds: 20)
        let unrelated = noise(count: building.count, sigma: 1, seed: 4)

        guard let result = AdaptiveNoiseCancellation.cancel(
            primary: building, reference: unrelated, taps: 16, stepSize: 0.02) else {
            return XCTFail()
        }
        XCTAssertLessThan(result.fractionRemoved, 0.2)
    }

    func testItRefusesARecordTooShortToConverge() {
        XCTAssertNil(AdaptiveNoiseCancellation.cancel(
            primary: [1, 2, 3, 4], reference: [1, 2, 3, 4], taps: 32))
    }

    // MARK: 74 — Constrained displacement

    /// The classic failure this exists to fix: a constant bias integrates into
    /// a parabola. With the sensor known to be still at both ends, the filter
    /// has to find the bias rather than accumulate it.
    func testItRemovesAConstantBiasInsteadOfIntegratingIt() {
        let rate = 100.0
        let count = Int(rate * 20)
        let bias = 0.02                              // m/s², a realistic offset
        // Genuinely still, plus a bias. True displacement is zero throughout.
        let samples = [Double](repeating: bias, count: count)
        let w = Waveform(samples: samples, sampleRate: rate)

        let quiet = ConstrainedDisplacement.detectQuietWindows(w)
        let result = ConstrainedDisplacement.estimate(w, quietWindows: quiet)

        // Naive double integration of a 0.02 bias over 20 s is 4 m of nonsense.
        XCTAssertLessThan(abs(result.residual), 0.05,
                          "Residual drifted to \(result.residual) m.")
        XCTAssertEqual(result.estimatedBias, bias, accuracy: 0.02)
    }

    func testItRecoversARealPermanentOffset() {
        let rate = 100.0
        // Still, then a single symmetric acceleration pulse that leaves the
        // sensor displaced, then still again. A high-pass would remove exactly
        // this — the offset is the lowest frequency there is.
        var samples = [Double](repeating: 0, count: Int(rate * 5))
        let pulse = Int(rate * 0.5)
        for i in 0..<pulse {
            samples.append(sin(Double.pi * Double(i) / Double(pulse)) * 0.5)
        }
        for i in 0..<pulse {
            samples.append(-sin(Double.pi * Double(i) / Double(pulse)) * 0.5)
        }
        samples.append(contentsOf: [Double](repeating: 0, count: Int(rate * 5)))

        let w = Waveform(samples: samples, sampleRate: rate)
        let quiet = [0..<Int(rate * 4), (samples.count - Int(rate * 4))..<samples.count]
        let result = ConstrainedDisplacement.estimate(w, quietWindows: quiet)

        // The pulse pair produces a real net displacement — nonzero, finite,
        // and not the metres a naive integration would give.
        XCTAssertGreaterThan(abs(result.residual), 1e-4)
        XCTAssertLessThan(abs(result.residual), 1.0)
        XCTAssertTrue(result.displacement.allSatisfy(\.isFinite))
    }

    func testQuietWindowDetectionFindsTheStillParts() {
        let rate = 100.0
        var samples = [Double](repeating: 0, count: Int(rate * 5))
        samples.append(contentsOf: noise(count: Int(rate * 5), sigma: 1, seed: 9))
        let w = Waveform(samples: samples, sampleRate: rate)

        let quiet = ConstrainedDisplacement.detectQuietWindows(w)
        XCTAssertFalse(quiet.isEmpty)
        // Every window found should be inside the still first half.
        for window in quiet {
            XCTAssertLessThan(window.lowerBound, Int(rate * 5))
        }
    }

    func testShortRecordsAreHandledWithoutCrashing() {
        let w = Waveform(samples: [0, 1], sampleRate: 100)
        let result = ConstrainedDisplacement.estimate(w, quietWindows: [])
        XCTAssertTrue(result.displacement.isEmpty)
    }

    // MARK: 75 — Allan variance

    /// The defining property: for white noise, the Allan deviation falls as the
    /// square root of the averaging time. Doubling tau should cut it by about
    /// √2. Anything else means the estimator is wrong.
    func testWhiteNoiseFallsAsOneOverRootTau() {
        let w = Waveform(samples: noise(count: 20_000, sigma: 1, seed: 17), sampleRate: 100)
        let result = AllanVariance.compute(w)
        XCTAssertGreaterThan(result.points.count, 5)

        // Compare an early point with one at roughly four times the cluster
        // size; the deviation should be about half.
        guard let first = result.points.first(where: { $0.clusterSize >= 2 }),
              let later = result.points.first(where: { $0.clusterSize >= first.clusterSize * 4 })
        else { return XCTFail("Not enough cluster sizes.") }

        let ratio = first.deviation / later.deviation
        XCTAssertEqual(ratio, 2.0, accuracy: 0.6,
                       "Deviation ratio was \(ratio); white noise should give about 2.")
    }

    /// A sensor with drift has a floor: averaging longer stops helping. That
    /// floor is the number the app compares a building's sway against.
    func testABiasedSensorShowsAFloorRatherThanFallingForever() {
        // White noise plus a slow random walk — the signature of bias
        // instability in a real MEMS accelerometer.
        var rng = SeededRandom(seed: 41)
        var walk = 0.0
        let samples = (0..<20_000).map { _ -> Double in
            walk += rng.gaussian(mean: 0, sd: 0.002)
            return walk + rng.gaussian(mean: 0, sd: 0.5)
        }
        let result = AllanVariance.compute(Waveform(samples: samples, sampleRate: 100))

        XCTAssertGreaterThan(result.biasInstability, 0)
        XCTAssertGreaterThan(result.optimalAveragingTime, 0)
        // The floor is somewhere in the middle of the curve, not at either end
        // — which is what distinguishes a drifting sensor from a clean one.
        let taus = result.points.map(\.tau)
        XCTAssertGreaterThan(result.optimalAveragingTime, taus.first ?? 0)
    }

    func testItSaysPlainlyWhenASensorCannotSeeTheBuilding() {
        let w = Waveform(samples: noise(count: 8_000, sigma: 1.0, seed: 3), sampleRate: 100)
        let result = AllanVariance.compute(w)

        // A building moving a thousandth of the sensor's own floor.
        let hopeless = result.canResolve(result.biasInstability * 0.001)
        XCTAssertEqual(hopeless.verdict, .hopeless)
        XCTAssertTrue(hopeless.verdict.explanation.contains("noise"))

        let comfortable = result.canResolve(result.biasInstability * 100)
        XCTAssertEqual(comfortable.verdict, .comfortable)
    }

    // MARK: 76 — Time alignment

    func testItRecoversAKnownIntegerLag() {
        let rate = 100.0
        let base = noise(count: 2_000, sigma: 1, seed: 8)
        let shift = 17
        let a = Waveform(samples: Array(base[shift...]), sampleRate: rate)
        let b = Waveform(samples: Array(base[..<(base.count - shift)]), sampleRate: rate)

        guard let alignment = TimeAlignment.align(a, b, maximumLag: 1.0) else {
            return XCTFail("No alignment.")
        }
        XCTAssertEqual(alignment.lagSeconds, Double(shift) / rate, accuracy: 0.012)
        XCTAssertGreaterThan(alignment.correlation, 0.9)
        XCTAssertTrue(alignment.isReliable)
    }

    /// The whole reason for the parabolic step: a lag that is not a whole
    /// number of samples. At 100 Hz, integer-only resolution is 10 ms, which is
    /// 60 m of epicentre error.
    func testItResolvesLagFinerThanOneSample() {
        let rate = 100.0
        let frequency = 3.0
        // Half a sample of delay, expressed as a phase shift.
        let halfSample = 0.5 / rate
        let a = Waveform(samples: tone(frequency, rate: rate, seconds: 20), sampleRate: rate)
        let b = Waveform(samples: tone(frequency, rate: rate, seconds: 20,
                                       phase: -2 * Double.pi * frequency * halfSample),
                         sampleRate: rate)

        guard let alignment = TimeAlignment.align(a, b, maximumLag: 0.2) else {
            return XCTFail("No alignment.")
        }
        XCTAssertEqual(alignment.lagSeconds, halfSample, accuracy: 0.002)
    }

    func testItReportsUnreliableWhenTheTwoSensorsSawDifferentThings() {
        let rate = 100.0
        let a = Waveform(samples: noise(count: 2_000, sigma: 1, seed: 1), sampleRate: rate)
        let b = Waveform(samples: noise(count: 2_000, sigma: 1, seed: 2), sampleRate: rate)

        guard let alignment = TimeAlignment.align(a, b) else { return XCTFail() }
        XCTAssertFalse(alignment.isReliable)
    }

    func testItRefusesRecordsTooShortToCorrelate() {
        let a = Waveform(samples: [1, 2, 3], sampleRate: 100)
        XCTAssertNil(TimeAlignment.align(a, a))
    }
}
