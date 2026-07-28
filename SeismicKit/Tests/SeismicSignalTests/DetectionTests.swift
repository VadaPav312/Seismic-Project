import XCTest
@testable import SeismicSignal
import SeismicCore

// Algorithms 9–14.

final class STALTATests: XCTestCase {

    /// Quiet, then a burst. The trigger must fire, and only once.
    private func quietThenBurst(sampleRate: Double = 100) -> Waveform {
        var rng = SeededRandom(seed: 11)
        var samples = (0..<Int(30 * sampleRate)).map { _ in rng.gaussian(sd: 0.005) }
        let onset = Int(20 * sampleRate)
        for i in onset..<samples.count {
            let t = Double(i - onset) / sampleRate
            let envelope = t < 0.5 ? t / 0.5 : exp(-(t - 0.5) / 2.0)
            samples[i] += envelope * 0.8 * sin(2 * .pi * 3 * t)
        }
        return Waveform(samples: samples, sampleRate: sampleRate)
    }

    func testClassicTriggersOnAnEventAndNotOnNoise() {
        let quiet = SyntheticMotion.ambient(seconds: 60, noiseFloor: 0.005, seed: 3)
        XCTAssertFalse(STALTA.classic(quiet).didTrigger, "triggered on pure noise")

        let result = STALTA.classic(quietThenBurst())
        XCTAssertTrue(result.didTrigger)
        XCTAssertEqual(result.triggeredAt.count, 1, "one event must produce one trigger")
        XCTAssertEqual(result.triggeredAt[0], 20.0, accuracy: 1.0)
        XCTAssertGreaterThan(result.peakRatio, 4)
    }

    func testRecursiveAgreesWithClassicOnWhetherToTrigger() {
        let w = quietThenBurst()
        let classic = STALTA.classic(w)
        let recursive = STALTA.recursive(w)
        XCTAssertTrue(recursive.didTrigger)
        XCTAssertEqual(recursive.triggeredAt[0], classic.triggeredAt[0], accuracy: 2.0)
    }

    func testRatioIsScaleFree() {
        // Doubling the amplitude of everything must not change the ratio, which
        // is the entire reason STA/LTA is used instead of a fixed threshold.
        let w = quietThenBurst()
        let loud = Waveform(samples: w.samples.map { $0 * 25 }, sampleRate: w.sampleRate)
        let a = STALTA.classic(w).peakRatio
        let b = STALTA.classic(loud).peakRatio
        XCTAssertEqual(a, b, accuracy: a * 0.02)
    }

    func testDetriggerUsesHysteresisSoOneEventIsNotSplit() {
        let result = STALTA.classic(quietThenBurst())
        XCTAssertEqual(result.triggeredAt.count, result.detriggeredAt.count)
        for (t, d) in zip(result.triggeredAt, result.detriggeredAt) {
            XCTAssertGreaterThan(d, t)
        }
    }

    func testConfigClampsNonsensicalSettings() {
        let c = STALTAConfig(shortWindow: -5, longWindow: 0.001,
                             triggerThreshold: 0.5, detriggerThreshold: 99)
        XCTAssertGreaterThan(c.shortWindow, 0)
        XCTAssertGreaterThan(c.longWindow, c.shortWindow)
        XCTAssertGreaterThan(c.triggerThreshold, 1)
        XCTAssertLessThan(c.detriggerThreshold, c.triggerThreshold)
    }

    func testShortRecordDoesNotCrashAndDoesNotTrigger() {
        let tiny = Waveform(samples: [0.1, 0.2, 0.3], sampleRate: 100)
        XCTAssertFalse(STALTA.classic(tiny).didTrigger)
        XCTAssertFalse(STALTA.recursive(tiny).didTrigger)
    }
}

final class ArrivalPickerTests: XCTestCase {

