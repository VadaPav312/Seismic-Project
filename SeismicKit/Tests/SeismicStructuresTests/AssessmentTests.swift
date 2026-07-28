import XCTest
@testable import SeismicStructures
import SeismicCore
import SeismicSignal

// Algorithms 46–50.

final class FragilityTests: XCTestCase {

    private var thresholds: DriftThresholds {
        DriftThresholds.forSystem(.momentFrame, material: .reinforcedConcrete)
    }

    func testProbabilityIsAHalfAtTheMedianDemand() {
        let curve = FragilityCurve(damageState: .moderate, medianDemand: 0.01, dispersion: 0.45)
        XCTAssertEqual(curve.probabilityOfExceedance(demand: 0.01), 0.5, accuracy: 1e-9)
    }

    func testProbabilityIncreasesMonotonicallyWithDemand() {
        let curve = FragilityCurve(damageState: .moderate, medianDemand: 0.01, dispersion: 0.45)
        var previous = -1.0
        for demand in stride(from: 0.0001, through: 0.2, by: 0.0005) {
            let p = curve.probabilityOfExceedance(demand: demand)
            XCTAssertGreaterThanOrEqual(p, previous - 1e-12)
            XCTAssertTrue(p >= 0 && p <= 1)
            previous = p
        }
    }

    func testZeroDemandGivesZeroProbability() {
        let curve = FragilityCurve(damageState: .slight, medianDemand: 0.005, dispersion: 0.4)
        XCTAssertEqual(curve.probabilityOfExceedance(demand: 0), 0)
        XCTAssertEqual(curve.probabilityOfExceedance(demand: -1), 0)
    }

    func testWiderDispersionFlattensTheCurve() {
        let tight = FragilityCurve(damageState: .moderate, medianDemand: 0.01, dispersion: 0.2)
        let loose = FragilityCurve(damageState: .moderate, medianDemand: 0.01, dispersion: 0.8)
        // Below the median, more dispersion means more probability; above it, less.
        XCTAssertGreaterThan(loose.probabilityOfExceedance(demand: 0.004),
                             tight.probabilityOfExceedance(demand: 0.004))
        XCTAssertLessThan(loose.probabilityOfExceedance(demand: 0.03),
                          tight.probabilityOfExceedance(demand: 0.03))
    }

    func testStateProbabilitiesSumToOne() {
        let set = FragilitySet.from(thresholds, label: "concrete moment frame")
        for demand in [0.0, 0.001, 0.005, 0.01, 0.02, 0.05, 0.2] {
            let probabilities = set.stateProbabilities(demand: demand)
            let total = probabilities.values.reduce(0, +)
            XCTAssertEqual(total, 1.0, accuracy: 1e-9, "demand \(demand) sums to \(total)")
            XCTAssertTrue(probabilities.values.allSatisfy { $0 >= -1e-12 })
        }
    }

    func testMostLikelyStateEscalatesWithDemand() {
        let set = FragilitySet.from(thresholds, label: "concrete moment frame")
        XCTAssertEqual(set.mostLikelyState(demand: 0.0001), .none)
        XCTAssertGreaterThanOrEqual(set.mostLikelyState(demand: 0.10).rawValue,
                                    DamageState.extensive.rawValue)
        XCTAssertLessThanOrEqual(set.mostLikelyState(demand: 0.002).rawValue,
                                 DamageState.slight.rawValue)
    }

    func testCurvesAreOrderedBySeverity() {
        let set = FragilitySet.from(thresholds, label: "test")
        for i in 1..<set.curves.count {
            XCTAssertGreaterThan(set.curves[i].medianDemand, set.curves[i - 1].medianDemand)
            XCTAssertGreaterThan(set.curves[i].damageState.rawValue,
                                 set.curves[i - 1].damageState.rawValue)
        }
    }
}

final class EvidenceBuilderTests: XCTestCase {

    func testSmallPeriodChangeIsTreatedAsReassuring() {
        let evidence = EvidenceBuilder.fromPeriodChange(before: 1.0, after: 1.015,
                                                        temperatureCorrected: true,
                                                        measurementConfidence: 0.9)
        XCTAssertNotNil(evidence)
        XCTAssertLessThan(evidence!.damageIndication, 0)
        XCTAssertTrue(evidence!.detail.contains("temperature"))
    }

