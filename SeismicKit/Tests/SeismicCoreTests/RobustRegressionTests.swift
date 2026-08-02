import XCTest
@testable import SeismicCore

/// Theil–Sen against ordinary least squares.
///
/// The tests are built around the one property that justifies replacing a fit
/// everybody understands with one they do not: least squares can be broken by a
/// single bad point, and this cannot.
final class RobustRegressionTests: XCTestCase {

    /// A clean line, plus optional contamination.
    private func data(slope: Double, intercept: Double, count: Int,
                      noise: Double = 0, seed: UInt64 = 5)
        -> (x: [Double], y: [Double])
    {
        var rng = SeededRandom(seed: seed)
        let x = (0..<count).map { Double($0) * 0.5 }
        let y = x.map { intercept + slope * $0 + (noise > 0 ? rng.gaussian(sd: noise) : 0) }
        return (x, y)
    }

    // MARK: The basics

    func testItRecoversACleanLineExactly() {
        let (x, y) = data(slope: 2.5, intercept: -1.25, count: 20)
        guard let fit = TheilSen.fit(x: x, y: y) else { return XCTFail("No fit.") }
        XCTAssertEqual(fit.slope, 2.5, accuracy: 1e-9)
        XCTAssertEqual(fit.intercept, -1.25, accuracy: 1e-9)
        XCTAssertEqual(fit.medianAbsoluteResidual, 0, accuracy: 1e-9)
    }

    func testItRecoversALineThroughNoisyData() {
        let (x, y) = data(slope: -0.8, intercept: 4.0, count: 60, noise: 0.2)
        guard let fit = TheilSen.fit(x: x, y: y) else { return XCTFail() }
        XCTAssertEqual(fit.slope, -0.8, accuracy: 0.06)
        XCTAssertEqual(fit.intercept, 4.0, accuracy: 0.3)
    }

    func testItRefusesTooFewPoints() {
        XCTAssertNil(TheilSen.fit(x: [1, 2], y: [1, 2]))
        XCTAssertNil(TheilSen.fit(x: [1, 2, 3], y: [1, 2]))
    }

    func testAllPointsAtTheSameXProduceNothingRatherThanInfinity() {
        XCTAssertNil(TheilSen.fit(x: [3, 3, 3, 3], y: [1, 2, 3, 4]))
    }

    // MARK: The reason it exists

    /// One bad measurement — a lorry idling outside during a nightly reading —
    /// must not move the answer.
    ///
    /// The outlier is placed at the *end* of the temperature range, and that is
    /// not to make the test easier. It is the realistic case and the dangerous
    /// one: a reading's leverage over a least-squares slope grows with its
    /// distance from the mean, so the bad night that does real damage is the
    /// coldest or hottest one of the year, which is exactly where a building's
    /// plant is most likely to be running hard.
    func testASingleWildPointAtTheEndOfTheRangeBreaksLeastSquaresAndNotTheilSen() {
        var (x, y) = data(slope: 2.0, intercept: 0, count: 30)
        y[29] += 60

        guard let robust = TheilSen.fit(x: x, y: y),
              let ols = TheilSen.leastSquares(x: x, y: y) else { return XCTFail() }

        XCTAssertEqual(robust.slope, 2.0, accuracy: 0.05,
                       "Theil–Sen moved to \(robust.slope).")
        XCTAssertGreaterThan(abs(ols.slope - 2.0), 0.3,
                             "Least squares was supposed to be dragged; it gave "
                             + "\(ols.slope).")
    }

    /// And the corollary, which is worth knowing before trusting either fit:
    /// the same bad reading in the middle of the range barely touches the
    /// slope. Least squares is not uniformly fragile — it is fragile at the
    /// ends, which is where the informative measurements also live.
    func testAWildPointInTheMiddleHasLittleLeverageOnEitherFit() {
        var (x, y) = data(slope: 2.0, intercept: 0, count: 30)
        y[15] += 60

        guard let robust = TheilSen.fit(x: x, y: y),
              let ols = TheilSen.leastSquares(x: x, y: y) else { return XCTFail() }

        XCTAssertEqual(robust.slope, 2.0, accuracy: 0.05)
        XCTAssertEqual(ols.slope, 2.0, accuracy: 0.1,
                       "A mid-range outlier moved least squares more than expected.")
    }

