import XCTest
@testable import SeismicCore

/// Section properties, checked against closed-form answers.
///
/// These formulae are easy to get subtly wrong — a factor of twelve, a sign, a
/// missing parallel-axis term — and wrong in a way that still produces
/// plausible numbers. So every case here has an analytic value to compare
/// against rather than a previously recorded output.
final class SectionPropertiesTests: XCTestCase {

    private func rectangle(width: Double, depth: Double,
                           originX: Double = 0, originY: Double = 0) -> [Coordinate2D] {
        let w = width / 2, d = depth / 2
        return [
            Coordinate2D(x: originX - w, y: originY - d),
            Coordinate2D(x: originX + w, y: originY - d),
            Coordinate2D(x: originX + w, y: originY + d),
            Coordinate2D(x: originX - w, y: originY + d),
        ]
    }

    // MARK: Rectangles

    /// For a rectangle, Ixx = b·h³/12 and Iyy = h·b³/12. Textbook.
    func testRectangleMatchesTheClosedForm() {
        let width = 30.0, depth = 12.0
        let section = SectionProperties.of(rectangle(width: width, depth: depth))

        XCTAssertEqual(section.area, width * depth, accuracy: 1e-9)
        XCTAssertEqual(section.centroidX, 0, accuracy: 1e-9)
        XCTAssertEqual(section.centroidY, 0, accuracy: 1e-9)
        XCTAssertEqual(section.ixx, width * pow(depth, 3) / 12, accuracy: 1e-6)
        XCTAssertEqual(section.iyy, depth * pow(width, 3) / 12, accuracy: 1e-6)
        XCTAssertEqual(section.ixy, 0, accuracy: 1e-6, "A symmetric plan has no product of inertia")
    }

    /// The centroid must be found, not assumed to be the origin.
    func testAnOffsetRectangleStillReportsCentroidalMoments() {
        let centred = SectionProperties.of(rectangle(width: 20, depth: 10))
        let offset = SectionProperties.of(rectangle(width: 20, depth: 10,
                                                    originX: 137, originY: -64))

        XCTAssertEqual(offset.centroidX, 137, accuracy: 1e-6)
        XCTAssertEqual(offset.centroidY, -64, accuracy: 1e-6)
        // Moments are about the centroid, so moving the shape changes nothing.
        XCTAssertEqual(offset.ixx, centred.ixx, accuracy: 1e-6)
        XCTAssertEqual(offset.iyy, centred.iyy, accuracy: 1e-6)
    }

    /// Winding order is not something a traced outline guarantees.
    func testWindingOrderDoesNotChangeTheAnswer() {
        let ring = rectangle(width: 24, depth: 9)
        let forward = SectionProperties.of(ring)
        let reversed = SectionProperties.of(ring.reversed())

        XCTAssertEqual(forward.area, reversed.area, accuracy: 1e-9)
        XCTAssertEqual(forward.ixx, reversed.ixx, accuracy: 1e-6)
        XCTAssertEqual(forward.iyy, reversed.iyy, accuracy: 1e-6)
        XCTAssertEqual(forward.ixy, reversed.ixy, accuracy: 1e-6)
    }

    /// A square is directionally neutral; a slab emphatically is not.
    func testDirectionalRatioReflectsTheProportions() {
        XCTAssertEqual(SectionProperties.of(rectangle(width: 20, depth: 20)).directionalRatio,
                       1, accuracy: 1e-6)
        // Stiffness goes with the cube of the dimension, so 4:1 in plan is
        // 16:1 in stiffness.
        XCTAssertEqual(SectionProperties.of(rectangle(width: 40, depth: 10)).directionalRatio,
                       16, accuracy: 1e-3)
    }

    // MARK: Curves

    /// A circle approximated as a dense polygon must converge on πr⁴/4.
    ///
    /// This is the case that proves curved plans need no special handling: the
    /// integration is exact for the polygon it is given, so accuracy is set
    /// purely by how finely the curve was traced.
    func testACircleConvergesOnTheAnalyticValue() {
        let radius = 14.0
        for sides in [64, 256, 1024] {
            let ring = (0..<sides).map { index -> Coordinate2D in
                let angle = 2 * .pi * Double(index) / Double(sides)
                return Coordinate2D(x: radius * cos(angle), y: radius * sin(angle))
            }
            let section = SectionProperties.of(ring)
            let expectedI = .pi * pow(radius, 4) / 4
            let tolerance = sides >= 256 ? 0.002 : 0.02

            XCTAssertEqual(section.area, .pi * radius * radius,
                           accuracy: .pi * radius * radius * tolerance)
            XCTAssertEqual(section.ixx, expectedI, accuracy: expectedI * tolerance)
            XCTAssertEqual(section.iyy, expectedI, accuracy: expectedI * tolerance)
            XCTAssertEqual(section.directionalRatio, 1, accuracy: 0.01,
                           "A circle has no preferred direction")
        }
    }