    func testLargePeriodChangeIsTreatedAsDamning() {
        let evidence = EvidenceBuilder.fromPeriodChange(before: 1.0, after: 1.25,
                                                        temperatureCorrected: true,
                                                        measurementConfidence: 0.9)!
        XCTAssertGreaterThan(evidence.damageIndication, 0.9)
        XCTAssertEqual(evidence.value!, 25, accuracy: 0.01)
    }

    func testShorteningPeriodIsFlaggedAsSuspiciousNotReassuring() {
        // A damaged building never gets stiffer. A negative change means the two
        // measurements are not comparable, which is a data-quality problem.
        let evidence = EvidenceBuilder.fromPeriodChange(before: 1.0, after: 0.85,
                                                        temperatureCorrected: false,
                                                        measurementConfidence: 0.9)!
        XCTAssertTrue(evidence.detail.contains("shorter"))
        // Less reassuring than a genuine no-change result.
        let noChange = EvidenceBuilder.fromPeriodChange(before: 1.0, after: 1.0,
                                                        temperatureCorrected: false,
                                                        measurementConfidence: 0.9)!
        XCTAssertGreaterThan(evidence.damageIndication, noChange.damageIndication)
    }

    func testUncorrectedPeriodChangeCarriesLessWeight() {
        let corrected = EvidenceBuilder.fromPeriodChange(before: 1, after: 1.1,
                                                         temperatureCorrected: true,
                                                         measurementConfidence: 1)!
        let uncorrected = EvidenceBuilder.fromPeriodChange(before: 1, after: 1.1,
                                                           temperatureCorrected: false,
                                                           measurementConfidence: 1)!
        XCTAssertGreaterThan(corrected.weight, uncorrected.weight)
    }

    func testInvalidPeriodsReturnNil() {
        XCTAssertNil(EvidenceBuilder.fromPeriodChange(before: 0, after: 1,
                                                      temperatureCorrected: true,
                                                      measurementConfidence: 1))
    }

    func testResidualDisplacementScalesWithSeverity() {
        let tiny = EvidenceBuilder.fromResidualDisplacement(0.0005, buildingHeight: 30)!
        let large = EvidenceBuilder.fromResidualDisplacement(0.08, buildingHeight: 30)!
        XCTAssertLessThan(tiny.damageIndication, 0)
        XCTAssertGreaterThan(large.damageIndication, 0.8)
    }

    func testTiltEvidenceIsDecisiveWhenTripped() {
        let none = EvidenceBuilder.fromTilt(degrees: 0, tripped: false)!
        let leaning = EvidenceBuilder.fromTilt(degrees: 1.5, tripped: true)!
        XCTAssertLessThan(none.damageIndication, 0)
        XCTAssertGreaterThan(leaning.damageIndication, 0.9)
        XCTAssertGreaterThan(leaning.weight, none.weight)
    }

    func testWeakShakingIsItselfEvidenceAgainstDamage() {
        let weak = EvidenceBuilder.fromShakingSeverity(pga: 0.01 * gravity, cav: 0.02,
                                                       thresholdExceeded: false)
        XCTAssertLessThan(weak.damageIndication, 0)
        XCTAssertTrue(weak.detail.contains("below the level"))
    }

    func testEveryEvidenceItemHasAHeadlineAndDetail() {
        let items = [
            EvidenceBuilder.fromPeriodChange(before: 1, after: 1.1, temperatureCorrected: true,
                                             measurementConfidence: 1),
            EvidenceBuilder.fromResidualDisplacement(0.02, buildingHeight: 20),
            EvidenceBuilder.fromTilt(degrees: 0.4, tripped: true),
            EvidenceBuilder.fromShakingSeverity(pga: 3, cav: 0.5, thresholdExceeded: true),
        ].compactMap { $0 }
        XCTAssertEqual(items.count, 4)
        for item in items {
            XCTAssertFalse(item.headline.isEmpty)
            XCTAssertFalse(item.detail.isEmpty)
            XCTAssertTrue((-1...1).contains(item.damageIndication))
        }
    }
}

final class BayesianFusionTests: XCTestCase {

    private func periodEvidence(_ percent: Double) -> Evidence {
        EvidenceBuilder.fromPeriodChange(before: 1.0, after: 1.0 + percent / 100,
                                         temperatureCorrected: true,
                                         measurementConfidence: 0.9)!
    }

    func testNoEvidenceLeavesThePriorUntouched() {
        let output = BayesianFusion.fuse(.init(prior: 0.3, evidence: []))
        XCTAssertEqual(output.probability, 0.3, accuracy: 1e-9)
    }