    /// The formal claim: up to about 29% of the data can be arbitrarily wrong
    /// before the estimator can be broken at all. Tested at 20%, comfortably
    /// inside that but far past anything least squares survives.
    func testItSurvivesAFifthOfTheDataBeingWrong() {
        var (x, y) = data(slope: 1.5, intercept: 2.0, count: 50)
        var rng = SeededRandom(seed: 99)
        for i in stride(from: 0, to: 50, by: 5) {
            y[i] = rng.uniform(-200, 200)          // complete nonsense
        }

        guard let robust = TheilSen.fit(x: x, y: y),
              let ols = TheilSen.leastSquares(x: x, y: y) else { return XCTFail() }

        XCTAssertEqual(robust.slope, 1.5, accuracy: 0.25,
                       "Theil–Sen gave \(robust.slope).")
        XCTAssertGreaterThan(abs(ols.slope - 1.5), abs(robust.slope - 1.5),
                             "Least squares \(ols.slope) was no worse than robust "
                             + "\(robust.slope).")
    }

    /// The residual scale has to be robust too, or a couple of wild points
    /// inflate it and everything downstream concludes the fit is poor.
    func testTheResidualScaleIgnoresTheOutliers() {
        var (x, y) = data(slope: 1.0, intercept: 0, count: 40, noise: 0.05)
        y[3] += 100
        y[9] -= 100

        guard let fit = TheilSen.fit(x: x, y: y) else { return XCTFail() }
        XCTAssertLessThan(fit.medianAbsoluteResidual, 0.2,
                          "Residual scale was \(fit.medianAbsoluteResidual).")
    }

    // MARK: The interval

    func testARealSlopeIsReportedAsSignificant() {
        let (x, y) = data(slope: 3.0, intercept: 1.0, count: 40, noise: 0.1)
        guard let fit = TheilSen.fit(x: x, y: y) else { return XCTFail() }
        XCTAssertTrue(fit.isSlopeSignificant)
        XCTAssertTrue(fit.slopeInterval.contains(3.0))
    }

    /// The check that matters for the temperature correction: a building whose
    /// period genuinely does not depend on temperature must not have a
    /// correction applied on the strength of a slope that is noise.
    func testNoRelationshipIsReportedAsNotSignificant() {
        var rng = SeededRandom(seed: 3)
        let x = (0..<60).map { Double($0) }
        let y = (0..<60).map { _ in rng.gaussian(sd: 1) }

        guard let fit = TheilSen.fit(x: x, y: y) else { return XCTFail() }
        XCTAssertFalse(fit.isSlopeSignificant,
                       "Interval \(fit.slopeInterval) excluded zero for pure noise.")
    }

    func testTheIntervalBracketsTheSlope() {
        let (x, y) = data(slope: -2.0, intercept: 0, count: 40, noise: 0.3)
        guard let fit = TheilSen.fit(x: x, y: y) else { return XCTFail() }
        XCTAssertLessThanOrEqual(fit.slopeInterval.lowerBound, fit.slope)
        XCTAssertGreaterThanOrEqual(fit.slopeInterval.upperBound, fit.slope)
    }

    // MARK: Scale

    /// A decade of nightly measurements is seven million pairs. The sampled
    /// path has to give the same answer as the exhaustive one.
    func testTheSampledPathAgreesWithTheExhaustiveOne() {
        let (x, y) = data(slope: 1.7, intercept: 0.5, count: 220, noise: 0.1)

        guard let exhaustive = TheilSen.fit(x: x, y: y, maximumPairs: 1_000_000),
              let sampled = TheilSen.fit(x: x, y: y, maximumPairs: 2_000)
        else { return XCTFail() }

        XCTAssertEqual(sampled.slope, exhaustive.slope, accuracy: 0.05)
    }

    func testPredictionMatchesTheFittedLine() {
        let (x, y) = data(slope: 2.0, intercept: 3.0, count: 20)
        guard let fit = TheilSen.fit(x: x, y: y) else { return XCTFail() }
        XCTAssertEqual(fit.predict(10), 23, accuracy: 1e-6)
    }
}
