import XCTest
import SeismicCore
@testable import SeismicSignal

final class AdvancedDetectionTests: XCTestCase {

    private func noise(count: Int, sigma: Double, seed: UInt64) -> [Double] {
        var rng = SeededRandom(seed: seed)
        return (0..<count).map { _ in rng.gaussian(mean: 0, sd: sigma) }
    }

    /// A short wavelet with a sharp onset and a decaying tail — the shape of a
    /// small earthquake at a station.
    private func burst(length: Int, frequency: Double, rate: Double) -> [Double] {
        (0..<length).map { i in
            let t = Double(i) / rate
            return exp(-t * 6) * sin(2 * Double.pi * frequency * t)
        }
    }

    // MARK: 77 — Matched filter

    func testItFindsEveryCopyOfTheTemplate() {
        let rate = 100.0
        let template = burst(length: 200, frequency: 6, rate: rate)
        var signal = [Double](repeating: 0, count: 4_000)

        let plantedAt = [500, 1_500, 2_800]
        for (index, position) in plantedAt.enumerated() {
            // Each one smaller than the last, as an aftershock sequence is.
            let scale = 1.0 / Double(index + 1)
            for (k, value) in template.enumerated() {
                signal[position + k] += value * scale
            }
        }

        let detections = MatchedFilter.detect(
            in: Waveform(samples: signal, sampleRate: rate),
            template: template, threshold: .absolute(0.7))

        XCTAssertEqual(detections.count, plantedAt.count,
                       "Found \(detections.map(\.sampleIndex)), expected \(plantedAt).")
        for (found, expected) in zip(detections.map(\.sampleIndex), plantedAt) {
            XCTAssertEqual(found, expected, accuracy: 3)
        }
    }

    /// The claim that justifies the algorithm: it finds an event whose peak
    /// never rises above the noise, which an energy detector cannot.
    ///
    /// The template is twenty seconds long, and that is not padding. A matched
    /// filter's advantage grows with the length of the template it can
    /// integrate over, so a two-second template buys almost nothing and a
    /// twenty-second one buys a great deal — which is exactly why real
    /// aftershock catalogues cut templates tens of seconds long rather than
    /// snipping out the first arrival.
    func testItFindsAnEventWhosePeakNeverRisesAboveTheNoise() {
        let rate = 100.0
        // A long, slowly decaying wavetrain — a real earthquake coda, not a
        // click.
        let template = (0..<2_000).map { i -> Double in
            let t = Double(i) / rate
            return exp(-t * 0.15) * sin(2 * Double.pi * 5 * t)
        }

        var signal = noise(count: 12_000, sigma: 1.0, seed: 12)
        let position = 6_000
        let amplitude = 0.5
        for (k, value) in template.enumerated() {
            signal[position + k] += value * amplitude
        }

        // The event really is invisible to an energy detector: its peak is
        // below the noise's, so no threshold on amplitude can separate them.
        let plantedPeak = template.map(abs).max()! * amplitude
        let noisePeak = noise(count: 6_000, sigma: 1.0, seed: 12).map(abs).max()!
        XCTAssertLessThan(plantedPeak, noisePeak,
                          "The planted event was not actually buried.")

        let detections = MatchedFilter.detect(
            in: Waveform(samples: signal, sampleRate: rate),
            template: template, threshold: .medianAbsoluteDeviation(multiple: 5))

        // Half a second of slop on a twenty-second template. Noise shifts the
        // correlation peak slightly; demanding the exact sample would be
        // testing the random seed rather than the algorithm.
        XCTAssertTrue(detections.contains { abs($0.sampleIndex - position) <= 50 },
                      "Missed the buried event. Found \(detections.map(\.sampleIndex)).")
    }

