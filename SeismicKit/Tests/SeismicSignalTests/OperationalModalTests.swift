import XCTest
import SeismicCore
@testable import SeismicSignal

/// Operational modal analysis: measuring a building from its ordinary wobble.
///
/// Every test here builds a signal whose answer is known exactly — a sum of
/// damped sinusoids at frequencies and dampings written into the test — and
/// checks the algorithm recovers them. That is the only honest way to test an
/// identification method: run it on real data and you can only check it against
/// another algorithm, which tells you they agree and nothing about whether
/// either is right.
final class OperationalModalTests: XCTestCase {

    // MARK: Helpers

    /// A decaying sinusoid: A·e^(−ζωt)·sin(ω√(1−ζ²)·t).
    private func decay(frequency: Double, damping: Double, amplitude: Double = 1,
                       sampleRate: Double, seconds: Double, phase: Double = 0) -> [Double] {
        let omega = 2 * Double.pi * frequency
        let damped = omega * (1 - damping * damping).squareRoot()
        let count = Int(seconds * sampleRate)
        return (0..<count).map { i in
            let t = Double(i) / sampleRate
            return amplitude * exp(-damping * omega * t) * sin(damped * t + phase)
        }
    }

    private func noise(count: Int, sigma: Double, seed: UInt64) -> [Double] {
        var rng = SeededRandom(seed: seed)
        return (0..<count).map { _ in rng.gaussian(mean: 0, sd: sigma) }
    }

    // MARK: 64 — Prony

    func testPronyRecoversASingleDampedSinusoid() {
        let signal = decay(frequency: 1.25, damping: 0.03, sampleRate: 100, seconds: 12)
        let poles = PronyAnalysis.poles(of: signal, sampleRate: 100, order: 6)

        guard let found = poles.min(by: { abs($0.frequency - 1.25) < abs($1.frequency - 1.25) })
        else { return XCTFail("No pole recovered at all.") }
        XCTAssertEqual(found.frequency, 1.25, accuracy: 0.01)
        XCTAssertEqual(found.damping, 0.03, accuracy: 0.008)
    }

    /// The case single-channel peak picking cannot do: two modes close enough
    /// that one spectral hump covers both.
    func testPronySeparatesTwoNearbyModes() {
        let a = decay(frequency: 1.10, damping: 0.02, amplitude: 1.0,
                      sampleRate: 100, seconds: 20)
        let b = decay(frequency: 1.32, damping: 0.04, amplitude: 0.8,
                      sampleRate: 100, seconds: 20, phase: 0.7)
        let signal = zip(a, b).map(+)

        let poles = PronyAnalysis.poles(of: signal, sampleRate: 100, order: 10)
        let frequencies = poles.map(\.frequency)

        XCTAssertTrue(frequencies.contains { abs($0 - 1.10) < 0.03 },
                      "Missed the 1.10 Hz mode. Found: \(frequencies)")
        XCTAssertTrue(frequencies.contains { abs($0 - 1.32) < 0.03 },
                      "Missed the 1.32 Hz mode. Found: \(frequencies)")
    }

    func testPronyRecoversDampingIndependentlyOfFrequency() {
        // Same frequency, four times the damping. Damping has to move and
        // frequency must not.
        let light = PronyAnalysis.poles(
            of: decay(frequency: 2.0, damping: 0.01, sampleRate: 200, seconds: 15),
            sampleRate: 200, order: 6)
        let heavy = PronyAnalysis.poles(
            of: decay(frequency: 2.0, damping: 0.04, sampleRate: 200, seconds: 15),
            sampleRate: 200, order: 6)

        let lightPole = light.min { abs($0.frequency - 2) < abs($1.frequency - 2) }
        let heavyPole = heavy.min { abs($0.frequency - 2) < abs($1.frequency - 2) }
        XCTAssertNotNil(lightPole); XCTAssertNotNil(heavyPole)
        XCTAssertEqual(lightPole?.frequency ?? 0, 2.0, accuracy: 0.02)
        XCTAssertEqual(heavyPole?.frequency ?? 0, 2.0, accuracy: 0.02)
        XCTAssertGreaterThan(heavyPole?.damping ?? 0, (lightPole?.damping ?? 1) * 2)
    }

    /// A building does not gain energy after the shaking stops, so a pole that
    /// says it does is a fitting artefact and must be discarded.
    func testGrowingPolesAreRejected() {
        let signal = noise(count: 2_000, sigma: 1, seed: 7)
        let poles = PronyAnalysis.poles(of: signal, sampleRate: 100, order: 14)
        XCTAssertTrue(poles.allSatisfy { $0.damping >= 0 })
    }

    func testTooShortASignalReturnsNothingRatherThanNonsense() {
        XCTAssertTrue(PronyAnalysis.poles(of: [1, 2, 3], sampleRate: 100, order: 8).isEmpty)
    }

    // MARK: Durand–Kerner