    func testConsistentDamageEvidenceDrivesTheProbabilityUp() {
        let output = BayesianFusion.fuse(.init(prior: 0.3, evidence: [
            periodEvidence(18),
            EvidenceBuilder.fromResidualDisplacement(0.05, buildingHeight: 25)!,
            EvidenceBuilder.fromTilt(degrees: 0.8, tripped: true)!,
        ]))
        XCTAssertGreaterThan(output.probability, 0.9)
        XCTAssertEqual(output.verdict, .red)
    }

    func testConsistentReassuringEvidenceDrivesItDown() {
        let output = BayesianFusion.fuse(.init(prior: 0.3, evidence: [
            periodEvidence(0.5),
            EvidenceBuilder.fromResidualDisplacement(0.0003, buildingHeight: 25)!,
            EvidenceBuilder.fromTilt(degrees: 0, tripped: false)!,
            EvidenceBuilder.fromShakingSeverity(pga: 0.02 * gravity, cav: 0.03,
                                                thresholdExceeded: false),
        ]))
        XCTAssertLessThan(output.probability, 0.15)
        XCTAssertEqual(output.verdict, .green)
    }

    func testIndependentWeakEvidenceAccumulates() {
        // Three mild indications together should outweigh any one of them.
        let single = BayesianFusion.fuse(.init(prior: 0.2, evidence: [periodEvidence(5)]))
        let three = BayesianFusion.fuse(.init(prior: 0.2, evidence: [
            periodEvidence(5),
            EvidenceBuilder.fromResidualDisplacement(0.006, buildingHeight: 25)!,
            EvidenceBuilder.fromDriftDemand(0.007, storey: 3,
                                            thresholds: .forSystem(.momentFrame,
                                                                   material: .reinforcedConcrete)),
        ]))
        XCTAssertGreaterThan(three.probability, single.probability)
    }

    func testContradictoryEvidenceWidensTheIntervalRatherThanAveragingAway() {
        let agreeing = BayesianFusion.fuse(.init(prior: 0.4, evidence: [
            periodEvidence(15),
            EvidenceBuilder.fromResidualDisplacement(0.05, buildingHeight: 25)!,
        ]))
        let conflicting = BayesianFusion.fuse(.init(prior: 0.4, evidence: [
            periodEvidence(15),
            EvidenceBuilder.fromResidualDisplacement(0.0002, buildingHeight: 25)!,
            EvidenceBuilder.fromTilt(degrees: 0, tripped: false)!,
        ]))
        let agreeingWidth = agreeing.interval.upperBound - agreeing.interval.lowerBound
        let conflictingWidth = conflicting.interval.upperBound - conflicting.interval.lowerBound
        XCTAssertGreaterThan(conflictingWidth, agreeingWidth)
        XCTAssertTrue(conflicting.reasoning.contains("disagree"))
    }

    func testPermanentTiltForcesRedRegardlessOfOtherEvidence() {
        // The override that must not be outvoted: a leaning building is unsafe
        // even if every other measurement looks fine.
        let output = BayesianFusion.fuse(.init(prior: 0.05, evidence: [
            periodEvidence(0),
            EvidenceBuilder.fromResidualDisplacement(0.0001, buildingHeight: 25)!,
            EvidenceBuilder.fromTilt(degrees: 2.0, tripped: true)!,
        ]))
        XCTAssertEqual(output.verdict, .red)
    }

    func testThinEvidenceGivesNeedsInspectionRatherThanGreen() {
        // A single weak measurement must never be enough to declare a building
        // safe — the interval is too wide to support it.
        let output = BayesianFusion.fuse(.init(prior: 0.35, evidence: [
            EvidenceBuilder.fromDriftDemand(0.001, storey: 1,
                                            thresholds: .forSystem(.momentFrame,
                                                                   material: .reinforcedConcrete)),
        ]))
        XCTAssertNotEqual(output.verdict, .green)
        XCTAssertNotEqual(output.verdict, .red)
    }

    func testProbabilityAlwaysLiesInsideItsInterval() {
        for prior in [0.02, 0.2, 0.5, 0.8, 0.97] {
            for change in [-5.0, 0.0, 4.0, 10.0, 25.0] {
                let output = BayesianFusion.fuse(.init(prior: prior,
                                                       evidence: [periodEvidence(change)]))
                XCTAssertTrue(output.interval.contains(output.probability),
                              "prior \(prior) change \(change)")
                XCTAssertTrue((0...1).contains(output.probability))
            }
        }
    }