    // MARK: Asymmetric plans

    /// An L has a non-zero product of inertia, and principal axes that are not
    /// the axes it was drawn on. Missing that is how a model misses the
    /// direction a building is weakest in.
    func testAnLShapeHasRotatedPrincipalAxes() {
        // Unit L: a 2x2 square with the top-right 1x1 removed.
        let ring = [
            Coordinate2D(x: 0, y: 0), Coordinate2D(x: 2, y: 0),
            Coordinate2D(x: 2, y: 1), Coordinate2D(x: 1, y: 1),
            Coordinate2D(x: 1, y: 2), Coordinate2D(x: 0, y: 2),
        ]
        let section = SectionProperties.of(ring)

        XCTAssertEqual(section.area, 3, accuracy: 1e-9)
        // Centroid of three unit squares at (0.5,0.5), (1.5,0.5), (0.5,1.5).
        XCTAssertEqual(section.centroidX, 5.0 / 6.0, accuracy: 1e-6)
        XCTAssertEqual(section.centroidY, 5.0 / 6.0, accuracy: 1e-6)

        XCTAssertNotEqual(section.ixy, 0, "An L is not symmetric about its own axes")
        let degrees = abs(section.principalAngle * 180 / .pi)
        // Symmetric about its diagonal, so the principal axes sit at 45°.
        XCTAssertEqual(degrees, 45, accuracy: 1.0)
    }

    /// Symmetry the shape genuinely has must come out exactly.
    func testASymmetricPlanHasNoProductOfInertia() {
        for shape in [rectangle(width: 30, depth: 30), rectangle(width: 8, depth: 40)] {
            XCTAssertEqual(SectionProperties.of(shape).ixy, 0, accuracy: 1e-9)
        }
    }

    /// Principal moments are an invariant: their sum is the polar moment,
    /// whatever axes the shape happened to be drawn on.
    func testPrincipalMomentsPreserveThePolarMoment() {
        let ring = [
            Coordinate2D(x: -3, y: -1), Coordinate2D(x: 5, y: -2),
            Coordinate2D(x: 4, y: 3), Coordinate2D(x: -2, y: 4),
        ]
        let section = SectionProperties.of(ring)
        XCTAssertEqual(section.iMajor + section.iMinor, section.polarMoment, accuracy: 1e-6)
        XCTAssertGreaterThanOrEqual(section.iMajor, section.iMinor)
        XCTAssertGreaterThanOrEqual(section.iMinor, 0)
    }

    // MARK: Degenerate input

    func testDegenerateOutlinesReturnNothingRatherThanNonsense() {
        let cases: [[Coordinate2D]] = [
            [],
            [Coordinate2D(x: 0, y: 0)],
            [Coordinate2D(x: 0, y: 0), Coordinate2D(x: 1, y: 1)],
            // Collinear: three points, no enclosed area.
            [Coordinate2D(x: 0, y: 0), Coordinate2D(x: 1, y: 1), Coordinate2D(x: 2, y: 2)],
        ]
        for ring in cases {
            let section = SectionProperties.of(ring)
            XCTAssertEqual(section.area, 0)
            XCTAssertEqual(section.radiusOfGyration, 0)
            XCTAssertTrue(section.ixx.isFinite && section.iyy.isFinite)
        }
    }

    func testEverythingStaysFiniteForAbsurdCoordinates() {
        let ring = [
            Coordinate2D(x: -1e7, y: -1e7), Coordinate2D(x: 1e7, y: -1e7),
            Coordinate2D(x: 1e7, y: 1e7), Coordinate2D(x: -1e7, y: 1e7),
        ]
        let section = SectionProperties.of(ring)
        XCTAssertTrue(section.area.isFinite)
        XCTAssertTrue(section.ixx.isFinite)
        XCTAssertTrue(section.radiusOfGyration.isFinite)
        XCTAssertGreaterThan(section.area, 0)
    }

    /// Eccentricity is the number codes regulate, so its scale must be right.
    func testEccentricityIsMeasuredAgainstThePlansOwnSize() {
        let section = SectionProperties.of(rectangle(width: 40, depth: 40))
        XCTAssertEqual(section.eccentricityRatio(stiffnessCentreX: 0, stiffnessCentreY: 0),
                       0, accuracy: 1e-9, "Coincident centres mean no eccentricity")

        let offset = section.eccentricityRatio(stiffnessCentreX: 4, stiffnessCentreY: 0)
        XCTAssertGreaterThan(offset, 0)
        XCTAssertLessThan(offset, 1, "4 m on a 40 m plan is not a whole radius of gyration")
    }
}