    func testRootFinderRecoversKnownRealRoots() {
        // (z − 2)(z + 3) = z² + z − 6
        let roots = PronyAnalysis.durandKerner(
            [Complex(1, 0), Complex(1, 0), Complex(-6, 0)])
        let real = roots.map(\.re).sorted()
        XCTAssertEqual(real.count, 2)
        XCTAssertEqual(real[0], -3, accuracy: 1e-6)
        XCTAssertEqual(real[1], 2, accuracy: 1e-6)
    }

    func testRootFinderRecoversAComplexConjugatePair() {
        // z² + 1 → ±i. A real mode is exactly this shape, so failing here would
        // mean finding no modes at all.
        let roots = PronyAnalysis.durandKerner(
            [Complex(1, 0), Complex(0, 0), Complex(1, 0)])
        XCTAssertEqual(roots.count, 2)
        for root in roots {
            XCTAssertEqual(root.re, 0, accuracy: 1e-6)
            XCTAssertEqual(abs(root.im), 1, accuracy: 1e-6)
        }
    }

    // MARK: 65 — Stabilisation

    func testStabilisationKeepsThePhysicalModeAndRanksItHighest() {
        var signal = decay(frequency: 1.4, damping: 0.025, sampleRate: 100, seconds: 25)
        for (i, value) in noise(count: signal.count, sigma: 0.02, seed: 21).enumerated() {
            signal[i] += value
        }

        let stable = StabilisationDiagram.run(signal, sampleRate: 100)
        guard let best = stable.first else { return XCTFail("Nothing survived.") }
        XCTAssertEqual(best.frequency, 1.4, accuracy: 0.05)
        XCTAssertGreaterThan(best.appearances, 3)
        XCTAssertGreaterThan(best.stability, 0.4)
    }

    /// Pure noise has no physical modes, so nothing should come back looking
    /// stable. This is the test that matters: an identification method that
    /// finds confident modes in noise is worse than one that finds none.
    func testNoiseProducesNothingConfident() {
        let stable = StabilisationDiagram.run(noise(count: 3_000, sigma: 1, seed: 99),
                                              sampleRate: 100)
        XCTAssertTrue(stable.allSatisfy { $0.stability < 0.75 },
                      "A pole in pure noise reached stability "
                      + "\(stable.map(\.stability).max() ?? 0).")
    }

    // MARK: 63 — FDD

    func testFDDPutsItsPeakAtTheDrivingFrequency() {
        let rate = 100.0
        let seconds = 40.0
        let count = Int(rate * seconds)
        // One mode, present on all three channels in a fixed ratio — which is
        // what a mode shape *is*.
        let base = (0..<count).map { i -> Double in
            sin(2 * Double.pi * 2.0 * Double(i) / rate)
        }
        let noiseX = noise(count: count, sigma: 0.05, seed: 1)
        let noiseY = noise(count: count, sigma: 0.05, seed: 2)
        let noiseZ = noise(count: count, sigma: 0.05, seed: 3)

        let record = TriaxialRecord(
            x: Waveform(samples: zip(base, noiseX).map { $0 * 1.0 + $1 }, sampleRate: rate),
            y: Waveform(samples: zip(base, noiseY).map { $0 * 0.6 + $1 }, sampleRate: rate),
            z: Waveform(samples: zip(base, noiseZ).map { $0 * 0.1 + $1 }, sampleRate: rate))

        guard let result = FrequencyDomainDecomposition.run(record, segmentLength: 512) else {
            return XCTFail("FDD produced nothing.")
        }
        guard let peak = result.firstSingularValues.indices
            .max(by: { result.firstSingularValues[$0] < result.firstSingularValues[$1] })
        else { return XCTFail("No peak.") }
        XCTAssertEqual(result.frequencies[peak], 2.0, accuracy: 0.3)
    }

    func testFDDRecoversTheModeShapeAcrossChannels() {
        let rate = 100.0
        let count = 8_000
        let base = (0..<count).map { sin(2 * Double.pi * 2.0 * Double($0) / rate) }
        let record = TriaxialRecord(
            x: Waveform(samples: base.map { $0 * 1.0 }, sampleRate: rate),
            y: Waveform(samples: base.map { $0 * 0.5 }, sampleRate: rate),
            z: Waveform(samples: base.map { $0 * 0.2 }, sampleRate: rate))

        guard let result = FrequencyDomainDecomposition.run(record, segmentLength: 512),
              let peak = result.firstSingularValues.indices
                .max(by: { result.firstSingularValues[$0] < result.firstSingularValues[$1] })
        else { return XCTFail("FDD produced nothing.") }

        // Normalised to the largest component, so the shape should read 1, 0.5, 0.2.
        let shape = result.dominantShapes[peak]
        XCTAssertEqual(shape[0], 1.0, accuracy: 0.08)
        XCTAssertEqual(shape[1], 0.5, accuracy: 0.08)
        XCTAssertEqual(shape[2], 0.2, accuracy: 0.08)
    }

    func testFDDRefusesARecordShorterThanOneSegment() {
        let short = TriaxialRecord.zeros(count: 100, sampleRate: 100)
        XCTAssertNil(FrequencyDomainDecomposition.run(short, segmentLength: 1024))
    }

    // MARK: 66 — MAC