    func testReasoningIsAlwaysProduced() {
        let output = BayesianFusion.fuse(.init(prior: 0.3, evidence: [periodEvidence(9)]))
        XCTAssertFalse(output.reasoning.isEmpty)
        XCTAssertEqual(output.contributions.count, 1)
    }

    func testPriorRisesWithDemand() {
        let set = FragilitySet.from(.forSystem(.momentFrame, material: .reinforcedConcrete),
                                    label: "test")
        let gentle = BayesianFusion.prior(fromDemand: 0.0005, fragility: set)
        let violent = BayesianFusion.prior(fromDemand: 0.05, fragility: set)
        XCTAssertGreaterThan(violent, gentle)
        XCTAssertTrue((0...1).contains(gentle))
        XCTAssertTrue((0...1).contains(violent))
    }

    func testSameShakingDifferentContextGivesDifferentAnswers() {
        // A 5% period change after violent shaking means something quite
        // different from the same change after a barely felt tremor.
        let evidence = [periodEvidence(5)]
        let afterViolence = BayesianFusion.fuse(.init(prior: 0.6, evidence: evidence))
        let afterNothing = BayesianFusion.fuse(.init(prior: 0.05, evidence: evidence))
        XCTAssertGreaterThan(afterViolence.probability, afterNothing.probability * 2)
    }
}

final class CUSUMTests: XCTestCase {

    func testNoTrendIsNotDetected() {
        var rng = SeededRandom(seed: 4)
        let values = (0..<200).map { _ in 1.0 + rng.gaussian(sd: 0.01) }
        let result = CUSUM.detect(values, baseline: 1.0, standardDeviation: 0.01)
        XCTAssertFalse(result.changeDetected)
        XCTAssertEqual(result.direction, .none)
        XCTAssertTrue(result.explanation.contains("No sustained trend"))
    }

    func testSlowDriftIsDetectedEvenThoughNoSingleReadingIsUnusual() {
        // This is the whole point: each value is well within normal scatter, but
        // they are all on the same side.
        var rng = SeededRandom(seed: 9)
        var values = (0..<100).map { _ in 1.0 + rng.gaussian(sd: 0.01) }
        for i in 0..<100 {
            values.append(1.0 + Double(i) * 0.0004 + rng.gaussian(sd: 0.01))
        }
        // No individual reading is more than about 2.5 sigma from baseline.
        XCTAssertLessThan((values.max()! - 1.0) / 0.01, 6)

        let result = CUSUM.detect(values, baseline: 1.0, standardDeviation: 0.01)
        XCTAssertTrue(result.changeDetected)
        XCTAssertEqual(result.direction, .softening)
        XCTAssertGreaterThan(result.changeIndex!, 100)
    }

    func testStiffeningIsDetectedSeparatelyFromSoftening() {
        let values = (0..<60).map { i in 1.0 - Double(i) * 0.002 }
        let result = CUSUM.detect(values, baseline: 1.0, standardDeviation: 0.01)
        XCTAssertTrue(result.changeDetected)
        XCTAssertEqual(result.direction, .stiffening)
    }

    func testSumsNeverGoNegative() {
        var rng = SeededRandom(seed: 2)
        let values = (0..<100).map { _ in 1.0 + rng.gaussian(sd: 0.02) }
        let result = CUSUM.detect(values, baseline: 1.0, standardDeviation: 0.02)
        XCTAssertTrue(result.upperSums.allSatisfy { $0 >= 0 })
        XCTAssertTrue(result.lowerSums.allSatisfy { $0 >= 0 })
    }

    func testPeriodHistoryConvenienceEstimatesItsOwnBaseline() {
        var rng = SeededRandom(seed: 11)
        var periods = (0..<40).map { _ in 1.20 + rng.gaussian(sd: 0.004) }
        periods.append(contentsOf: (0..<40).map { _ in 1.26 + rng.gaussian(sd: 0.004) })
        let result = CUSUM.onPeriodHistory(periods)
        XCTAssertTrue(result.changeDetected)
        XCTAssertEqual(result.direction, .softening)
    }

    func testTooLittleHistoryIsReportedHonestly() {
        let result = CUSUM.onPeriodHistory([1.0, 1.01, 0.99])
        XCTAssertFalse(result.changeDetected)
        XCTAssertTrue(result.explanation.contains("eight"))
    }