    func testAICFindsAKnownOnsetToWithinAFewSamples() {
        var rng = SeededRandom(seed: 77)
        let sampleRate = 100.0
        let onsetIndex = 1500
        // Stationary noise, then stationary signal — the canonical case AIC is
        // derived for. (Applied to a whole record with a long decaying coda it
        // needs a search window; that path is covered by `pickP`.)
        var samples = (0..<4000).map { _ in rng.gaussian(sd: 0.01) }
        for i in onsetIndex..<samples.count {
            let t = Double(i - onsetIndex) / sampleRate
            samples[i] += 0.5 * sin(2 * .pi * 6 * t)
        }

        let pick = ArrivalPicker.aicPick(samples)
        XCTAssertNotNil(pick)
        // Within a tenth of a second of the true onset.
        XCTAssertEqual(Double(pick!.index), Double(onsetIndex), accuracy: 10)
        XCTAssertGreaterThan(pick!.confidence, 0)
        XCTAssertEqual(pick!.curve.count, samples.count)
    }

    func testAICPickBeatsASimpleAmplitudeThreshold() {
        var rng = SeededRandom(seed: 5)
        let onsetIndex = 2000
        var samples = (0..<5000).map { _ in rng.gaussian(sd: 0.01) }
        for i in onsetIndex..<samples.count {
            let t = Double(i - onsetIndex) / 100.0
            // Slow build-up: a threshold detector fires late by design.
            samples[i] += min(t / 2, 1) * 0.4 * sin(2 * .pi * 5 * t)
        }
        let aic = ArrivalPicker.aicPick(samples)!.index
        let threshold = samples.firstIndex { abs($0) > 0.1 } ?? samples.count

        XCTAssertLessThan(abs(aic - onsetIndex), abs(threshold - onsetIndex))
    }

    func testPickPOnASyntheticRecordLandsNearTheTruePArrival() {
        let params = SyntheticMotion.EventParameters(magnitude: 6.0, distanceKm: 40,
                                                     preEventSeconds: 15, seed: 909)
        let rec = SyntheticMotion.generate(params)
        let pick = ArrivalPicker.pickP(rec.z)
        XCTAssertNotNil(pick)
        XCTAssertEqual(pick!.time, params.preEventSeconds, accuracy: 3.0)
    }

    func testShortRecordReturnsNilRatherThanGuessing() {
        XCTAssertNil(ArrivalPicker.aicPick([1, 2, 3]))
        XCTAssertNil(ArrivalPicker.pickP(Waveform(samples: [1, 2], sampleRate: 100)))
    }
}

final class PolarisationTests: XCTestCase {

    func testRectilinearityIsHighForLinearMotionAndLowForCircular() {
        let n = 2000
        let sampleRate = 100.0

        // Purely linear: all motion on one axis.
        let linear = TriaxialRecord(
            x: SyntheticMotion.sine(frequency: 3, seconds: 20, sampleRate: sampleRate),
            y: Waveform(samples: [Double](repeating: 0, count: n), sampleRate: sampleRate),
            z: Waveform(samples: [Double](repeating: 0, count: n), sampleRate: sampleRate))
        let linearScore = Stats.mean(PolarisationAnalysis.rectilinearity(linear).samples)
        XCTAssertGreaterThan(linearScore, 0.85)

        // Circular: energy shared equally between two axes in quadrature.
        let circular = TriaxialRecord(
            x: SyntheticMotion.sine(frequency: 3, seconds: 20, sampleRate: sampleRate),
            y: SyntheticMotion.sine(frequency: 3, seconds: 20, sampleRate: sampleRate,
                                    phase: .pi / 2),
            z: Waveform(samples: [Double](repeating: 0, count: n), sampleRate: sampleRate))
        let circularScore = Stats.mean(PolarisationAnalysis.rectilinearity(circular).samples)
        XCTAssertLessThan(circularScore, linearScore)
    }

    func testPickArrivalsFindsPBeforeS() {
        let params = SyntheticMotion.EventParameters(magnitude: 6.5, distanceKm: 60,
                                                     preEventSeconds: 15, seed: 31337)
        let rec = SyntheticMotion.generate(params)
        let picks = PolarisationAnalysis.pickArrivals(rec)

        XCTAssertNotNil(picks.pTime)
        if let p = picks.pTime, let s = picks.sTime {
            XCTAssertGreaterThan(s, p, "S cannot arrive before P")
            // The true S−P for this geometry, within a generous tolerance.
            XCTAssertEqual(s - p, params.sMinusP, accuracy: params.sMinusP * 0.7 + 2)
        }
    }