    func testMACIsOneForTheSameShapeAtAnyScale() {
        let shape = [0.2, 0.5, 0.8, 1.0]
        XCTAssertEqual(ModeShapeComparison.mac(shape, shape), 1, accuracy: 1e-12)
        XCTAssertEqual(ModeShapeComparison.mac(shape, shape.map { $0 * 37 }), 1, accuracy: 1e-12)
        // And for a sign flip, which is the same physical motion half a cycle later.
        XCTAssertEqual(ModeShapeComparison.mac(shape, shape.map { -$0 }), 1, accuracy: 1e-12)
    }

    func testMACIsZeroForOrthogonalShapes() {
        XCTAssertEqual(ModeShapeComparison.mac([1, 0], [0, 1]), 0, accuracy: 1e-12)
    }

    func testMACFallsAsShapesDiverge() {
        let baseline = [0.2, 0.5, 0.8, 1.0]
        let slight = [0.22, 0.52, 0.79, 1.0]
        let severe = [0.9, 0.7, 0.4, 1.0]
        XCTAssertGreaterThan(ModeShapeComparison.mac(baseline, slight),
                             ModeShapeComparison.mac(baseline, severe))
    }

    func testMACMatrixPairsModesByShapeNotByPosition() {
        let before = [[1.0, 0.5, 0.2], [0.2, -0.9, 1.0]]
        // The same two modes, swapped in the list — which is what happens when
        // one briefly overtakes the other in amplitude.
        let after = [[0.2, -0.9, 1.0], [1.0, 0.5, 0.2]]
        let matrix = ModeShapeComparison.macMatrix(before, after)
        XCTAssertGreaterThan(matrix[0][1], 0.99)
        XCTAssertGreaterThan(matrix[1][0], 0.99)
        XCTAssertLessThan(matrix[0][0], 0.5)
    }

    // MARK: 67 — COMAC

    func testCOMACIsOneEverywhereWhenNothingHasChanged() {
        let modes = [[0.2, 0.5, 0.8, 1.0], [1.0, 0.3, -0.6, -1.0]]
        for storey in ModeShapeComparison.comac(before: modes, after: modes) {
            XCTAssertEqual(storey.value, 1, accuracy: 1e-9)
        }
    }

    func testCOMACDipsAtTheStoreyThatChanged() {
        let before = [[0.2, 0.5, 0.8, 1.0], [1.0, 0.3, -0.6, -1.0]]
        // Storey 2 stops participating in the first mode while carrying on
        // unchanged in the second — which is what a local stiffness loss
        // actually does, because the two modes reshape differently around it.
        let after = [[0.2, 0.05, 0.8, 1.0], [1.0, 0.3, -0.6, -1.0]]

        let values = ModeShapeComparison.comac(before: before, after: after)
        XCTAssertEqual(values.count, 4)
        XCTAssertLessThan(values[1].value, 0.6)
        for other in [0, 2, 3] {
            XCTAssertGreaterThan(values[other].value, 0.95)
        }
        XCTAssertEqual(ModeShapeComparison.mostChangedStorey(values)?.storey, 2)
    }

    /// The limitation, written down rather than discovered later.
    ///
    /// COMAC compares the *pattern across modes* at each coordinate, and that
    /// comparison is normalised — so a storey whose amplitude shrinks by the
    /// same factor in every mode reads as unchanged. It is not a bug and it
    /// cannot be tuned away; it is what the ratio in the formula does. It
    /// matters because a real measurement is scaled by whatever happened to be
    /// exciting the building that night, so a uniform amplitude change is
    /// exactly the thing COMAC is *designed* to ignore. Localisation therefore
    /// depends on the modes reshaping relative to each other, which real damage
    /// does and a windier night does not.
    func testCOMACIsBlindToAUniformAmplitudeChangeAtOneStorey() {
        let before = [[0.2, 0.5, 0.8, 1.0], [1.0, 0.3, -0.6, -1.0]]
        let scale = 0.04
        let after = [[0.2, 0.5 * scale, 0.8, 1.0], [1.0, 0.3 * scale, -0.6, -1.0]]

        let values = ModeShapeComparison.comac(before: before, after: after)
        XCTAssertGreaterThan(values[1].value, 0.9,
                             "COMAC unexpectedly reacted to a uniform per-coordinate scale.")
    }

    /// The important negative: a building where nothing stands out must not be
    /// given a floor number. Reporting "storey four" because it rounded lowest
    /// is inventing a finding.
    func testCOMACNamesNoStoreyWhenNoneStandsOut() {
        let before = [[0.2, 0.5, 0.8, 1.0], [1.0, 0.3, -0.6, -1.0]]
        let after = [[0.21, 0.49, 0.81, 0.99], [0.99, 0.31, -0.59, -1.0]]
        XCTAssertNil(ModeShapeComparison.mostChangedStorey(
            ModeShapeComparison.comac(before: before, after: after)))
    }

    func testCOMACNeedsTwoModesToSayAnything() {
        let one = [[0.2, 0.5, 0.8, 1.0]]
        XCTAssertTrue(ModeShapeComparison.comac(before: one, after: one).isEmpty)
    }
}