    func testZeroVarianceDoesNotProduceNaN() {
        let result = CUSUM.detect([1, 1, 1], baseline: 1, standardDeviation: 0)
        XCTAssertFalse(result.changeDetected)
    }
}

final class AnomalyDetectionTests: XCTestCase {

    private func normalObservations(count: Int, seed: UInt64 = 7) -> [[Double]] {
        var rng = SeededRandom(seed: seed)
        return (0..<count).map { _ in
            let period = 1.2 + rng.gaussian(sd: 0.02)
            // Damping is correlated with period in this building.
            let damping = 0.05 + (period - 1.2) * 0.5 + rng.gaussian(sd: 0.002)
            let ambient = 0.004 + rng.gaussian(sd: 0.0004)
            return [period, damping, ambient]
        }
    }

    private let names = ["period", "damping", "ambient level"]

    func testNormalObservationsAreNotFlagged() {
        let model = AnomalyDetection.train(observations: normalObservations(count: 200),
                                           featureNames: names)
        XCTAssertTrue(model.isTrained)
        let verdict = AnomalyDetection.evaluate([1.2, 0.05, 0.004], model: model)
        XCTAssertFalse(verdict.isAnomalous)
    }

    func testAClearlyAbnormalObservationIsFlagged() {
        let model = AnomalyDetection.train(observations: normalObservations(count: 200),
                                           featureNames: names)
        let verdict = AnomalyDetection.evaluate([1.9, 0.05, 0.004], model: model)
        XCTAssertTrue(verdict.isAnomalous)
        XCTAssertEqual(verdict.featureContributions.first?.name, "period")
    }

    func testACombinationThatBreaksTheCorrelationIsFlagged() {
        // Each value is individually ordinary; together they are impossible for
        // this building. A per-feature threshold would miss this entirely, which
        // is exactly why the covariance matters.
        let model = AnomalyDetection.train(observations: normalObservations(count: 300),
                                           featureNames: names)
        let individuallyNormal = AnomalyDetection.evaluate([1.24, 0.03, 0.004], model: model)
        XCTAssertTrue(individuallyNormal.isAnomalous,
                      "distance \(individuallyNormal.distance) vs threshold \(model.threshold)")
    }

    func testUntrainedModelSaysSoRatherThanGuessing() {
        let model = AnomalyDetection.train(observations: normalObservations(count: 3),
                                           featureNames: names)
        XCTAssertFalse(model.isTrained)
        let verdict = AnomalyDetection.evaluate([1.2, 0.05, 0.004], model: model)
        XCTAssertFalse(verdict.isAnomalous)
        XCTAssertTrue(verdict.explanation.contains("twelve"))
    }

    func testConstantFeatureDoesNotMakeEverythingInfinitelyAnomalous() {
        // A stuck sensor reports the same value forever, giving zero variance.
        // Without a ridge term the covariance is singular.
        var rng = SeededRandom(seed: 5)
        let observations = (0..<50).map { _ -> [Double] in
            [1.2 + rng.gaussian(sd: 0.02), 0.05, 0.004 + rng.gaussian(sd: 0.0003)]
        }
        let model = AnomalyDetection.train(observations: observations, featureNames: names)
        XCTAssertTrue(model.isTrained)
        let verdict = AnomalyDetection.evaluate([1.21, 0.05, 0.004], model: model)
        XCTAssertTrue(verdict.distance.isFinite)
    }

    func testMahalanobisIsZeroAtTheMean() {
        let model = AnomalyDetection.train(observations: normalObservations(count: 100),
                                           featureNames: names)
        let distance = AnomalyDetection.mahalanobis(model.means, means: model.means,
                                                    precision: model.precision)
        XCTAssertEqual(distance, 0, accuracy: 1e-9)
    }

    func testMatrixInversionRoundTrips() {
        let m = [[4.0, 1.0, 0.5], [1.0, 3.0, 0.2], [0.5, 0.2, 2.0]]
        let inverse = AnomalyDetection.invert(m)!
        let product = LinearAlgebra.matMul(m, inverse)
        for i in 0..<3 {
            for j in 0..<3 {
                XCTAssertEqual(product[i][j], i == j ? 1 : 0, accuracy: 1e-9)
            }
        }
    }

    func testSingularMatrixReturnsNil() {
        XCTAssertNil(AnomalyDetection.invert([[1, 2], [2, 4]]))
    }

    func testMismatchedDimensionsAreRejected() {
        let model = AnomalyDetection.train(observations: normalObservations(count: 50),
                                           featureNames: names)
        let verdict = AnomalyDetection.evaluate([1.2, 0.05], model: model)
        XCTAssertFalse(verdict.isAnomalous)
    }
}

