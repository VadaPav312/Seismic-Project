import XCTest
@testable import SeismicCore

/// Massing: how a building's plan changes as it rises.
///
/// These matter more than they look. The profile drives the mass the modal
/// analysis integrates, so an error here does not draw a wrong picture — it
/// reports a wrong period, which is the number the whole app rests on.
final class MassingTests: XCTestCase {

    func testAUniformProfileIsExactlyUniform() {
        let massing = Massing.uniform
        XCTAssertTrue(massing.isUniform)
        for fraction in stride(from: 0.0, through: 1.0, by: 0.1) {
            XCTAssertEqual(massing.scale(at: fraction), 1, accuracy: 1e-9)
        }
        XCTAssertNil(massing.largestDiscontinuity)
    }

    func testATaperNarrowsMonotonicallyAndReachesItsTop() {
        let massing = Massing.tapered(topScale: 0.3)
        XCTAssertEqual(massing.scale(at: 0), 1, accuracy: 1e-9)
        XCTAssertEqual(massing.scale(at: 1), 0.3, accuracy: 1e-9)

        var previous = 1.1
        for fraction in stride(from: 0.0, through: 1.0, by: 0.05) {
            let scale = massing.scale(at: fraction)
            XCTAssertLessThanOrEqual(scale, previous + 1e-9, "taper is not monotonic")
            previous = scale
        }
        XCTAssertFalse(massing.isUniform)
    }

    /// A taper is gradual, so it is not a discontinuity however much it narrows.
    /// That distinction is the whole point of the property: an engineer cares
    /// about abrupt changes, not total ones.
    func testAGradualTaperIsNotReportedAsADiscontinuity() {
        XCTAssertNil(Massing.tapered(topScale: 0.2).largestDiscontinuity)
    }

    func testAPodiumIsAnAbruptDropAtTheRightHeight() {
        let massing = Massing.podium(podiumFraction: 0.3, towerScale: 0.4)
        XCTAssertEqual(massing.scale(at: 0.2), 1, accuracy: 1e-9, "still podium")
        XCTAssertEqual(massing.scale(at: 0.5), 0.4, accuracy: 1e-9, "already tower")

        guard let discontinuity = massing.largestDiscontinuity else {
            return XCTFail("A podium must register as a discontinuity")
        }
        XCTAssertEqual(discontinuity.atHeightFraction, 0.3, accuracy: 0.02)
        XCTAssertEqual(discontinuity.drop, 0.6, accuracy: 0.02)
    }

    func testSetbacksStepRatherThanSlope() {
        let massing = Massing.setback(steps: 3, topScale: 0.5)
        XCTAssertNotNil(massing.largestDiscontinuity,
                        "A setback is a ledge, not a chamfer")
        XCTAssertEqual(massing.scale(at: 1), 0.5, accuracy: 0.02)
    }

    /// Area goes with the square of a linear scale. Getting this wrong on a
    /// tower-on-podium misplaces a large fraction of a building's weight.
    func testFloorAreaFollowsTheSquareOfThePlanScale() {
        let massing = Massing.podium(podiumFraction: 0.25, towerScale: 0.5)
        let areas = massing.floorAreas(baseArea: 1000, storeys: 20)

        XCTAssertEqual(areas.first ?? 0, 1000, accuracy: 1, "podium is full area")
        // Half the plan width is a quarter of the floor.
        XCTAssertEqual(areas.last ?? 0, 250, accuracy: 5, "tower is a quarter of the area")
    }

    func testScalesAreSampledAtStoreyMiddles() {
        // Sampling at the base would put every setback one storey too high.
        let massing = Massing.podium(podiumFraction: 0.5, towerScale: 0.5)
        let scales = massing.scales(storeys: 10)
        XCTAssertEqual(scales.count, 10)
        XCTAssertEqual(scales[0], 1, accuracy: 1e-9)
        XCTAssertEqual(scales[9], 0.5, accuracy: 1e-9)
    }

    /// Stations arriving out of order or duplicated must not fold the building.
    func testStationsAreSortedAndDeduplicated() {
        let massing = Massing(stations: [
            .init(heightFraction: 1, scale: 0.4),
            .init(heightFraction: 0, scale: 1),
            .init(heightFraction: 0.5, scale: 0.7),
            .init(heightFraction: 0.5, scale: 0.2),
        ])
        let fractions = massing.stations.map(\.heightFraction)
        XCTAssertEqual(fractions, fractions.sorted())
        XCTAssertEqual(Set(fractions).count, fractions.count, "duplicates survived")
    }

    func testAbsurdInputIsClampedRatherThanPropagated() {
        let massing = Massing(stations: [
            .init(heightFraction: -5, scale: 40),
            .init(heightFraction: 12, scale: -3),
        ])
        for station in massing.stations {
            XCTAssertTrue((0...1).contains(station.heightFraction))
            XCTAssertTrue((0.05...1).contains(station.scale))
        }
        for fraction in [-1.0, 0, 0.5, 1, 99] {
            XCTAssertTrue(massing.scale(at: fraction).isFinite)
        }
        XCTAssertEqual(Massing(stations: []).scale(at: 0.5), 1, accuracy: 1e-9,
                       "An empty profile must fall back to uniform")
    }

    func testSummaryDescribesWhatTheProfileActuallyDoes() {
        XCTAssertTrue(Massing.uniform.summary.contains("Uniform"))
        XCTAssertTrue(Massing.podium(podiumFraction: 0.25, towerScale: 0.4)
            .summary.lowercased().contains("setback"))
        XCTAssertTrue(Massing.tapered(topScale: 0.4)
            .summary.lowercased().contains("taper"))
    }

    func testItSurvivesACodingRoundTrip() throws {
        // It travels as JSON inside a retrieved fact, so this is a real path.
        let original = Massing.setback(steps: 4, topScale: 0.35)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Massing.self, from: data)
        XCTAssertEqual(decoded, original)
    }
}