    func testSMinusPIsNilWhenSWasNotPicked() {
        var picks = ArrivalPicks(pTime: 5)
        XCTAssertNil(picks.sMinusP)
        picks.sTime = 9
        XCTAssertEqual(picks.sMinusP!, 4, accuracy: 1e-12)
        picks.sTime = 3            // S before P is impossible
        XCTAssertNil(picks.sMinusP)
    }
}

final class SensorFusionTests: XCTestCase {

    func testUnanimousAgreementIsAccepted() {
        let votes = SensorFusion.buildVotes(accelerationRatio: 9, tiltChanged: true,
                                            soundLevel: 0.8, triggerThreshold: 4)
        let decision = SensorFusion.vote(votes)
        XCTAssertTrue(decision.accepted)
        XCTAssertEqual(decision.confidence, 1.0, accuracy: 1e-9)
        XCTAssertTrue(decision.dissenting.isEmpty)
        XCTAssertEqual(decision.explanation, "Every sensor agreed.")
    }

    func testAccelerometerAloneIsNotEnough() {
        // The accelerometer carries 0.6 of the weight — exactly the threshold,
        // so it passes alone but only just. With a stricter requirement it must
        // not.
        let votes = SensorFusion.buildVotes(accelerationRatio: 9, tiltChanged: false,
                                            soundLevel: 0.05, triggerThreshold: 4)
        XCTAssertFalse(SensorFusion.vote(votes, requiredConfidence: 0.7).accepted)
    }

    func testCorroboratedAccelerometerIsAccepted() {
        let votes = SensorFusion.buildVotes(accelerationRatio: 9, tiltChanged: true,
                                            soundLevel: 0.05, triggerThreshold: 4)
        let decision = SensorFusion.vote(votes, requiredConfidence: 0.7)
        XCTAssertTrue(decision.accepted)
        XCTAssertEqual(decision.agreeing.count, 2)
    }

    func testNoSensorsGivesAnHonestAnswerRatherThanACrash() {
        let decision = SensorFusion.vote([])
        XCTAssertFalse(decision.accepted)
        XCTAssertEqual(decision.confidence, 0)
        XCTAssertFalse(decision.explanation.isEmpty)
    }

    func testChannelsWithNoVotingWeightAreIgnored() {
        let votes = [SensorVote(channel: .rtc, agreed: true, value: 1),
                     SensorVote(channel: .accelerometer, agreed: true, value: 9)]
        let decision = SensorFusion.vote(votes)
        XCTAssertEqual(decision.agreeing, [.accelerometer])
    }
}

final class FalseTriggerRejectionTests: XCTestCase {

    func testRealEarthquakeIsAccepted() {
        let rec = SyntheticMotion.generate(
            .init(magnitude: 6.3, distanceKm: 35, preEventSeconds: 10, seed: 2024))
        let verdict = FalseTriggerRejection.classify(rec)
        XCTAssertTrue(verdict.isEarthquake, "rejected a real earthquake: \(verdict.reason)")
        XCTAssertNil(verdict.matchedNuisance)
    }

    func testDoorSlamIsRejected() {
        let verdict = FalseTriggerRejection.classify(SyntheticMotion.nuisance(.doorSlam))
        XCTAssertFalse(verdict.isEarthquake)
        XCTAssertNotNil(verdict.matchedNuisance)
    }

    func testEveryNuisanceSourceIsRejected() {
        for kind in SyntheticMotion.Nuisance.allCases {
            let verdict = FalseTriggerRejection.classify(SyntheticMotion.nuisance(kind, seed: 7))
            XCTAssertFalse(verdict.isEarthquake, "\(kind.label) was mistaken for an earthquake")
        }
    }

    func testFeatureExtractionIsSaneOnAnEmptyRecord() {
        let empty = TriaxialRecord.zeros(count: 100, sampleRate: 100)
        let f = FalseTriggerRejection.features(of: empty)
        XCTAssertEqual(f.peak, 0, accuracy: 1e-12)
        XCTAssertFalse(FalseTriggerRejection.classify(f).isEarthquake)
    }

    func testEveryNuisanceSignatureExplainsItself() {
        for sig in FalseTriggerRejection.nuisanceLibrary {
            XCTAssertFalse(sig.guidance.isEmpty)
            XCTAssertFalse(sig.name.isEmpty)
        }
    }
}