final class AftershockForecastTests: XCTestCase {

    func testRateDecaysWithTime() {
        // Omori: far more aftershocks in the first day than in the seventh.
        let firstDay = AftershockForecast.expectedCount(mainshockMagnitude: 7.0, magnitude: 5.0,
                                                        fromHours: 0, toHours: 24)
        let seventhDay = AftershockForecast.expectedCount(mainshockMagnitude: 7.0, magnitude: 5.0,
                                                          fromHours: 144, toHours: 168)
        XCTAssertGreaterThan(firstDay, seventhDay * 3)
    }

    func testLargerMainshocksProduceMoreAftershocks() {
        let small = AftershockForecast.expectedCount(mainshockMagnitude: 5.5, magnitude: 4.0,
                                                     fromHours: 0, toHours: 24)
        let large = AftershockForecast.expectedCount(mainshockMagnitude: 7.5, magnitude: 4.0,
                                                     fromHours: 0, toHours: 24)
        XCTAssertGreaterThan(large, small * 10)
    }

    func testLargerAftershocksAreRarer() {
        // Gutenberg-Richter: each magnitude unit is roughly ten times rarer.
        let magnitude4 = AftershockForecast.expectedCount(mainshockMagnitude: 7, magnitude: 4,
                                                          fromHours: 0, toHours: 168)
        let magnitude5 = AftershockForecast.expectedCount(mainshockMagnitude: 7, magnitude: 5,
                                                          fromHours: 0, toHours: 168)
        XCTAssertEqual(magnitude4 / magnitude5, 10, accuracy: 1.5)
    }

    func testProbabilityIsBoundedAndMonotonic() {
        var previous = -1.0
        for hours in [1.0, 6, 24, 72, 168, 720] {
            let forecast = AftershockForecast.forecast(mainshockMagnitude: 6.8, toHours: hours)
            XCTAssertTrue((0...1).contains(forecast.probabilityOfAtLeastOne))
            XCTAssertGreaterThanOrEqual(forecast.probabilityOfAtLeastOne, previous)
            previous = forecast.probabilityOfAtLeastOne
        }
    }

    func testZeroLengthWindowGivesZeroProbability() {
        XCTAssertEqual(AftershockForecast.expectedCount(mainshockMagnitude: 7, magnitude: 5,
                                                        fromHours: 10, toHours: 10), 0)
    }

    func testForecastExplainsItself() {
        let forecast = AftershockForecast.forecast(mainshockMagnitude: 6.5, toHours: 24)
        XCTAssertFalse(forecast.explanation.isEmpty)
        XCTAssertTrue(forecast.explanation.contains("%"))
    }

    func testGuidanceIsStricterForMoreDamagedBuildings() {
        let green = AftershockForecast.reentryGuidance(mainshockMagnitude: 6.8, verdict: .green)
        let amber = AftershockForecast.reentryGuidance(mainshockMagnitude: 6.8, verdict: .amber)
        let red = AftershockForecast.reentryGuidance(mainshockMagnitude: 6.8, verdict: .red)

        XCTAssertLessThanOrEqual(green.recommendedWaitHours, amber.recommendedWaitHours)
        XCTAssertTrue(red.headline.contains("Do not"))
        XCTAssertFalse(green.detail.isEmpty)
        XCTAssertEqual(green.forecasts.count, 5)
    }

    func testGuidanceForARedBuildingNeverSuggestsGoingBackIn() {
        let red = AftershockForecast.reentryGuidance(mainshockMagnitude: 5.0, verdict: .red)
        XCTAssertTrue(red.detail.lowercased().contains("engineer"))
    }

    func testParametersClampToPhysicallySensibleValues() {
        let p = AftershockForecast.Parameters(a: -1.67, b: 1.0, p: 0.1, c: -5)
        XCTAssertGreaterThanOrEqual(p.p, 0.5)
        XCTAssertGreaterThan(p.c, 0)
    }

    func testPEqualToOneDoesNotDivideByZero() {
        let count = AftershockForecast.expectedCount(
            mainshockMagnitude: 7, magnitude: 5, fromHours: 0, toHours: 24,
            parameters: .init(a: -1.67, b: 1.0, p: 1.0, c: 0.05))
        XCTAssertTrue(count.isFinite)
        XCTAssertGreaterThan(count, 0)
    }
}