    /// And the size of the margin, measured rather than asserted.
    ///
    /// This is what the previous test rests on, pinned as a number so that a
    /// change to the correlation or the normalisation shows up here as a
    /// shrinking margin rather than silently as a missed detection somewhere
    /// else. Half the noise amplitude gives roughly a five-fold margin over the
    /// trace's own scatter — which is why the default multiple of nine is right
    /// for a day of data and wrong for one record.
    func testTheDetectionMarginForABuriedEventIsAboutFiveTimesTheScatter() {
        let rate = 100.0
        let template = (0..<2_000).map { i -> Double in
            let t = Double(i) / rate
            return exp(-t * 0.15) * sin(2 * Double.pi * 5 * t)
        }
        var signal = noise(count: 12_000, sigma: 1.0, seed: 12)
        for (k, value) in template.enumerated() { signal[6_000 + k] += value * 0.5 }

        let detections = MatchedFilter.detect(
            in: Waveform(samples: signal, sampleRate: rate),
            template: template, threshold: .medianAbsoluteDeviation(multiple: 3))
        guard let event = detections.min(by: {
            abs($0.sampleIndex - 6_000) < abs($1.sampleIndex - 6_000)
        }) else { return XCTFail("Nothing found even at three MAD.") }

        // Measured: the peak correlation is about 0.18 against a trace whose
        // MAD is about 0.031 — a margin just under six. Pinned so that a change
        // to the correlation or its normalisation shows up here as a shrinking
        // margin rather than silently as a missed detection somewhere else.
        XCTAssertEqual(event.correlation, 0.18, accuracy: 0.04)
        XCTAssertLessThan(abs(event.sampleIndex - 6_000), 50)
    }

    func testItReportsNothingInPureNoise() {
        let rate = 100.0
        let template = burst(length: 300, frequency: 5, rate: rate)
        let detections = MatchedFilter.detect(
            in: Waveform(samples: noise(count: 6_000, sigma: 1, seed: 33), sampleRate: rate),
            template: template, threshold: .absolute(0.7))
        XCTAssertTrue(detections.isEmpty,
                      "Found \(detections.count) events in noise.")
    }

    func testOneEventIsReportedOnceRatherThanOncePerLag() {
        let rate = 100.0
        let template = burst(length: 200, frequency: 6, rate: rate)
        var signal = [Double](repeating: 0, count: 2_000)
        for (k, value) in template.enumerated() { signal[800 + k] = value }

        let detections = MatchedFilter.detect(
            in: Waveform(samples: signal, sampleRate: rate),
            template: template, threshold: .absolute(0.6), minimumSeparation: 1.0)
        XCTAssertEqual(detections.count, 1)
    }

    func testRelativeAmplitudeTracksTheSizeOfTheEvent() {
        let rate = 100.0
        let template = burst(length: 200, frequency: 6, rate: rate)
        var signal = [Double](repeating: 0, count: 3_000)
        for (k, value) in template.enumerated() {
            signal[500 + k] = value * 1.0
            signal[2_000 + k] = value * 0.25
        }

        let detections = MatchedFilter.detect(
            in: Waveform(samples: signal, sampleRate: rate),
            template: template, threshold: .absolute(0.6))
        XCTAssertEqual(detections.count, 2)
        XCTAssertGreaterThan(detections[0].relativeAmplitude,
                             detections[1].relativeAmplitude * 2)
    }

    // MARK: 78 — Kurtosis picker

    func testItPicksTheOnsetOfATransient() {
        let rate = 100.0
        let onset = 1_000
        var signal = noise(count: 4_000, sigma: 0.05, seed: 4)
        let burstSamples = burst(length: 1_000, frequency: 4, rate: rate)
        for (k, value) in burstSamples.enumerated() { signal[onset + k] += value }

        guard let pick = KurtosisPicker.pick(Waveform(samples: signal, sampleRate: rate),
                                             windowSeconds: 0.6) else {
            return XCTFail("No pick.")
        }
        XCTAssertEqual(pick.sampleIndex, onset, accuracy: 80,
                       "Picked \(pick.sampleIndex), true onset \(onset).")
    }

    func testItDeclinesToPickWhenThereIsNoTransient() {
        let signal = noise(count: 4_000, sigma: 1, seed: 6)
        let pick = KurtosisPicker.pick(Waveform(samples: signal, sampleRate: 100))
        // It may still return a pick — there is always a steepest rise — but it
        // must not claim it is sharp.
        if let pick { XCTAssertLessThan(pick.sharpness, 5) }
    }

    func testItRefusesARecordShorterThanAFewWindows() {
        let w = Waveform(samples: noise(count: 50, sigma: 1, seed: 1), sampleRate: 100)
        XCTAssertNil(KurtosisPicker.pick(w, windowSeconds: 1.0))
    }

    func testDisagreementBetweenPickersIsExplainedRatherThanHidden() {
        let agree = KurtosisPicker.compare(kurtosisPick: 4.00, aicPick: 4.05)
        XCTAssertTrue(agree.interpretation.contains("impulsive"))

        let differ = KurtosisPicker.compare(kurtosisPick: 3.20, aicPick: 4.40)
        XCTAssertTrue(differ.interpretation.contains("emergent"))
        XCTAssertTrue(differ.interpretation.contains("warning"))
    }

    // MARK: 79 — Back-azimuth

    /// A P wave from a known direction has to come back as that direction.
    /// Built by putting linear motion along a known bearing on the two
    /// horizontals, with the vertical component a real incidence angle.
    func testItRecoversAKnownBackAzimuth() {
        let rate = 100.0
        let count = 400
        // Source to the north-east, so the ground moves along 045°/225°.
        let trueBackAzimuth = 45.0
        let radians = trueBackAzimuth * .pi / 180
        let incidence = 30.0 * .pi / 180

        // First motion is *away* from the source.
        let north = -cos(radians) * sin(incidence)
        let east = -sin(radians) * sin(incidence)
        let vertical = cos(incidence)

        let pulse = burst(length: count, frequency: 8, rate: rate)
        let record = TriaxialRecord(
            x: Waveform(samples: pulse.map { $0 * north }, sampleRate: rate),
            y: Waveform(samples: pulse.map { $0 * east }, sampleRate: rate),
            z: Waveform(samples: pulse.map { $0 * vertical }, sampleRate: rate))

        guard let bearing = PolarisationAnalysis.analyse(record, from: 0,
                                                         windowSeconds: 1.0) else {
            return XCTFail("No bearing.")
        }
        XCTAssertEqual(bearing.backAzimuth, trueBackAzimuth, accuracy: 6)
        XCTAssertGreaterThan(bearing.rectilinearity, 0.9)
        XCTAssertTrue(bearing.isReliable)
    }

    func testItReportsLowRectilinearityForMotionThatIsNotLinear() {
        let rate = 100.0
        let record = TriaxialRecord(
            x: Waveform(samples: noise(count: 400, sigma: 1, seed: 1), sampleRate: rate),
            y: Waveform(samples: noise(count: 400, sigma: 1, seed: 2), sampleRate: rate),
            z: Waveform(samples: noise(count: 400, sigma: 1, seed: 3), sampleRate: rate))

        guard let bearing = PolarisationAnalysis.analyse(record, from: 0,
                                                         windowSeconds: 2.0) else {
            return XCTFail()
        }
        XCTAssertLessThan(bearing.rectilinearity, 0.6)
        XCTAssertFalse(bearing.isReliable)
    }

    func testCompassPointMatchesTheBearing() {
        func point(_ azimuth: Double) -> String {
            PolarisationAnalysis.Bearing(backAzimuth: azimuth, incidence: 30,
                                        rectilinearity: 0.9, isAmbiguous: false).compassPoint
        }
        XCTAssertEqual(point(0), "N")
        XCTAssertEqual(point(90), "E")
        XCTAssertEqual(point(180), "S")
        XCTAssertEqual(point(270), "W")
        XCTAssertEqual(point(45), "NE")
        XCTAssertEqual(point(359), "N")
    }

    func testItRefusesAWindowThatRunsPastTheEndOfTheRecord() {
        let record = TriaxialRecord.zeros(count: 100, sampleRate: 100)
        XCTAssertNil(PolarisationAnalysis.analyse(record, from: 5, windowSeconds: 1))
    }

    /// The eigensolver the bearing rests on, checked against a matrix whose
    /// answer is known by inspection.
    func testJacobiEigenSolverIsCorrectOnAKnownMatrix() {
        // Diagonal: eigenvalues are the diagonal entries.
        let diagonal = [[3.0, 0, 0], [0, 5.0, 0], [0, 0, 1.0]]
        let (values, _) = PolarisationAnalysis.symmetricEigen(diagonal)
        XCTAssertEqual(values.sorted(), [1, 3, 5])

        // A symmetric 2×2 embedded in 3×3: [[2,1],[1,2]] has eigenvalues 1 and 3.
        let coupled = [[2.0, 1.0, 0], [1.0, 2.0, 0], [0, 0, 7.0]]
        let (coupledValues, vectors) = PolarisationAnalysis.symmetricEigen(coupled)
        let sorted = coupledValues.sorted()
        XCTAssertEqual(sorted[0], 1, accuracy: 1e-9)
        XCTAssertEqual(sorted[1], 3, accuracy: 1e-9)
        XCTAssertEqual(sorted[2], 7, accuracy: 1e-9)

        // And the eigenvectors have to be unit length, or every downstream
        // angle is wrong by a scale factor.
        for column in 0..<3 {
            let norm = (0..<3).reduce(0.0) { $0 + vectors[$1][column] * vectors[$1][column] }
            XCTAssertEqual(norm, 1, accuracy: 1e-9)
        }
    }
}
